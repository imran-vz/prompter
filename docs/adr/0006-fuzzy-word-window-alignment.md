# Align by fuzzy word-window matching with a forward bias

`TranscriptAligner` (an actor, "so all work happens off the main thread") tokenizes the Script and the transcript with `ScriptTokenizer`: lowercase letters only, apostrophes inside words dropped, digits spelled out, stage directions skipped, and each word's UTF-16 range in the Script kept. It then compares the last 6 transcribed words (Partials) or last 10 (Finals) against same-length windows of the Script, scoring by word-level Levenshtein similarity (`STT/TranscriptAligner.swift`).

Search widens only as needed: first near the last match, then at sentence starts if the best score is below 0.7, then the whole Script if it is below 0.5. A result needs a score above 0.35. Backward jumps are rejected unless the match is strong: more than 5 words back needs ≥ 0.7, more than 15 needs ≥ 0.85. Progress is anchored to the **last word** of the matched window, which becomes the Current word.

## Consequences

- Alignment runs through one worker where the newest request always wins: "intermediate transcripts are skipped — the newest one is always aligned, and results reach the UI strictly in order" (`STTController.scheduleAlignment`). Results are dropped below Confidence 0.30 for Partials and 0.25 for Finals.
- `PrompterViewModel.handleAlignment` turns the Current word into a screen line (ADR 0007), moves the scroll target forward freely but backward only by more than 60 pt. The display-link tick eases towards the target using the Smoothing setting.

_Reason for fuzzy windows over other alignment methods: not recorded in the code._
