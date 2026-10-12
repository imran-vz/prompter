# AGENTS.md

Guidance for coding agents working in this repo.

## Read first

- `CONTEXT.md`: the project glossary (Script, Prompter, Engine, Utterance, Final, Turn, Alignment, …). Use those terms in code, comments and commit messages.
- `docs/adr/`: why the architecture looks the way it does. Read the relevant ADR before changing the audio pipeline, VAD, Engines or alignment. When you make a decision that is hard to reverse, surprising, and a real trade-off, add a new numbered ADR.

## Project

Native macOS app in SwiftUI and AppKit. One app target (`Prompter`) and one unit-test target (`PrompterTests`, Swift Testing, hosted in the app).

- Xcode project: `Prompter.xcodeproj`, scheme `Prompter`
- Deployment target macOS 14.0, Swift 5 language mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and approachable concurrency. **Types are main-actor by default**, so mark audio and background types `nonisolated` explicitly (as the `STT/` types already are).
- Dependency: WhisperKit via SPM (`upToNextMajor` from 0.10.0)
- Sandboxed. Entitlements in `Prompter/Prompter.entitlements` (audio input, speech recognition, network client for Model downloads)
- `marketing/` is an unrelated Vite and Tailwind landing page (bun)

## Build

```sh
xcodebuild -scheme Prompter -configuration Debug -destination 'platform=macOS' build
```

```sh
xcodebuild test -scheme Prompter -destination 'platform=macOS'
```

Check that both succeed after any Swift change. Tests cover the pure parts (tokenizer, aligner, transcript merging); add to them when you touch those. Speech behaviour and on-screen positioning can only be checked by running the app and reading aloud, so say so when a change cannot be checked any other way. The test host skips the Prompter window and the microphone (`PrompterViewModel.isRunningTests`).

CI (`.github/workflows/ci.yml`) runs the tests unsigned. `scripts/release.sh` archives, signs with Developer ID and notarizes.

## Layout

```
Prompter/
  PrompterApp.swift          App entry: MenuBarExtra + Settings scene, AppDelegate owns the view model
  PrompterWindow.swift       Notch-attached NSPanel, frame/screen logic, global key monitor
  PrompterView.swift         Prompter container, Control strip, hover, progress bar
  ScriptTextView.swift       TextKit text view: draws the Script, maps offsets to lines (ADR 0007)
  GlobalHotKeys.swift        ⌃⌥⌘ system-wide shortcuts via Carbon RegisterEventHotKey
  PrompterViewModel.swift    All user settings (UserDefaults), playback, display-link scroll loop,
                             maps AlignmentResult → scroll target
  SettingsTab.swift          Settings UI (Script / Appearance / Layout / Behavior / Speech tabs)
  Models.swift               Theme, alignment enums, STTEngineType, NotchConnectedShape
  HighlightingTextEditor.swift  Script editor (from NotchPrompter)
  STTController.swift        Pipeline supervisor: capture → Engine + VAD → alignment
  STT/
    AudioCaptureService.swift   Sole owner of the mic; fans out ordered chunks; mute = zeroed buffers
    STTEngine.swift             Engine protocol, TranscriptionChunk, VADState, STTError
    AppleSpeechEngine.swift     SFSpeechRecognizer, self-healing sessions, contextual strings
    WhisperKitEngine.swift      Rolling 8 s window, periodic transcribe, Final on finishUtterance
    WhisperKitModelManager.swift  Model list/download/delete/last-used
    VADDetector.swift           Adaptive energy VAD with hysteresis and hangover
    ScriptTokenizer.swift       Words + UTF-16 ranges; skips stage directions, spells out numbers
    TranscriptAligner.swift     Actor; fuzzy word-window match → AlignmentResult
    TranscriptMerger.swift      Joins Finals into the capped Accumulated transcript
    MicState.swift              Lock-protected global mute flag read on the audio thread
```

## Data flow

```
AudioCaptureService ──► Engine ──► TranscriptionChunk ──┐
        │                                               ├─► TranscriptAligner ─► PrompterViewModel.handleAlignment ─► targetOffset
        └──────────► VADDetector (in STTController) ────┘                                                       display-link tick chases it
```

`handleAlignment` asks `ScriptTextView` for the line of the Current word and sets `targetOffset` so that line sits on the Reading position. `PrompterViewModel.tick` moves `offset` towards `targetOffset` only when VAD is not Silence (or Playback is on) and no Manual override is active. `tick` runs every frame, so it must only write `offset` when the value changes.

## Rules that must hold

These are deliberate. Do not "simplify" them away without a new ADR.

1. **Only `AudioCaptureService` touches `AVAudioEngine`.** Engines take an `AsyncStream<AudioCaptureEvent>`; they must not install taps (ADR 0002).
2. **The audio tap callback does "the minimum: deep-copy, RMS, yield"** (it runs on the real-time audio thread). Start/stop/config work stays on the service's serial `controlQueue`.
3. **Engines consume audio in order on one task.** Do not spawn a task per buffer.
4. **An Engine's output stream finishes only on audio end or `stop()`.** Short-lived recogniser errors are handled inside the Engine; finishing the stream makes the supervisor restart the whole Pipeline (ADR 0003).
5. **`stop()` must join its worker tasks** before returning so nothing stale writes into the next session.
6. **VAD never drops transcripts.** Engine words call `noteSpeechEvidence` and force Speaking (ADR 0004).
7. **Handle `.formatChanged`** in any new Engine by rebuilding format-dependent state.
8. **Only permission errors are fatal** (`STTError.isFatal`). Anything else should be retryable.
9. **Mute zeroes audio; it does not stop capture.**
10. **The Prompter never activates the app or steals focus**, and no keyboard input is watched globally. System-wide shortcuts go through `GlobalHotKeys` only.
11. **Only Partials count as Speech evidence.** A Final arrives after the Turn ended; counting it would reopen the Turn.

## Adding an Engine

1. Add a case to `STTEngineType` (`Models.swift`).
2. Implement `STTEngine` as a `nonisolated final class`: `prepare()` requests permissions and loads models; `start(audio:)` returns a stream of Partials and Finals; `finishUtterance()` commits the current Utterance as a Final; `stop()` cancels and joins its tasks.
3. Wire it up in `PrompterViewModel.updateEngine()` and the Speech tab. Respect `speechLocale`.
4. Throw a non-fatal `STTError` with a clear `STTController.describe` message for anything the user must fix (missing Model, missing language). The Speech tab shows it while the Pipeline retries.

## Settings

All user-facing settings are `@Published` on `PrompterViewModel` and saved to `UserDefaults` under the keys in `enum K`. To add one, add the property, a key, and entries in `loadSettings`, `saveSettings`, and either the `saveOnly` list or its own sink if changing it has side effects. `loadSettings` treats `0` as "unset" for doubles (`nonZero`), so a setting that can really be 0 needs a different default check.

## Conventions

- Match the existing style: `// MARK: -` sections, doc comments that explain *why*, and `[ClassName]` prefixes in `print` logging.
- Keep `CONTEXT.md` free of implementation detail; it is a glossary, not a spec.
- Commit messages are short imperative summaries (e.g. "Refactor speech pipeline for resilient audio capture").
