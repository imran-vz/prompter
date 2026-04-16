//
//  PrompterView.swift
//  Prompter
//
//  Created by Imran on 13/04/26.
//

import SwiftUI
import AppKit

/// Width of the floating control strip that sits outside the prompter.
let controlStripTotalWidth: CGFloat = 44

// MARK: - Entry Point

struct PrompterView: NSViewRepresentable {
    @ObservedObject var viewModel: PrompterViewModel

    func makeNSView(context: Context) -> PrompterHostingView {
        PrompterHostingView(viewModel: viewModel)
    }

    func updateNSView(_ nsView: PrompterHostingView, context: Context) {
        nsView.updateContent()
    }
}

// MARK: - NSView Wrapper (scroll-wheel interception)

class PrompterHostingView: NSView {
    private let viewModel: PrompterViewModel
    private var hostingView: NSHostingView<PrompterContentView>!
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    init(viewModel: PrompterViewModel) {
        self.viewModel = viewModel
        super.init(frame: .zero)

        let content = PrompterContentView(viewModel: viewModel)
        hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateContent() {
        hostingView.rootView = PrompterContentView(viewModel: viewModel)
    }

    // Tracking area for hover / scroll-wheel

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent)  { isHovering = false }

    override func scrollWheel(with event: NSEvent) {
        guard isHovering else { return }
        viewModel.applyManualScroll(delta: event.scrollingDeltaY * 2.0)
    }
}

// MARK: - Content View

struct PrompterContentView: View {
    @ObservedObject var viewModel: PrompterViewModel
    @State private var contentHeight: CGFloat = 0
    @State private var showControls = false
    @State private var isHoveringPrompter = false
    @State private var wasPlayingBeforeHover = false

    private var theme: PrompterTheme { viewModel.prompterTheme }

    var body: some View {
        HStack(spacing: 0) {
            prompterBody
                .clipShape(NotchConnectedShape(topInvertedRadius: 10, bottomRadius: 16))
                .onHover { handlePrompterHover($0) }

            // Transparent zone for the floating control strip
            ZStack {
                Color.clear
                if showControls && viewModel.showHoverControls {
                    controlStrip
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(x: 6))
                                .animation(.spring(response: 0.3, dampingFraction: 0.75)),
                            removal: .opacity.animation(.easeOut(duration: 0.12))
                        ))
                }
            }
            .frame(width: controlStripTotalWidth)
        }
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                showControls = hovering
            }
        }
    }

    // MARK: Pause-on-Hover

    private func handlePrompterHover(_ hovering: Bool) {
        guard viewModel.pauseOnHover else {
            isHoveringPrompter = false
            wasPlayingBeforeHover = false
            return
        }
        if hovering {
            isHoveringPrompter = true
            wasPlayingBeforeHover = viewModel.isPlaying
            if viewModel.isPlaying { viewModel.pause() }
        } else {
            if isHoveringPrompter, wasPlayingBeforeHover { viewModel.play() }
            isHoveringPrompter = false
            wasPlayingBeforeHover = false
        }
    }

    // MARK: Prompter Body

    private var prompterBody: some View {
        ZStack {
            theme.backgroundColor

            GeometryReader { geo in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    movingText
                        .frame(width: geo.size.width, alignment: .center)
                        .offset(y: -viewModel.offset)
                        .background(HeightReader(height: $contentHeight))
                    Spacer(minLength: 0)
                }
                .clipped()
                .onChange(of: viewModel.offset) { _, val in
                    let limit = contentHeight - viewModel.prompterHeight * 0.25
                    if contentHeight > 0, val >= limit {
                        viewModel.offset = max(0, limit)
                        viewModel.pause()
                    }
                }
                .onChange(of: viewModel.text) { _, _ in viewModel.offset = 0 }
                .onChange(of: contentHeight) { _, val in viewModel.contentHeight = val }
            }

            fadeOverlays

            // Bottom glow line
            VStack {
                Spacer()
                Rectangle()
                    .fill(LinearGradient(
                        colors: [theme.accentColor.opacity(0), theme.accentColor.opacity(0.18)],
                        startPoint: .top, endPoint: .bottom))
                    .frame(height: 2).blur(radius: 4)
                    .allowsHitTesting(false)
            }

            if viewModel.showProgressBar {
                HStack { Spacer(); progressBar }
            }

            // Live transcript badge
            if viewModel.sttEnabled, !viewModel.sttController.lastTranscript.isEmpty {
                VStack {
                    Spacer()
                    HStack {
                        transcriptBadge
                        Spacer()
                    }
                    .padding(.leading, 8).padding(.bottom, 6)
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: Fade Overlays

    private var fadeOverlays: some View {
        VStack(spacing: 0) {
            if viewModel.enableTopFade {
                LinearGradient(colors: [theme.fadeColor, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: viewModel.topFadeHeight).allowsHitTesting(false)
            }
            Spacer()
            if viewModel.enableBottomFade {
                LinearGradient(colors: [.clear, theme.fadeColor], startPoint: .top, endPoint: .bottom)
                    .frame(height: viewModel.bottomFadeHeight).allowsHitTesting(false)
            }
        }
    }

    // MARK: Progress Bar

    private var progressBar: some View {
        let progress = contentHeight > 0
            ? min(max(viewModel.offset / contentHeight, 0), 1)
            : 0.0

        return GeometryReader { geo in
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.textColor.opacity(0.08))
                    .frame(width: 3)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.accentColor.opacity(0.6))
                    .frame(width: 3, height: geo.size.height * progress)
                    .shadow(color: theme.glowColor.opacity(0.3), radius: 4)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 3)
        .padding(.trailing, 4).padding(.vertical, 8)
        .allowsHitTesting(false)
    }

    // MARK: Transcript Badge

    private var transcriptBadge: some View {
        Text(viewModel.sttController.lastTranscript)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(theme.textColor.opacity(0.35))
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(theme.borderColor, lineWidth: 0.5))
            )
    }

    // MARK: Control Strip

    private var controlStrip: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 2) {
                controlBtn(icon: viewModel.isPlaying ? "pause.fill" : "play.fill",
                           help: viewModel.isPlaying ? "Pause" : "Play") {
                    viewModel.isPlaying ? viewModel.pause() : viewModel.play()
                }
                controlBtn(icon: "backward.fill", help: "Scroll back") { viewModel.scrollBack() }
                controlBtn(icon: "arrow.counterclockwise", help: "Reset") { viewModel.reset() }

                stripDivider

                if viewModel.sttEnabled {
                    controlBtn(
                        icon: viewModel.micMuted ? "mic.slash.fill" : "mic.fill",
                        help: viewModel.micMuted ? "Unmute" : "Mute",
                        tint: viewModel.micMuted ? .red.opacity(0.8) : nil
                    ) { viewModel.micMuted.toggle() }
                    stripDivider
                }

                controlBtn(icon: "chevron.up", help: "Minimize") {
                    viewModel.isPrompterVisible = false
                }
                controlBtn(icon: "gearshape.fill", help: "Settings") { openSettings() }
            }
            .padding(.vertical, 6).padding(.horizontal, 5)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
                    .shadow(color: theme.glowColor.opacity(0.06), radius: 8)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(theme.borderColor, lineWidth: 0.5))
            )
            Spacer()
        }
        .padding(.leading, 4)
    }

    private var stripDivider: some View {
        RoundedRectangle(cornerRadius: 0.5)
            .fill(theme.textColor.opacity(0.10))
            .frame(width: 16, height: 1)
            .padding(.vertical, 3)
    }

    private func controlBtn(icon: String, help: String, tint: Color? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint ?? theme.textColor.opacity(0.85))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(ControlStripButtonStyle(theme: theme))
        .help(help)
    }

    // MARK: Settings

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.title == "Prompter" {
            w.makeKeyAndOrderFront(nil); return
        }
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: 0, context: nil,
                                     characters: ",", charactersIgnoringModifiers: ",",
                                     isARepeat: false, keyCode: 43) {
            NSApp.postEvent(e, atStart: true)
        }
    }

    // MARK: Text Rendering

    private var movingText: some View {
        VStack(spacing: viewModel.lineHeight) { textBlock }
            .padding(.horizontal, 16).padding(.top, 32)
    }

    private var textBlock: some View {
        let raw = viewModel.text.isEmpty ? "Put some text in Settings..." : viewModel.text
        let full = "\n" + raw + "\n\n[the end]"
        let nsAttr = styledAttributedString(full,
            readUpTo: viewModel.sttEnabled ? viewModel.sttReadUpToOffset : 0)

        let attr: AttributedString
        if let a = try? AttributedString(nsAttr, including: \.appKit) {
            var m = a
            m.font = .system(size: viewModel.fontSize, weight: .regular, design: viewModel.fontDesign)
            attr = m
        } else {
            var f = AttributedString(full)
            f.font = .system(size: viewModel.fontSize, weight: .regular, design: viewModel.fontDesign)
            f.foregroundColor = theme.textColor
            attr = f
        }

        return Text(attr)
            .multilineTextAlignment(viewModel.textAlignment.swiftUIAlignment)
            .lineSpacing(viewModel.lineHeight)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func styledAttributedString(_ text: String, readUpTo: Int) -> NSMutableAttributedString {
        let s = NSMutableAttributedString(string: text)
        let full = NSRange(location: 0, length: text.utf16.count)
        let font = NSFont.systemFont(ofSize: CGFloat(viewModel.fontSize))
        let color = NSColor(theme.textColor)

        s.addAttribute(.font, value: font, range: full)
        s.addAttribute(.foregroundColor, value: color, range: full)

        // Dim already-read text
        if readUpTo > 0 {
            let r = NSRange(location: 0, length: min(readUpTo, text.utf16.count))
            s.addAttribute(.foregroundColor, value: color.withAlphaComponent(0.35), range: r)
        }

        // Italicise stage directions [like this]
        if let regex = try? NSRegularExpression(pattern: "\\[[^\\]]+\\]") {
            for m in regex.matches(in: text, range: full) {
                s.addAttribute(.foregroundColor, value: color.withAlphaComponent(0.3), range: m.range)
                let desc = font.fontDescriptor.withSymbolicTraits(.italic)
                if let italic = NSFont(descriptor: desc, size: font.pointSize) {
                    s.addAttribute(.font, value: italic, range: m.range)
                }
            }
        }
        return s
    }
}

// MARK: - Button Style

struct ControlStripButtonStyle: ButtonStyle {
    let theme: PrompterTheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed ? theme.accentColor.opacity(0.15) : .clear)
            )
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Height Reader

private struct HeightReader: View {
    @Binding var height: CGFloat
    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { height = geo.size.height }
                .onChange(of: geo.size) { _, s in height = s.height }
        }
    }
}
