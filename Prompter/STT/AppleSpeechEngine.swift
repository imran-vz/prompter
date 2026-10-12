import Speech
import AVFoundation

/// Apple on-device speech recognition, fed from the shared audio pipeline.
///
/// Recognition sessions are *self-healing*: SFSpeechRecognitionTask ends on its
/// own (errors, ~1-minute on-device limits, finals after pauses). Whenever the
/// current session ends, a fresh request/task pair is created on the next audio
/// chunk and transcription continues seamlessly. Each session's final text is
/// emitted as an `isFinal` chunk, which the controller merges into the
/// accumulated transcript.
nonisolated final class AppleSpeechEngine: STTEngine, @unchecked Sendable {
    var displayName: String { "Apple Speech" }

    private let recognizer: SFSpeechRecognizer?

    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var sessionEnded = true
    private var lastSessionStart: TimeInterval = -.greatestFiniteMagnitude
    private var contextualStrings: [String] = []

    private var consumeTask: Task<Void, Never>?

    init() {
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    // MARK: - Contextual strings

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
        let strings = Array(unique).sorted()
        lock.lock()
        contextualStrings = strings
        lock.unlock()
    }

    // MARK: - Lifecycle

    func prepare() async throws {
        let audioGranted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        guard audioGranted else { throw STTError.noMicrophoneAccess }

        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else { throw STTError.notAuthorized }
    }

    func start(audio: AsyncStream<AudioCaptureEvent>) async throws -> AsyncStream<TranscriptionChunk> {
        guard let recognizer, recognizer.isAvailable else {
            throw STTError.engineNotAvailable
        }

        let (stream, continuation) = AsyncStream.makeStream(of: TranscriptionChunk.self)

        // One task consumes audio in order — no per-buffer task spawning.
        consumeTask = Task.detached(priority: .userInitiated) { [weak self] in
            for await event in audio {
                guard let self, !Task.isCancelled else { break }
                switch event {
                case .formatChanged:
                    // Buffer format may differ now — the old request would choke.
                    self.markSessionEnded()
                case .chunk(let chunk):
                    self.appendChunk(chunk, continuation: continuation)
                }
            }
            // Audio ended (not a cancellation): ask the recognizer to commit
            // and wait briefly for its final result so trailing words reach the
            // stream before it closes. Skipped on cancellation — that's a
            // deliberate teardown where nothing downstream is listening.
            if !Task.isCancelled {
                await self?.drainFinalResult()
            }
            self?.endSession()
            continuation.finish()
            print("[AppleSpeechEngine] Audio stream ended")
        }

        return stream
    }

    /// End the current request's audio and wait (bounded) for the recognition
    /// callback to deliver the final result. The callback yields the final to
    /// the continuation and then sets `sessionEnded`, which is our signal.
    private func drainFinalResult() async {
        let (active, ended) = lock.withLock { (request, sessionEnded) }
        guard let active, !ended else { return }
        active.endAudio()
        for _ in 0..<20 {   // up to ~1s
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return }
            if lock.withLock({ sessionEnded }) { return }
        }
    }

    private func appendChunk(_ chunk: AudioChunk,
                             continuation: AsyncStream<TranscriptionChunk>.Continuation) {
        lock.lock()
        let ended = sessionEnded
        let sinceStart = Date().timeIntervalSinceReferenceDate - lastSessionStart
        lock.unlock()

        if ended {
            // Throttle session creation so a recognizer that fails instantly
            // (e.g. temporarily unavailable) doesn't spin at audio-buffer rate.
            guard sinceStart > 0.5 else { return }
            startSession(continuation: continuation)
        }

        lock.lock()
        let activeRequest = request
        lock.unlock()
        activeRequest?.append(chunk.buffer)
    }

    private func startSession(continuation: AsyncStream<TranscriptionChunk>.Continuation) {
        guard let recognizer else { return }

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.taskHint = .dictation
        newRequest.requiresOnDeviceRecognition = true   // on-device = ~200ms faster

        lock.lock()
        if !contextualStrings.isEmpty {
            newRequest.contextualStrings = contextualStrings
        }
        // Tear down any previous task before installing the new session.
        task?.cancel()
        request = newRequest
        sessionEnded = false
        lastSessionStart = Date().timeIntervalSinceReferenceDate
        lock.unlock()

        let newTask = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                if !text.isEmpty {
                    continuation.yield(TranscriptionChunk(text: text, isFinal: result.isFinal))
                }
                if result.isFinal {
                    self.markSessionEnded()
                }
            }
            if error != nil {
                self.markSessionEnded()
            }
        }

        lock.lock()
        task = newTask
        lock.unlock()
        print("[AppleSpeechEngine] Recognition session started")
    }

    private func markSessionEnded() {
        lock.lock()
        sessionEnded = true
        let active = request
        lock.unlock()
        active?.endAudio()
    }

    /// VAD detected end of turn — ask the recognizer to commit the current
    /// utterance. The final result arrives through the normal callback and the
    /// session restarts on the next audio chunk.
    func finishUtterance() {
        lock.lock()
        let active = request
        lock.unlock()
        active?.endAudio()
    }

    private func endSession() {
        let (activeRequest, activeTask) = lock.withLock {
            let pair = (request, task)
            request = nil
            task = nil
            sessionEnded = true
            return pair
        }
        activeRequest?.endAudio()
        activeTask?.cancel()
    }

    func stop() async {
        let consume = consumeTask
        consumeTask = nil
        consume?.cancel()
        // Join the consumer so it can't touch session state after we return.
        _ = await consume?.value
        endSession()
        print("[AppleSpeechEngine] Stopped")
    }
}
