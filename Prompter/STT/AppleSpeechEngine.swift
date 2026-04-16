import Speech
import AVFoundation

@MainActor
final class AppleSpeechEngine: NSObject, STTEngine, SFSpeechRecognizerDelegate {
    var displayName: String { "Apple Speech" }
    private(set) var isRunning: Bool = false

    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    private var streamContinuation: AsyncStream<TranscriptionChunk>.Continuation?
    private var contextualStrings: [String] = []

    // VAD
    private let vad = VADDetector()
    private let vadLock = NSLock()
    private var _cachedVADState: VADState = .speaking
    private var cachedVADState: VADState {
        get { vadLock.withLock { _cachedVADState } }
        set { vadLock.withLock { _cachedVADState = newValue } }
    }

    override init() {
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        super.init()
        recognizer?.delegate = self
    }

    func setContextualStrings(from script: String) {
        // Extract unique words/phrases to boost recognition accuracy
        let normalized = script.lowercased()
        let words = normalized.components(separatedBy: CharacterSet.letters.inverted).filter { $0.count > 3 }
        let bigrams = zip(words, words.dropFirst()).map { "\($0) \($1)" }
        var unique = Set(words + bigrams)
        // Also keep any bracketed stage directions
        if let regex = try? NSRegularExpression(pattern: "\\[[^\\]]+\\]", options: []) {
            let matches = regex.matches(in: script, options: [], range: NSRange(location: 0, length: script.utf16.count))
            for match in matches {
                if let range = Range(match.range, in: script) {
                    unique.insert(String(script[range]))
                }
            }
        }
        contextualStrings = Array(unique).sorted()
    }

    func makeTranscriptionStream() -> AsyncStream<TranscriptionChunk> {
        AsyncStream { continuation in
            self.streamContinuation = continuation
        }
    }

    func prepare() async throws {
        let audioGranted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        guard audioGranted else {
            throw STTError.noMicrophoneAccess
        }

        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            throw STTError.notAuthorized
        }
    }

    func start() async throws {
        guard !isRunning else { return }
        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw STTError.engineNotAvailable
        }

        try await prepare()
        await vad.reset()

        audioEngine.stop()
        audioEngine.reset()
        audioEngine.inputNode.removeTap(onBus: 0)

        request = SFSpeechAudioBufferRecognitionRequest()
        guard let request = request else {
            throw STTError.unknown("Failed to create recognition request")
        }
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = true   // on-device = ~200ms faster
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
        }

        isRunning = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let _ = error {
                self.streamContinuation?.yield(TranscriptionChunk(text: "", isFinal: true, timestamp: Date()))
                self.streamContinuation?.finish()
                Task { await self.stop() }
                return
            }

            guard let result = result else { return }

            let chunk = TranscriptionChunk(
                text: result.bestTranscription.formattedString,
                isFinal: result.isFinal,
                timestamp: Date(),
                vadState: self.cachedVADState
            )
            self.streamContinuation?.yield(chunk)

            if result.isFinal {
                self.streamContinuation?.finish()
            }
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 512, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Compute RMS for VAD directly from the buffer pointer — no array allocation needed.
            let rms: Float
            if let data = buffer.floatChannelData?[0] {
                rms = audioRMS(data, count: Int(buffer.frameLength))
            } else {
                rms = 0
            }

            Task { [weak self] in
                guard let self else { return }
                let (newState, changed) = await self.vad.process(rms: rms)
                self.cachedVADState = newState
                if changed {
                    self.streamContinuation?.yield(.vadEvent(newState))
                }
            }

            // Note: cachedVADState is updated asynchronously by the Task above.
            // Reading it here gives the state from the *previous* buffer (≈11ms lag),
            // which is acceptable — same pattern as MicState.shared.isMuted.
            let isSilent = MicState.shared.isMuted || (self.cachedVADState == .silence)
            if isSilent {
                guard let silent = self.silentBuffer(matching: buffer) else { return }
                self.request?.append(silent)
            } else {
                self.request?.append(buffer)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        print("[AppleSpeechEngine] Recognition task and audio engine started")
    }

    private func silentBuffer(matching buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let silentBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else { return nil }
        silentBuffer.frameLength = buffer.frameLength
        for i in 0..<Int(buffer.format.channelCount) {
            guard let channelData = silentBuffer.floatChannelData?[i] else { continue }
            for frame in 0..<Int(silentBuffer.frameLength) {
                channelData[frame] = 0
            }
        }
        return silentBuffer
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        streamContinuation?.finish()
        streamContinuation = nil
        print("[AppleSpeechEngine] Stopped")
    }

    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        if !available {
            Task { await stop() }
        }
    }
}
