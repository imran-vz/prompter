# Prompter

A macOS teleprompter attached to the notch that scrolls a Script either at a fixed speed or by following the speaker's voice. Terms below come from the code and UI. Where the code uses a different name from the UI, the code name is noted after "In code".

## Language

### The prompter

**Script**:
The text the speaker reads, entered in the Script tab of Settings.
In code: `text`, `script`.

**Stage direction**:
A `[bracketed]` note inside the Script, such as `[pause]` or `[smile]`.

**Prompter**:
The floating panel attached to the notch that displays the Script.

**Control strip**:
The column of buttons that appears beside the Prompter on hover.
In code: "Hover Controls" in the UI.

**Reading position**:
The fraction of the Prompter's height at which the current word should sit.
In code: `readingLineOffset`.

**Current word**:
The word in the Script the speaker was last heard saying, highlighted in the Prompter.
In code: `currentWordRange`.

**Read-up-to point**:
The spot in the Script up to which the speaker has been heard; text before it is dimmed.
In code: `readUpToOffset`.

**Playback**:
Scrolling at a fixed speed, started with Play.
In code: `isPlaying`, `speed`.

**Manual override**:
The 3-second window after the user scrolls by hand, during which Speech tracking does not move the Prompter.

**Follow active display**:
Showing the Prompter on whichever screen the mouse is on.

### Speech tracking

**Speech tracking**:
Scrolling the Prompter to follow what the speaker is saying.
In code: `sttEnabled`, "STT".

**Pipeline**:
The full speech-tracking chain from microphone to Alignment, started, stopped and restarted as one unit. Its status is idle, starting, listening, restarting or failed.

**Engine**:
A speech recogniser that turns audio into Transcription chunks: Apple Speech or WhisperKit.
In code: `STTEngine`.

**Model**:
A downloadable WhisperKit weight set such as `tiny` or `base.en`.

**Contextual strings**:
Words and word pairs taken from the Script and given to the Apple Speech Engine to improve recognition.

**Transcription chunk**:
One piece of text emitted by an Engine, either a Partial or a Final.

**Partial**:
A provisional transcription of the current Utterance.

**Final**:
A transcription the Engine has committed; the next Utterance starts from scratch.
In code: `isFinal`.

**Utterance**:
The span of speech an Engine transcribes as one unit, ending with a Final.

**Accumulated transcript**:
All Finals since the Pipeline started or was reset, joined with overlapping words merged.

**VAD state**:
Whether the speaker is currently in Silence, Speaking or the Trailing edge, judged from microphone energy.

**Trailing edge**:
The pause right after speech, before the VAD state commits to Silence; speech that resumes here carries on the same Turn.

**Turn**:
A stretch of speaking that ends when the VAD state settles into Silence. When a Turn ends, the Engine commits a Final.

**Speech evidence**:
Words arriving from the Engine, treated as proof the speaker is talking whatever the microphone energy says.

**Alignment**:
Locating the latest transcript within the Script to get a reading position and a Confidence.

**Confidence**:
How closely the transcribed words match the Script at the aligned position, from 0 to 1.

**Mute**:
Silencing microphone input while the Pipeline keeps running.
In code: `micMuted`, `MicState`.
