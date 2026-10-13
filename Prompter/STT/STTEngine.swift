import Foundation

/// VAD state owned by STTController and consumed by the ViewModel for scroll gating.
nonisolated enum VADState: Equatable, Sendable, Hashable {
    case silence
    case speaking
    case trailingEdge
}

/// A transcription result emitted by an STT engine.
///
/// Engines emit only text — voice-activity detection lives in the controller,
/// fed directly from the audio pipeline, so transcription can never be gated
/// or dropped by VAD misfires.
nonisolated struct TranscriptionChunk: Equatable, Sendable {
    let text: String
    /// `true` when the engine has committed this utterance and will start the
    /// next one from scratch. The controller merges finals into the
    /// accumulated transcript.
    let isFinal: Bool
}

nonisolated enum STTError: Error, Equatable {
    case notAuthorized
    case noMicrophoneAccess
    case engineNotAvailable
    /// The on-device speech model for this language isn't installed. Not
    /// fatal: the Pipeline keeps retrying, so it recovers once the user adds
    /// the language in System Settings.
    case onDeviceRecognitionUnavailable(language: String)
    /// The selected WhisperKit Model hasn't been downloaded yet. Not fatal for
    /// the same reason: it starts as soon as the download finishes.
    case modelNotDownloaded(String)
    /// The selected WhisperKit Model is English-only (`.en`) but the speech
    /// language isn't English. Not fatal: it starts once the user picks a
    /// multilingual Model or switches the language.
    case modelLanguageMismatch(model: String, language: String)
    case alignmentFailed
    case unknown(String)

    /// Fatal errors should not be retried by the supervisor (e.g. the user
    /// denied permissions — retrying can never succeed).
    var isFatal: Bool {
        switch self {
        case .notAuthorized, .noMicrophoneAccess: return true
        default: return false
        }
    }
}

/// A speech-to-text engine that consumes a shared audio stream and produces
/// transcription chunks.
///
/// Contract:
/// - `start(audio:)` returns a stream that finishes only when the audio stream
///   finishes or `stop()` is called. Transient recognition failures must be
///   handled *internally* (engines recreate their recognition sessions); the
///   supervisor treats a finished stream as "engine down" and restarts.
/// - Engines must consume audio events in order, on a single task.
nonisolated protocol STTEngine: AnyObject {
    var displayName: String { get }

    func setContextualStrings(from script: String)

    /// Acquire permissions / load models. May be called repeatedly.
    func prepare() async throws

    /// Begin transcribing the given audio stream.
    func start(audio: AsyncStream<AudioCaptureEvent>) async throws -> AsyncStream<TranscriptionChunk>

    /// Force the engine to finalize the current utterance now (called at VAD
    /// end-of-turn). Engines emit a final chunk and begin a fresh session.
    func finishUtterance()

    func stop() async
}

extension STTEngine {
    nonisolated func setContextualStrings(from script: String) {}
    nonisolated func finishUtterance() {}
}

// MARK: - Audio Utilities

/// Root-mean-square energy of a float PCM buffer.
nonisolated func audioRMS(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    let sumSq = samples.reduce(0) { $0 + $1 * $1 }
    return sqrt(sumSq / Float(samples.count))
}

/// Pointer-based variant — avoids allocating an intermediate `[Float]` when the
/// raw channel data is already available from `AVAudioPCMBuffer.floatChannelData`.
nonisolated func audioRMS(_ pointer: UnsafePointer<Float>, count: Int) -> Float {
    guard count > 0 else { return 0 }
    var sumSq: Float = 0
    for i in 0..<count { sumSq += pointer[i] * pointer[i] }
    return sqrt(sumSq / Float(count))
}
