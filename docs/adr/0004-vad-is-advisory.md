# Voice activity detection is advisory and never gates transcription

`VADDetector` is "advisory, never gating. VAD output controls scroll-chasing and end-of-utterance commits; it must never block transcription. If the recognizer produces words, `noteSpeechEvidence` overrides energy" (`STT/VADDetector.swift`). It runs in `STTController` on its own audio subscription, alongside the Engine rather than in front of it. `TranscriptionChunk` carries only text, "so transcription can never be gated or dropped by VAD misfires" (`STT/STTEngine.swift`).

In the initial commit (`19b1824`), each Engine ran VAD itself and `STTController` dropped transcripts while the state was Silence (`guard vadState != .silence else { return }`). The current code comments give the failure mode this avoids: "never let a miscalibrated VAD freeze the prompter mid-read."

## Consequences

- VAD decides two things. First, whether the Prompter chases the Alignment target: `PrompterViewModel.tick` moves only when the state is not Silence or Playback is on, and it "holds position during silence so turn gaps don't drift the teleprompter". Second, when a Turn ends: Speaking/Trailing edge → Silence calls `engine.finishUtterance()` and runs a final Alignment.
- Thresholds adapt to a tracked noise floor instead of "relying on a fixed RMS constant". Speech starts above max(0.006, 3 × floor), with 150 ms onset and 1.4 s hangover. The floor adapts downward faster than upward "so a loud passage doesn't permanently raise the floor".
