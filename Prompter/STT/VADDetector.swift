import Foundation

/// Voice Activity Detector — adaptive energy-based state machine with
/// hysteresis and hangover.
///
/// Design principles:
/// - **Advisory, never gating.** VAD output controls scroll-chasing and
///   end-of-utterance commits; it must never block transcription. If the
///   recognizer produces words, `noteSpeechEvidence` overrides energy.
/// - **Adaptive thresholds.** The noise floor is tracked continuously so the
///   detector works across quiet and hot microphones instead of relying on a
///   fixed RMS constant.
/// - **Single-threaded.** A plain struct, called in order from the controller's
///   audio loop. No actor hops, no out-of-order processing.
nonisolated struct VADDetector {

    // MARK: - Tunables

    /// How long energy must stay above the speech threshold before entering `.speaking`.
    let onsetDuration: TimeInterval = 0.15
    /// How long since the last speech evidence before committing to `.silence`.
    let hangoverDuration: TimeInterval = 1.4
    /// Absolute lower bound for the speech threshold so electrical noise never
    /// reads as speech on a dead-quiet input.
    let minSpeechThreshold: Float = 0.006

    // MARK: - State

    private(set) var state: VADState = .silence
    private var noiseFloor: Float = 0.003
    private var onsetStart: TimeInterval?
    private var lastSpeechTime: TimeInterval = -.greatestFiniteMagnitude

    private var speechThreshold: Float { max(minSpeechThreshold, noiseFloor * 3.0) }
    private var silenceThreshold: Float { max(minSpeechThreshold * 0.55, noiseFloor * 1.8) }

    // MARK: - Processing

    /// Process one audio chunk's RMS. Returns `(newState, didTransition)`.
    /// `now` is a monotonic-ish timestamp in seconds; callers pass a consistent clock.
    @discardableResult
    mutating func process(rms: Float, now: TimeInterval) -> (VADState, Bool) {
        updateNoiseFloor(rms: rms)
        let previous = state

        switch state {
        case .silence:
            if rms > speechThreshold {
                if onsetStart == nil { onsetStart = now }
                if now - onsetStart! >= onsetDuration {
                    state = .speaking
                    lastSpeechTime = now
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
                if now - lastSpeechTime >= hangoverDuration {
                    state = .silence
                }
            }
        }

        return (state, state != previous)
    }

    /// The recognizer produced words — stronger evidence of speech than energy
    /// thresholds. Forces `.speaking` so a miscalibrated threshold can never
    /// freeze the teleprompter while someone is audibly reading.
    @discardableResult
    mutating func noteSpeechEvidence(now: TimeInterval) -> (VADState, Bool) {
        let previous = state
        state = .speaking
        lastSpeechTime = now
        onsetStart = nil
        return (state, state != previous)
    }

    private mutating func updateNoiseFloor(rms: Float) {
        // Only learn from sub-threshold frames; adapt downward faster than upward
        // so a loud passage doesn't permanently raise the floor.
        guard rms < speechThreshold else { return }
        let alpha: Float = rms < noiseFloor ? 0.05 : 0.01
        noiseFloor = max(0.0005, noiseFloor + alpha * (rms - noiseFloor))
    }

    mutating func reset() {
        state = .silence
        onsetStart = nil
        lastSpeechTime = -.greatestFiniteMagnitude
    }
}
