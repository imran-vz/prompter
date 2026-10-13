//
//  ScriptTextView.swift
//  Prompter
//
//  Draws the Script in the Prompter with TextKit, so the exact on-screen line
//  of any word is known. Speech tracking scrolls by that position instead of
//  guessing from word counts (ADR 0007).
//

import AppKit
import SwiftUI

/// Answers "where on screen is this part of the Script?" for speech tracking.
protocol ScriptLayoutProviding: AnyObject {
    /// Vertical centre of the line holding the character at `offset` (UTF-16,
    /// in Script coordinates), measured from the top of the text.
    func lineMidY(forUTF16Offset offset: Int) -> CGFloat?
}

/// Everything that affects how the Script is drawn. Compared before
/// restyling, so scrolling (which changes none of it) never re-lays out text.
struct ScriptRenderContent: Equatable {
    var script: String
    var fontSize: CGFloat
    var fontDesign: Font.Design
    var lineSpacing: CGFloat
    var alignment: NSTextAlignment
    var textColor: NSColor
    var accentColor: NSColor
    /// UTF-16 offset up to which the text is dimmed as already read.
    var readUpTo: Int
    /// Range of the Current word, highlighted while speech tracking.
    var currentWord: NSRange?

    static let endMarker = "\n\n[the end]"
    static let placeholder = "Put some text in Settings..."
}

// MARK: - SwiftUI wrapper

struct ScriptTextView: NSViewRepresentable {
    let content: ScriptRenderContent
    let onLayoutProvider: (ScriptLayoutProviding) -> Void

    func makeNSView(context: Context) -> ScriptTextNSView {
        let view = ScriptTextNSView()
        view.apply(content)
        onLayoutProvider(view)
        return view
    }

    func updateNSView(_ nsView: ScriptTextNSView, context: Context) {
        nsView.apply(content)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ScriptTextNSView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }
}

// MARK: - TextKit view

final class ScriptTextNSView: NSView, ScriptLayoutProviding {
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
    private var current: ScriptRenderContent?
    /// Length of the Script part of the storage (excludes the end marker), so
    /// offsets past the Script clamp to its last line.
    private var scriptLength = 0

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Purely visual: hover, clicks and the scroll wheel go to the Prompter.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ content: ScriptRenderContent) {
        guard content != current else { return }
        let textChanged = content.script != current?.script
        current = content
        storage.setAttributedString(Self.attributed(content))
        scriptLength = content.script.isEmpty ? 0 : (content.script as NSString).length
        if textChanged { invalidateIntrinsicContentSize() }
        needsDisplay = true
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        if container.size.width != width {
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if container.size.width != newSize.width {
            container.size = NSSize(width: newSize.width, height: .greatestFiniteMagnitude)
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let glyphs = layoutManager.glyphRange(forBoundingRect: dirtyRect, in: container)
        layoutManager.drawBackground(forGlyphRange: glyphs, at: .zero)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }

    func lineMidY(forUTF16Offset offset: Int) -> CGFloat? {
        guard scriptLength > 0 else { return nil }
        let index = min(max(0, offset), scriptLength - 1)
        layoutManager.ensureLayout(for: container)
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let line = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        return line.midY
    }

    // MARK: - Styling

    private static let stageDirection = try? NSRegularExpression(pattern: "\\[[^\\]]+\\]")

    private static func attributed(_ c: ScriptRenderContent) -> NSAttributedString {
        let isEmpty = c.script.isEmpty
        let text = (isEmpty ? ScriptRenderContent.placeholder : c.script) + ScriptRenderContent.endMarker
        let s = NSMutableAttributedString(string: text)
        let full = NSRange(location: 0, length: s.length)
        let scriptRange = NSRange(location: 0, length: isEmpty ? 0 : (c.script as NSString).length)

        let font = Self.font(size: c.fontSize, design: c.fontDesign)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = c.alignment
        paragraph.lineSpacing = c.lineSpacing

        s.addAttributes([.font: font, .foregroundColor: c.textColor, .paragraphStyle: paragraph], range: full)

        // Dim already-read text
        if c.readUpTo > 0, scriptRange.length > 0 {
            let r = NSRange(location: 0, length: min(c.readUpTo, scriptRange.length))
            s.addAttribute(.foregroundColor, value: c.textColor.withAlphaComponent(0.35), range: r)
        }

        // Stage directions [like this]: dimmed and italic
        for m in stageDirection?.matches(in: text, range: full) ?? [] {
            s.addAttribute(.foregroundColor, value: c.textColor.withAlphaComponent(0.3), range: m.range)
            let desc = font.fontDescriptor.withSymbolicTraits(.italic)
            if let italic = NSFont(descriptor: desc, size: font.pointSize) {
                s.addAttribute(.font, value: italic, range: m.range)
            }
        }

        // Current word: colour only, so highlighting never reflows the text.
        if let word = c.currentWord, word.length > 0, NSMaxRange(word) <= scriptRange.length {
            s.addAttributes([
                .foregroundColor: c.accentColor,
                .backgroundColor: c.accentColor.withAlphaComponent(0.16),
            ], range: word)
        }
        return s
    }

    private static func font(size: CGFloat, design: Font.Design) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        let fontDesign: NSFontDescriptor.SystemDesign
        switch design {
        case .serif: fontDesign = .serif
        case .rounded: fontDesign = .rounded
        case .monospaced: fontDesign = .monospaced
        default: return base
        }
        guard let desc = base.fontDescriptor.withDesign(fontDesign) else { return base }
        return NSFont(descriptor: desc, size: size) ?? base
    }
}
