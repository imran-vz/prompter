# One audio capture service owns the microphone

`AudioCaptureService` is the "sole owner of the microphone". It copies each tap buffer on the real-time audio thread and "broadcasts ordered chunks to any number of subscribers (STT engines, VAD)" (`STT/AudioCaptureService.swift`). Each subscriber gets its own `AsyncStream` with `bufferingNewest(64)`: "if a consumer stalls, the oldest chunks are dropped rather than growing memory without bound." Engines receive an `AsyncStream<AudioCaptureEvent>` and never touch `AVAudioEngine`.

This replaced the design in the initial commit (`19b1824`), where each Engine created its own `AVAudioEngine` and ran its own VAD (commit `61e4886`, "Refactor speech pipeline for resilient audio capture").

## Consequences

- When the audio configuration changes (`AVAudioEngineConfigurationChange`), the service reinstalls the tap, retrying up to 10 times 0.5 s apart, and broadcasts `.formatChanged`. That tells Engines to "rebuild converters / recognition requests".
- `start()` is idempotent and tears down any running engine first, "so a stale tap can never linger."
- **Mute zeroes buffers instead of stopping capture**: when muted, the service produces "a zeroed one of identical shape … so downstream timing is unaffected", and reports `rms = 0`. The mute flag (`MicState`) is read on the audio thread under a lock.
- The tap callback does only "the minimum: deep-copy, RMS, yield"; start/stop/config changes are serialised on a dedicated dispatch queue "so state transitions can never interleave."
