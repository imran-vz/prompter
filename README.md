# Prompter

A teleprompter for macOS that sits under the notch and scrolls as you speak.

Prompter runs from the menu bar. It shows a floating panel at the top of the screen, shaped to blend into the notch. Paste a script and either press Play to scroll at a fixed speed, or turn on Speech Tracking: Prompter listens through the microphone, works out where you are in the script, and scrolls to keep that spot on your reading line.

## Features

- **Speech tracking**: scrolls so the line you are reading stays on your reading line, highlights each word as you say it, and dims the text you have already read. A small badge shows the latest words it heard. Numbers match whether you say "three" or the recogniser writes "3", and stage directions are ignored.
- **Two speech engines**: Apple Speech (on-device) or [WhisperKit](https://github.com/argmaxinc/WhisperKit) models, which you download, select and delete in Settings. Pick the language you read in, or follow the system language.
- **Recovers on its own**: if the audio device changes or the recogniser stops, the speech pipeline restarts automatically. The Speech tab shows its status (Off / Starting… / Listening / Reconnecting… / error), says why it is reconnecting, and links to the right System Settings pane when a permission or language is missing.
- **Mic mute**: stops listening without turning speech tracking off.
- **Hidden from screen sharing**: by default the Prompter doesn't appear in screen shares, recordings or screenshots.
- **Notch-attached panel**: floats above other windows on every Space, including full-screen apps, without taking focus from the app you are presenting from. You can set its width (150–600) and height (80–500), its left/centre/right position, and which screen it uses, or let it follow the screen your mouse is on.
- **Appearance**: Midnight, Dark and Light themes; Default, Serif, Rounded and Monospaced fonts; text size 8–80; line spacing; text alignment; adjustable top and bottom fades.
- **Hover**: a control strip appears on hover (play/pause, scroll back, reset, mic mute, minimise, settings). Scrolling can pause while the mouse is over the text, and the scroll wheel moves the script by hand.
- **Progress bar**: a thin vertical bar on the right edge.
- **Stage directions**: `[bracketed]` text is dimmed and italic in the prompter and the script editor.
- **Import**: load a script from a text, Markdown, RTF or Word file.

The script ends with a `[the end]` marker, and playback stops by itself when it gets there.

## Requirements

- macOS 14 Sonoma or later
- Microphone and Speech Recognition permissions for speech tracking
- For Apple Speech, the on-device model for your language (System Settings › Keyboard › Dictation)
- Network access only to download WhisperKit models

## Usage

1. Click the menu-bar icon and open **Settings** (`⌘,`).
2. Type or paste your script in the **Script** tab.
3. Either press **Play** to scroll at the speed set in **Behavior**, or turn on **Speech Tracking** in the **Speech** tab and start reading.

### Keyboard shortcuts

Global shortcuts work from any app. Turn them off in **Behavior** if they clash with something you use.

| Shortcut | Action |
|----------|--------|
| `⌃⌥⌘P` | Play / pause |
| `⌃⌥⌘H` | Show / hide prompter |
| `⌃⌥⌘R` | Reset to the top |
| `⌃⌥⌘↑` / `⌃⌥⌘↓` | Scroll by hand (speech tracking holds off for 3 s) |

After you click the prompter, these plain keys also work until you click elsewhere:

| Key | Action |
|-----|--------|
| `Space` | Play / pause |
| `↑` / `↓` | Scroll by hand |
| `←` / `→` | Speed down / up |
| `R` | Reset to the top |

The menu-bar menu also has Settings (`⌘,`) and Exit (`⌘Q`).

### Settings

- **Script**: the script editor, word count and reading time, import from a file
- **Appearance**: font style, size, line spacing, alignment, theme, top and bottom fade
- **Layout**: width, height, horizontal alignment, screen, follow active display
- **Behavior**: scroll speed, pause on hover, hover controls, progress bar, global shortcuts, hide from screen sharing
- **Speech**: speech tracking, engine, WhisperKit model, language, mute microphone, reading position, smoothing

The Settings window also has Play/Pause, Reset (asks for confirmation) and Show/Hide buttons. All settings are saved automatically.

## Building from source

```sh
git clone git@github.com:imran-vz/prompter.git
cd prompter
xcodebuild -scheme Prompter -configuration Debug -destination 'platform=macOS' build
```

Or open `Prompter.xcodeproj` and run the `Prompter` scheme. WhisperKit is pulled in through Swift Package Manager.

Run the unit tests (tokenizer, alignment, transcript merging):

```sh
xcodebuild test -scheme Prompter -destination 'platform=macOS'
```

To build a signed and notarized `Prompter.zip` for download, see the instructions at the top of `scripts/release.sh`, then run `TEAM_ID=<your team ID> scripts/release.sh`.

`marketing/` holds a separate landing page built with Vite and Tailwind (`bun install`, then `bun run dev` / `bun run build`; the repo has a `bun.lock`).

## Privacy

- Apple Speech runs with `requiresOnDeviceRecognition = true`. WhisperKit models run locally.
- Audio is kept in memory only. Nothing in the app writes audio to disk or sends it over the network.
- The app is sandboxed. It has network access only so it can download WhisperKit models, and only when you click Download.
- The prompter is excluded from screen sharing and recordings unless you turn that off.

Permissions:
- **Microphone**: "Prompter uses the microphone to listen to your speech and auto-scroll the script."
- **Speech Recognition**: "Prompter uses speech recognition to match your spoken words to the script."

## Support

[Open an issue](https://github.com/imran-vz/prompter/issues) for bugs or feature requests.

## Acknowledgements

Inspired by [NotchPrompter](https://github.com/jpomykala/NotchPrompter). `HighlightingTextEditor.swift` comes from that project.

## License

[MIT](LICENSE)
