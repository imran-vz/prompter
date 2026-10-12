# Pluggable on-device speech Engines: Apple Speech default, WhisperKit optional

Speech recognition sits behind the `STTEngine` protocol (`prepare`, `start(audio:)`, `finishUtterance`, `stop`). There are two implementations, chosen with `STTEngineType`; the default is `.apple`.

- **`AppleSpeechEngine`**: `SFSpeechRecognizer` with locale `en-US`, `taskHint = .dictation` and `requiresOnDeviceRecognition = true` ("on-device = ~200ms faster"). It receives contextual strings built from the Script's words longer than 3 letters, adjacent word pairs, and `[bracketed]` directions "to boost recognition accuracy".
- **`WhisperKitEngine`**: an 8 s rolling window of 16 kHz mono audio, transcribed every 0.5 s to produce Partials. `finishUtterance` commits the window as a Final and clears it "so each turn starts clean". Passes are skipped when the window's peak energy is below 0.004 because "Whisper hallucinates on silence, and skipping saves a full model pass."

## Consequences

- Models are downloaded on demand through `WhisperKit.download` and stored under `Documents/huggingface/models/argmaxinc/whisperkit-coreml`. `WhisperKitModelManager` records which Models are downloaded, their paths, and when each was last used in `UserDefaults`. This is why the app needs the `network.client` entitlement.
- If the online Model list can't be fetched, a hard-coded list (`tiny` … `large-v3`) is used.
- Swapping engine or Model calls `STTController.setEngine`, which stops the Pipeline and restarts it if it was running.

_Reason for choosing these two Engines over others: not recorded in the code._
