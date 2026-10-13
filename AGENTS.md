# AGENTS.md

Guidance for coding agents working in this repo.

## Read first

- `CONTEXT.md`: the project glossary (Script, Prompter, Engine, Utterance, Final, Turn, Alignment, …). Use these terms in code, comments and commit messages. Keep it a glossary, free of implementation detail.
- `docs/adr/`: why the architecture looks the way it does. Read the relevant ADR before changing the audio pipeline, VAD, Engines or alignment. Add a new numbered ADR for any decision that is hard to reverse, surprising, and a real trade-off.

## Project

Native macOS menu-bar app in SwiftUI and AppKit.

- Scheme `Prompter`. Tests use Swift Testing in `PrompterTests`, hosted in the app.
- macOS 14.0+, Swift 5 language mode, approachable concurrency, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. **Types are main-actor by default**, so mark audio and background types `nonisolated` explicitly (as the `STT/` types are).
- Sandboxed: a new system capability needs a matching entitlement in `Prompter/Prompter.entitlements`.
- `marketing/` is an unrelated Vite + Tailwind landing page (bun).

## Build and test

```sh
xcodebuild -scheme Prompter -configuration Debug -destination 'platform=macOS' build
xcodebuild test -scheme Prompter -destination 'platform=macOS'
```

Both must succeed after any Swift change. Tests cover the pure parts (tokenizer, aligner, transcript merging); extend them when you touch those. The test host skips the Prompter window and the microphone (`PrompterViewModel.isRunningTests`).

Speech following and on-screen positioning can only be checked by running the app and reading aloud. Say so when a change can't be verified any other way.

CI (`.github/workflows/ci.yml`) runs the tests ad hoc signed (no certificate needed). `scripts/release.sh` archives, signs with Developer ID and notarizes.

## Where things live

File names are self-explanatory; these are the ones that aren't:

- `STTController.swift` is the Pipeline supervisor (capture → Engine + VAD → alignment). Engines and the audio pipeline live in `Prompter/STT/`.
- `PrompterViewModel.swift` holds every user setting, playback, the display-link scroll loop, and the AlignmentResult → scroll target mapping.
- `ScriptTextView.swift` maps text offsets to lines (ADR 0007). Scrolling depends on it.

## Data flow

```
AudioCaptureService ──► Engine ──► TranscriptionChunk ──┐
        │                                               ├─► TranscriptAligner ─► PrompterViewModel.handleAlignment ─► targetOffset
        └──────────► VADDetector (in STTController) ────┘                                                       display-link tick chases it
```

`handleAlignment` asks `ScriptTextView` for the line of the Current word and sets `targetOffset` so that line sits on the Reading position. `tick` moves `offset` towards `targetOffset` only when VAD is not Silence (or Playback is on) and no Manual override is active. `tick` runs every frame, so it must write `offset` only when the value changes.

## Rules that must hold

These are deliberate. Do not "simplify" them away without a new ADR.

**Audio capture** (ADR 0002)

1. Only `AudioCaptureService` touches `AVAudioEngine`. Engines consume an `AsyncStream<AudioCaptureEvent>` and never install taps.
2. The tap callback runs on the real-time audio thread and does the minimum: deep-copy, RMS, yield. Start/stop/config work stays on the service's serial `controlQueue`.
3. Mute zeroes audio; it does not stop capture.

**Engines and the Pipeline** (ADR 0003)

4. An Engine consumes audio in order on one task. No task per buffer.
5. An Engine's output stream finishes only on audio end or `stop()`. Handle short-lived recogniser errors inside the Engine; finishing the stream makes the supervisor restart the whole Pipeline.
6. `stop()` joins its worker tasks before returning, so nothing stale writes into the next session.
7. Every Engine handles `.formatChanged` by rebuilding format-dependent state.
8. Only permission errors are fatal (`STTError.isFatal`). Everything else is retryable.

**VAD** (ADR 0004)

9. VAD never drops transcripts. Engine words call `noteSpeechEvidence` and force Speaking.
10. Only Partials count as Speech evidence. A Final arrives after the Turn ended; counting it would reopen the Turn.

**Focus**

11. The Prompter never activates the app or steals focus, and no keyboard input is watched globally. System-wide shortcuts go through `GlobalHotKeys` only.

## Adding an Engine

1. Add a case to `STTEngineType` (`Models.swift`).
2. Implement `STTEngine` as a `nonisolated final class`:
   - `prepare()` requests permissions and loads models.
   - `start(audio:)` returns a stream of Partials and Finals.
   - `finishUtterance()` commits the current Utterance as a Final.
   - `stop()` cancels and joins its tasks.
3. Wire it up in `PrompterViewModel.updateEngine()` and the Speech tab. Respect `speechLocale`.
4. For anything the user must fix (missing Model, missing language), throw a non-fatal `STTError` and give it a clear message in `STTController.describe`. The Speech tab shows it while the Pipeline retries.

## Adding a setting

Settings are `@Published` on `PrompterViewModel` and saved to `UserDefaults` under keys in `enum K`. Add the property and a key, then entries in `loadSettings`, `saveSettings`, and either the `saveOnly` list or a dedicated sink if changing it has side effects.

`loadSettings` treats `0` as unset for doubles (`.nonZero`), so a setting whose real value can be 0 needs a different default check.

## Conventions

- `// MARK: -` sections, doc comments that explain *why*, and `[ClassName]` prefixes on `print` logging.
- Commit messages are short imperative summaries, e.g. "Refactor speech pipeline for resilient audio capture".
