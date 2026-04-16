import Foundation
import AVFoundation
import WhisperKit

final class WhisperKitEngine: NSObject, STTEngine {
    var displayName: String { "WhisperKit (\(modelName))" }
    private(set) var isRunning: Bool = false

    private let modelName: String
    private var whisperKit: WhisperKit?
    private var audioEngine = AVAudioEngine()
    private var streamContinuation: AsyncStream<TranscriptionChunk>.Continuation?
    private var transcriptionTask: Task<Void, Never>?

    private let sampleBuffer = SampleBuffer()
    private let state = EngineState()

    // VAD
    private let vad = VADDetector()
    private let vadLock = NSLock()
    private var _cachedVADState: VADState = .speaking
    private var cachedVADState: VADState {
        get { vadLock.withLock { _cachedVADState } }
        set { vadLock.withLock { _cachedVADState = newValue } }
    }

    init(modelName: String) {
        self.modelName = modelName
    }

    func makeTranscriptionStream() -> AsyncStream<TranscriptionChunk> {
        AsyncStream { continuation in
            self.streamContinuation = continuation
        }
    }

    func setContextualStrings(from script: String) {
        // WhisperKit does not support contextual string hints like Apple Speech.
        // In the future, this could inject a prompt via decode options.
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

        if whisperKit == nil {
            do {
                let kit = try await WhisperKit(
                    model: modelName,
                    verbose: true,
                    logLevel: .error,
                    download: true
                )
                self.whisperKit = kit
            } catch {
                throw STTError.engineNotAvailable
            }
        }
    }

    func start() async throws {
        guard !isRunning else { return }
        try await prepare()

        await sampleBuffer.reset()
        await state.reset()
        await vad.reset()

        audioEngine.stop()
        audioEngine.reset()
        audioEngine.inputNode.removeTap(onBus: 0)

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw STTError.engineNotAvailable
        }

        let converter = AVAudioConverter(from: recordingFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            guard !MicState.shared.isMuted else { return }
            let samples: [Float]
            if let converter = converter, buffer.format.sampleRate != targetFormat.sampleRate {
                samples = self.convert(buffer: buffer, using: converter, to: targetFormat)
            } else {
                guard let channelData = buffer.floatChannelData?[0] else { return }
                samples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
            }

            let rms = audioRMS(samples)
            Task { [weak self] in
                guard let self else { return }
                // Append first to preserve chronological ordering across concurrent Tasks.
                await self.sampleBuffer.append(samples)
                let (newState, changed) = await self.vad.process(rms: rms)
                self.cachedVADState = newState
                if changed { self.streamContinuation?.yield(.vadEvent(newState)) }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRunning = true
        print("[WhisperKitEngine] Audio engine started for model \(modelName)")

        await MainActor.run {
            WhisperKitModelManager.shared.markUsed(model: modelName)
        }

        transcriptionTask = Task.detached(priority: .userInitiated) { [weak self] in
            while let self = self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.5))
                guard !Task.isCancelled else { return }
                await self.transcribeAccumulated()
            }
        }
    }

    private func convert(buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat) -> [Float] {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * (format.sampleRate / buffer.format.sampleRate))
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        converter.convert(to: converted, error: &error, withInputFrom: inputBlock)
        guard error == nil else { return [] }
        guard let channelData = converted.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channelData, count: Int(converted.frameLength)))
    }

    private func transcribeAccumulated() async {
        guard await !state.isTranscribing else { return }
        guard let whisperKit = whisperKit else { return }

        // Skip transcription during confirmed silence — no speech to process
        guard cachedVADState != .silence else { return }

        let samples = await sampleBuffer.get()
        guard !samples.isEmpty else { return }

        await state.setTranscribing(true)
        defer { Task { await state.setTranscribing(false) } }

        do {
            let results = try await whisperKit.transcribe(audioArray: samples)
            guard let result = results.first else { return }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let lastText = await state.lastTranscribedText
            if text != lastText {
                await state.setLastTranscribedText(text)
                print("[WhisperKitEngine] Transcription: \"\(text)\"")
                let chunk = TranscriptionChunk(text: text, isFinal: false, timestamp: Date(), vadState: cachedVADState)
                streamContinuation?.yield(chunk)
            }
        } catch {
            print("[WhisperKitEngine] Transcription error: \(error)")
        }
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        transcriptionTask?.cancel()
        transcriptionTask = nil
        print("[WhisperKitEngine] Stopped")

        await transcribeAccumulated()

        let finalText = await state.lastTranscribedText
        let finalChunk = TranscriptionChunk(
            text: finalText,
            isFinal: true,
            timestamp: Date(),
            vadState: cachedVADState
        )
        streamContinuation?.yield(finalChunk)
        streamContinuation?.finish()
        streamContinuation = nil
    }

}

private actor EngineState {
    var isTranscribing: Bool = false
    var lastTranscribedText: String = ""

    func setTranscribing(_ value: Bool) {
        isTranscribing = value
    }

    func setLastTranscribedText(_ text: String) {
        lastTranscribedText = text
    }

    func reset() {
        isTranscribing = false
        lastTranscribedText = ""
    }
}

private actor SampleBuffer {
    var samples: [Float] = []

    func append(_ newSamples: [Float]) {
        samples.append(contentsOf: newSamples)
        let maxSamples = 16000 * 4
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    func get() -> [Float] {
        samples
    }

    func reset() {
        samples = []
    }
}
