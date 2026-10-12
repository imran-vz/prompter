# A supervisor restarts the whole Pipeline; Engines heal their own sessions

`STTController` runs "one supervisor task [that] owns the whole chain. If any link dies (recognition stream ends, capture fails), the chain is torn down and restarted with backoff. The pipeline can only be 'off' if the user turned it off or permissions are denied" (`STTController.swift`). Backoff starts at 0.5 s and doubles up to 5 s. Errors for which `STTError.isFatal` is true (`.notAuthorized`, `.noMicrophoneAccess`) end the loop with status `.failed`, because "retrying can never succeed" (`STT/STTEngine.swift`).

Short-lived recogniser failures are kept away from the supervisor. The `STTEngine` contract says: "Transient recognition failures must be handled *internally* (engines recreate their recognition sessions); the supervisor treats a finished stream as 'engine down' and restarts." `AppleSpeechEngine` does this because "SFSpeechRecognitionTask ends on its own (errors, ~1-minute on-device limits, finals after pauses)". It opens a fresh session on the next audio chunk, at most once every 0.5 s, "so a recognizer that fails instantly … doesn't spin at audio-buffer rate."

## Consequences

- A `generation` counter is bumped on every stop and Engine swap; "stale supervisor loops see a mismatch and exit instead of fighting the new one for the capture service."
- The supervisor subscribes to capture before starting it, "so no chunk is missed".
- When audio ends normally (not cancellation), Engines drain a last Final so trailing words survive a restart: Apple waits up to ~1 s, WhisperKit retries up to 8 passes 250 ms apart.
- `stop()` on each Engine joins its worker tasks so nothing stale writes into the next session.
