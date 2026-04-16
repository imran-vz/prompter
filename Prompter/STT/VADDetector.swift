import Foundation

/// Voice Activity Detector — energy-based state machine with hysteresis and hangover.
///
/// Call `process(rms:)` on every audio buffer. Returns the new state and whether
/// a transition occurred. Thread-safe: declared as a Swift actor.
///
/// Inspired by Pindrop's end-of-utterance callback pattern:
/// - `.speaking` / `.trailingEdge` → transcription runs normally
/// - `.silence` (after hangover expires) → turn ended, lock teleprompter position
actor VADDetector {

    // MARK: - Thresholds (tunable)

    /// RMS level required to start counting toward speech onset.
    let speechThreshold: Float = 0.015
    /// RMS level below which a speaking frame is considered sub-threshold (hysteresis).
    let silenceThreshold: Float = 0.008
    /// How long RMS must stay above `speechThreshold` before entering `.speaking`.
    let onsetDuration: TimeInterval = 0.15
    /// How long since the last speech frame before committing to `.silence`.
    let hangoverDuration: TimeInterval = 1.4

    // MARK: - State

    private(set) var state: VADState = .silence
    private var onsetStart: Date?
    private var lastSpeechTime: Date = .distantPast

    // MARK: - Processing

    /// Process one audio buffer. Returns `(newState, didTransition)`.
    @discardableResult
    func process(rms: Float, now: Date = Date()) -> (VADState, Bool) {
        let previous = state

        switch state {
        case .silence:
            if rms > speechThreshold {
                if onsetStart == nil { onsetStart = now }
                if now.timeIntervalSince(onsetStart!) >= onsetDuration {
                    state = .speaking
                    lastSpeechTime = now   // prevent instant silence on first sub-threshold frame
                    onsetStart = nil
                }
            } else {
                onsetStart = nil
            }

        case .speaking:
            if rms >= silenceThreshold {
                lastSpeechTime = now
            } else {
                state = .trailingEdge
            }

        case .trailingEdge:
            if rms > speechThreshold {
                // Recovered — speaker resumed mid-breath
                state = .speaking
                lastSpeechTime = now
            } else {
                if rms >= silenceThreshold { lastSpeechTime = now }
                if now.timeIntervalSince(lastSpeechTime) >= hangoverDuration {
                    state = .silence
                }
            }
        }

        return (state, state != previous)
    }

    func reset() {
        state = .silence
        onsetStart = nil
        lastSpeechTime = .distantPast
    }
}
