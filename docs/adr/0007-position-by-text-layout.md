# Position the Prompter by the real text layout

Speech tracking used to turn an Alignment into a scroll position by proportion: the matched word's index divided by the Script's word count, times the content height. That ignores line wrapping, blank lines between paragraphs, the top inset and the `[the end]` marker, so the line being read drifted away from the Reading position, worst in Scripts with uneven paragraphs.

The Prompter now draws the Script with TextKit (`ScriptTextView`, an `NSLayoutManager` in a plain `NSView`) instead of a SwiftUI `Text`. The aligner returns the Current word as a UTF-16 range in the Script, and `PrompterViewModel.handleAlignment` asks the text view for the centre of the line holding it. The Prompter scrolls so that line sits on the Reading position. The word-count proportion is kept only as a fallback before the first layout.

## Consequences

- The text the user sees and the text that is measured are the same layout, so positions are exact at any width, font, size or line spacing.
- The Script is restyled only when something that affects drawing changes (`ScriptRenderContent` is compared first). Scrolling moves the view; it never re-lays out text.
- The Current word highlight is colour only (foreground and background), so it can't reflow the text while the speaker reads.
- Styling is now AppKit (`NSFont`, `NSParagraphStyle`), so new appearance options have to be added in `ScriptTextNSView.attributed` rather than as SwiftUI modifiers.
- Script offsets map 1:1 to the drawn text: nothing may be prepended to the Script in the view. Extra space above it goes in `PrompterViewModel.scriptTopInset`.
