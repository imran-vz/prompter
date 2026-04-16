import Foundation

/// VAD state emitted by STT engines and consumed by STTController.
enum VADState: Equatable, Sendable, Hashable {
    case silence
    case speaking
    case trailingEdge
}

struct TranscriptionChunk: Equatable {
    let text: String
    let isFinal: Bool
    let timestamp: Date
    /// VAD state at the time this chunk was produced.
    /// Defaults to `.speaking` so existing construction sites are unaffected.
    let vadState: VADState

    init(text: String, isFinal: Bool, timestamp: Date, vadState: VADState = .speaking) {
        self.text = text
        self.isFinal = isFinal
        self.timestamp = timestamp
        self.vadState = vadState
    }

    /// Convenience: a pure VAD transition event with no transcript text.
    static func vadEvent(_ state: VADState) -> TranscriptionChunk {
        TranscriptionChunk(text: "", isFinal: false, timestamp: Date(), vadState: state)
    }
}

enum STTError: Error, Equatable {
    case notAuthorized
    case noMicrophoneAccess
    case engineNotAvailable
    case alignmentFailed
    case unknown(String)
}

protocol STTEngine: AnyObject {
    var displayName: String { get }
    var isRunning: Bool { get }

    /// Creates a fresh transcription stream. Callers should consume the returned stream directly.
    func makeTranscriptionStream() -> AsyncStream<TranscriptionChunk>

    func setContextualStrings(from script: String)

    func prepare() async throws
    func start() async throws
    func stop() async
}

extension STTEngine {
    func setContextualStrings(from script: String) {}
}

// MARK: - Audio Utilities

/// Root-mean-square energy of a float PCM buffer. Used by both STT engines for VAD.
func audioRMS(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    let sumSq = samples.reduce(0) { $0 + $1 * $1 }
    return sqrt(sumSq / Float(samples.count))
}

/// Pointer-based variant — avoids allocating an intermediate `[Float]` when the
/// raw channel data is already available from `AVAudioPCMBuffer.floatChannelData`.
func audioRMS(_ pointer: UnsafePointer<Float>, count: Int) -> Float {
    guard count > 0 else { return 0 }
    var sumSq: Float = 0
    for i in 0..<count { sumSq += pointer[i] * pointer[i] }
    return sqrt(sumSq / Float(count))
}
