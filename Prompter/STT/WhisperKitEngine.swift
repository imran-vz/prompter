import Foundation
@preconcurrency import AVFoundation
import WhisperKit

/// WhisperKit-based engine, fed from the shared audio pipeline.
///
/// One consumer task converts incoming buffers to 16 kHz mono and appends them
/// to a rolling window *in order* (no per-buffer task spawning). A second task
/// periodically transcribes the window and emits partials; `finishUtterance`
/// commits the window as a final and clears it so each turn starts clean.
nonisolated final class WhisperKitEngine: STTEngine, @unchecked Sendable {
    var displayName: String { "WhisperKit (\(modelName))" }

    private let modelName: String
    private var whisperKit: WhisperKit?

    private let window = SampleWindow()
    private var consumeTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?

    private let transcribeLock = NSLock()
    private var isTranscribing = false
    private var lastEmittedText = ""

    /// Skip transcription when the window's peak energy is below this — Whisper
    /// hallucinates on silence, and skipping saves a full model pass.
    private let energyGate: Float = 0.004

    /// ISO 639-1 code passed to the decoder, or nil to let Whisper detect it.
    private let language: String?

    init(modelName: String, language: String? = nil) {
        self.modelName = modelName
        self.language = language
    }

    /// Whisper's `.en` variants only recognise English. Names come either bare
    /// ("small.en") or as repo folders, optionally with a size suffix
    /// ("openai_whisper-small.en_217MB").
    static func isEnglishOnly(_ model: String) -> Bool {
        model.range(of: #"\.en($|_)"#, options: .regularExpression) != nil
    }

    // MARK: - Lifecycle

    func prepare() async throws {
        let audioGranted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        guard audioGranted else { throw STTError.noMicrophoneAccess }

        // An English-only Model fed another language still "listens" but
        // produces nothing the aligner can match, so refuse it up front.
        if let language, language != "en", Self.isEnglishOnly(modelName) {
            throw STTError.modelLanguageMismatch(model: modelName, language: language)
        }

        if whisperKit == nil {
            // Load only from a Model the user downloaded in Settings. Letting
            // WhisperKit download here would hide a multi-minute (or offline,
            // never-ending) download behind "Starting…".
            let name = modelName
            guard let folder = await MainActor.run(body: {
                WhisperKitModelManager.shared.modelFolder(for: name)
            }) else {
                throw STTError.modelNotDownloaded(modelName)
            }
            do {
                whisperKit = try await WhisperKit(WhisperKitConfig(
                    model: modelName,
                    modelFolder: folder,
                    verbose: false,
                    logLevel: .error,
                    download: false
                ))
            } catch {
                throw STTError.engineNotAvailable
            }
        }
    }

    func start(audio: AsyncStream<AudioCaptureEvent>) async throws -> AsyncStream<TranscriptionChunk> {
        guard whisperKit != nil else { throw STTError.engineNotAvailable }

        window.clear()
        let (stream, continuation) = AsyncStream.makeStream(of: TranscriptionChunk.self)
        transcribeLock.withLock {
            lastEmittedText = ""
            output = continuation
        }

        // Consumer: strict in-order conversion + append.
        consumeTask = Task.detached(priority: .userInitiated) { [weak self] in
            var converter: AudioFormatConverter?
            for await event in audio {
                guard let self, !Task.isCancelled else { break }
                switch event {
                case .formatChanged:
                    converter = nil   // rebuild for the new device format
                case .chunk(let chunk):
                    let format = chunk.buffer.format
                    if converter == nil || converter?.inputFormat != format {
                        converter = AudioFormatConverter(inputFormat: format)
                    }
                    guard let samples = converter?.convertTo16kMono(chunk.buffer) else { continue }
                    self.window.append(samples, rms: chunk.rms)
                }
            }
            // Audio ended (not a cancellation) — drain the window as a final so
            // trailing words survive a pipeline restart. Retry while a periodic
            // pass holds the busy flag, bounded so teardown can't hang.
            if !Task.isCancelled, let self {
                self.requestFinal()
                for _ in 0..<8 where self.hasPendingFinal && !Task.isCancelled {
                    await self.transcribeWindow()
                    if self.hasPendingFinal {
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
            }
            continuation.finish()
            print("[WhisperKitEngine] Audio stream ended")
        }

        // Transcriber: periodic pass over the current window.
        transcribeTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.5))
                guard !Task.isCancelled, let self else { return }
                await self.transcribeWindow()
            }
        }

        await MainActor.run {
            WhisperKitModelManager.shared.markUsed(model: modelName)
        }

        return stream
    }

    /// Mark the current turn for commit. The flag — not a detached task — is
    /// consumed by the next serialized transcribe pass, so a final can never be
    /// lost to a busy-skip; it is cleared only once the final is actually
    /// emitted (or the window has nothing to commit).
    func finishUtterance() {
        requestFinal()
    }

    private func requestFinal() {
        transcribeLock.withLock { pendingFinal = true }
    }

    private var hasPendingFinal: Bool {
        transcribeLock.withLock { pendingFinal }
    }

    func stop() async {
        let consume = consumeTask
        let transcribe = transcribeTask
        consumeTask = nil
        transcribeTask = nil
        consume?.cancel()
        transcribe?.cancel()
        // Join both workers so no stale pass can yield into a future session's
        // stream or append into a cleared window after we return.
        _ = await consume?.value
        _ = await transcribe?.value
        transcribeLock.withLock {
            output = nil
            pendingFinal = false
        }
        window.clear()
        print("[WhisperKitEngine] Stopped")
    }

    // MARK: - Transcription

    private var output: AsyncStream<TranscriptionChunk>.Continuation?
    private var pendingFinal = false

    private func transcribeWindow() async {
        guard let whisperKit else { return }

        let (target, busy, wantsFinal): (AsyncStream<TranscriptionChunk>.Continuation?, Bool, Bool) = transcribeLock.withLock {
            let wasBusy = isTranscribing
            if !wasBusy { isTranscribing = true }
            return (output, wasBusy, pendingFinal)
        }

        guard !busy, let target else { return }
        defer {
            transcribeLock.withLock { isTranscribing = false }
        }

        let (samples, peakRMS) = window.snapshot()
        guard !samples.isEmpty, peakRMS >= energyGate else {
            // Nothing to transcribe — a requested final has nothing to commit.
            if wantsFinal {
                transcribeLock.withLock {
                    pendingFinal = false
                    lastEmittedText = ""
                }
                window.clear()
            }
            return
        }

        do {
            let options = language.map { DecodingOptions(language: $0, detectLanguage: false) }
            let results: [TranscriptionResult] = try await whisperKit.transcribe(audioArray: samples,
                                                                                 decodeOptions: options)
            let text = (results.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            if wantsFinal {
                // Commit the turn: emit final, reset dedup, clean the window.
                transcribeLock.withLock {
                    pendingFinal = false
                    lastEmittedText = ""
                }
                if !text.isEmpty {
                    target.yield(TranscriptionChunk(text: text, isFinal: true))
                }
                window.clear()
            } else {
                guard !text.isEmpty else { return }
                let changed: Bool = transcribeLock.withLock {
                    let didChange = text != lastEmittedText
                    if didChange { lastEmittedText = text }
                    return didChange
                }
                if changed {
                    target.yield(TranscriptionChunk(text: text, isFinal: false))
                }
            }
        } catch {
            // A failed final stays pending and is retried on the next pass.
            print("[WhisperKitEngine] Transcription error: \(error)")
        }
    }
}

// MARK: - Sample Window

/// Rolling window of 16 kHz mono samples with peak-RMS tracking.
/// Lock-protected; written by the consumer task, snapshotted by the transcriber.
nonisolated private final class SampleWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var peakRMS: Float = 0

    private let maxSamples = 16_000 * 8   // 8s of context

    func append(_ newSamples: [Float], rms: Float) {
        lock.lock()
        samples.append(contentsOf: newSamples)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        peakRMS = max(peakRMS * 0.995, rms)   // slow decay so old loudness fades
        lock.unlock()
    }

    func snapshot() -> ([Float], Float) {
        lock.lock()
        defer { lock.unlock() }
        return (samples, peakRMS)
    }

    func clear() {
        lock.lock()
        samples = []
        peakRMS = 0
        lock.unlock()
    }
}

// MARK: - Format Conversion

/// Converts device-format PCM buffers to 16 kHz mono Float32 for Whisper.
nonisolated private final class AudioFormatConverter {
    let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat

    init?(inputFormat: AVAudioFormat) {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { return nil }
        self.inputFormat = inputFormat
        self.targetFormat = target
        self.converter = inputFormat == target ? nil : AVAudioConverter(from: inputFormat, to: target)
    }

    func convertTo16kMono(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let converter else {
            guard let data = buffer.floatChannelData?[0] else { return nil }
            return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
        let capacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate).rounded(.up) + 16
        )
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var error: NSError?
        var consumed = false
        converter.convert(to: converted, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = converted.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: data, count: Int(converted.frameLength)))
    }
}
