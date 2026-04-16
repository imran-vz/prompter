//
//  SettingsTab.swift
//  Prompter
//
//  Created by Imran on 13/04/26.
//

import SwiftUI

// MARK: - Tab Definition

enum SettingsTab: CaseIterable, Identifiable {
    case script
    case appearance
    case layout
    case behavior
    case speech

    var id: Self { self }

    var label: String {
        switch self {
        case .script: return "Script"
        case .appearance: return "Appearance"
        case .layout: return "Layout"
        case .behavior: return "Behavior"
        case .speech: return "Speech"
        }
    }

    var icon: String {
        switch self {
        case .script: return "doc.text.fill"
        case .appearance: return "paintpalette.fill"
        case .layout: return "macwindow"
        case .behavior: return "gearshape.fill"
        case .speech: return "waveform"
        }
    }
}

// MARK: - Design Tokens

private enum DS {
    static let cardBg = Color.primary.opacity(0.035)
    static let cardBorder = Color.primary.opacity(0.06)
    static let sidebarBg = Color.primary.opacity(0.03)
    static let sidebarSelected = Color.accentColor.opacity(0.10)
    static let sidebarIndicator = Color.accentColor

    static let label = Font.system(size: 13, weight: .regular)
    static let sublabel = Font.system(size: 11, weight: .regular)
    static let monoValue = Font.system(size: 11, weight: .medium, design: .monospaced)

    static let cardRadius: CGFloat = 10
    static let innerRadius: CGFloat = 7
    static let spacing: CGFloat = 14
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var viewModel: PrompterViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: SettingsTab = .script
    @State private var contentVisible = false
    @State private var showResetConfirmation = false

    var body: some View {
        ZStack {
            if contentVisible {
                settingsContent
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .frame(width: 700)
        .frame(minHeight: 560, maxHeight: 760)
        .background(.ultraThinMaterial)
        .confirmationDialog("Reset Prompter Position?", isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                viewModel.reset()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will stop playback and reset the scroll position to the beginning.")
        }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85).delay(0.05)) {
                contentVisible = true
            }
        }
    }

    // MARK: - Layout

    private var settingsContent: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.5)

            VStack(spacing: 0) {
                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomBar
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SETTINGS")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.quaternary)
                .kerning(1.2)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            ForEach(SettingsTab.allCases) { tab in
                sidebarItem(tab)
            }

            Spacer()

            // Version / branding
            HStack(spacing: 4) {
                Circle()
                    .fill(viewModel.isPlaying
                          ? Color.green.opacity(0.8)
                          : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
                Text(viewModel.isPlaying ? "Playing" : "Paused")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
        .padding(.vertical, 14)
        .frame(width: 160)
        .frame(maxHeight: .infinity)
        .background(DS.sidebarBg)
    }

    private func sidebarItem(_ tab: SettingsTab) -> some View {
        HStack(spacing: 8) {
            // Active indicator bar
            RoundedRectangle(cornerRadius: 1.5)
                .fill(selectedTab == tab ? DS.sidebarIndicator : Color.clear)
                .frame(width: 3, height: 16)

            Image(systemName: tab.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selectedTab == tab ? Color.accentColor : .secondary)
                .frame(width: 16)

            Text(tab.label)
                .font(.system(size: 13, weight: selectedTab == tab ? .medium : .regular))
                .foregroundStyle(selectedTab == tab ? .primary : .secondary)

            Spacer()
        }
        .padding(.trailing, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selectedTab == tab ? DS.sidebarSelected : Color.clear)
                .padding(.leading, 6)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTab = tab
            }
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .script:
            ScriptTabView(viewModel: viewModel)
        case .appearance:
            AppearanceTabView(viewModel: viewModel)
        case .behavior:
            BehaviorTabView(viewModel: viewModel)
        case .layout:
            LayoutTabView(viewModel: viewModel)
        case .speech:
            SpeechTabView(viewModel: viewModel)
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)

            HStack(spacing: 8) {
                ToolbarButton(
                    icon: viewModel.isPlaying ? "pause.fill" : "play.fill",
                    label: viewModel.isPlaying ? "Pause" : "Play"
                ) {
                    viewModel.isPlaying ? viewModel.pause() : viewModel.play()
                }

                ToolbarButton(icon: "arrow.counterclockwise", label: "Reset") {
                    showResetConfirmation = true
                }

                ToolbarButton(
                    icon: viewModel.isPrompterVisible ? "eye.slash.fill" : "eye.fill",
                    label: viewModel.isPrompterVisible ? "Hide" : "Show"
                ) {
                    viewModel.isPrompterVisible.toggle()
                }

                Spacer()

                Button("Done") {
                    closeWithAnimation()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(Color.accentColor)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
        }
    }

    private func closeWithAnimation() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            contentVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            dismiss()
        }
    }
}

// MARK: - Toolbar Button

private struct ToolbarButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(DS.cardBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(DS.cardBorder, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Glass Card

private struct GlassCard<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spacing) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.cardRadius)
                .fill(DS.cardBg)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.cardRadius)
                        .strokeBorder(DS.cardBorder, lineWidth: 0.5)
                )
        )
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.tertiary)
            .kerning(0.8)
    }
}

// MARK: - Script Tab

struct ScriptTabView: View {
    @ObservedObject var viewModel: PrompterViewModel
    @FocusState private var isTextEditorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: DS.cardRadius)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.cardRadius)
                            .strokeBorder(
                                isTextEditorFocused
                                    ? Color.accentColor.opacity(0.6)
                                    : DS.cardBorder,
                                lineWidth: isTextEditorFocused ? 1.5 : 0.5
                            )
                    )
                    .shadow(
                        color: isTextEditorFocused
                            ? Color.accentColor.opacity(0.08)
                            : .clear,
                        radius: 8, x: 0, y: 0
                    )

                if viewModel.text.isEmpty {
                    Text("Type your script here...\n\nUse [brackets] for stage directions like [pause], [smile], etc.")
                        .font(.system(size: 14))
                        .foregroundStyle(.quaternary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }

                HighlightingTextEditor(
                    text: $viewModel.text,
                    font: .systemFont(ofSize: 14, weight: .regular),
                    isFocused: $isTextEditorFocused
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .padding(16)
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Appearance Tab

struct AppearanceTabView: View {
    @ObservedObject var viewModel: PrompterViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {

                // Typography section
                SectionHeader(title: "Typography")

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Font Style")
                            .font(DS.sublabel)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 6) {
                            ForEach([Font.Design.default, .serif, .rounded, .monospaced], id: \.self) { design in
                                ChipButton(
                                    isSelected: viewModel.fontDesign == design,
                                    action: { viewModel.fontDesign = design }
                                ) {
                                    VStack(spacing: 3) {
                                        Text("Ag")
                                            .font(.system(size: 15, design: design))
                                        Text(design.displayName)
                                            .font(.system(size: 10))
                                    }
                                }
                            }
                        }
                    }

                    SettingSlider(
                        label: "Size",
                        value: $viewModel.fontSize,
                        range: 8...80,
                        step: 1,
                        unit: "pt"
                    )

                    SettingSlider(
                        label: "Line Spacing",
                        value: $viewModel.lineHeight,
                        range: 0...20,
                        step: 1,
                        unit: "pt"
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Alignment")
                            .font(DS.sublabel)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 6) {
                            ForEach(PrompterTextAlignment.allCases, id: \.self) { alignment in
                                ChipButton(
                                    isSelected: viewModel.textAlignment == alignment,
                                    action: { viewModel.textAlignment = alignment }
                                ) {
                                    VStack(spacing: 3) {
                                        Image(systemName: alignment.icon)
                                            .font(.system(size: 14))
                                        Text(alignment.displayName)
                                            .font(.system(size: 10))
                                    }
                                }
                            }
                        }
                    }
                }

                // Theme section
                SectionHeader(title: "Theme")

                GlassCard {
                    HStack(spacing: 6) {
                        ForEach(PrompterTheme.allCases, id: \.self) { theme in
                            ThemeChip(
                                theme: theme,
                                isSelected: viewModel.prompterTheme == theme,
                                action: { viewModel.prompterTheme = theme }
                            )
                        }
                    }
                }

                // Fade section
                SectionHeader(title: "Fade Effects")

                GlassCard {
                    SettingToggle(
                        title: "Top Fade",
                        subtitle: "Fade out content at the top",
                        isOn: $viewModel.enableTopFade
                    )

                    if viewModel.enableTopFade {
                        SettingSlider(
                            label: "Height",
                            value: $viewModel.topFadeHeight,
                            range: 10...150,
                            step: 5,
                            unit: "px"
                        )
                    }

                    Divider().opacity(0.3)

                    SettingToggle(
                        title: "Bottom Fade",
                        subtitle: "Fade out content at the bottom",
                        isOn: $viewModel.enableBottomFade
                    )

                    if viewModel.enableBottomFade {
                        SettingSlider(
                            label: "Height",
                            value: $viewModel.bottomFadeHeight,
                            range: 10...150,
                            step: 5,
                            unit: "px"
                        )
                    }
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Behavior Tab

struct BehaviorTabView: View {
    @ObservedObject var viewModel: PrompterViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {

                SectionHeader(title: "Scroll Speed")

                GlassCard {
                    SettingSlider(
                        label: "Speed",
                        value: $viewModel.speed,
                        range: 1...100,
                        step: 1,
                        unit: "pt/s"
                    )
                }

                SectionHeader(title: "Interaction")

                GlassCard {
                    SettingToggle(
                        title: "Pause on Hover",
                        subtitle: "Pause scrolling when mouse enters the prompter",
                        isOn: $viewModel.pauseOnHover
                    )

                    Divider().opacity(0.3)

                    SettingToggle(
                        title: "Hover Controls",
                        subtitle: "Show control strip when hovering over the prompter",
                        isOn: $viewModel.showHoverControls
                    )

                    Divider().opacity(0.3)

                    SettingToggle(
                        title: "Progress Bar",
                        subtitle: "Vertical progress indicator on the right side",
                        isOn: $viewModel.showProgressBar
                    )
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Layout Tab

struct LayoutTabView: View {
    @ObservedObject var viewModel: PrompterViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {

                SectionHeader(title: "Window Size")

                GlassCard {
                    SettingSlider(
                        label: "Width",
                        value: Binding(
                            get: { Double(viewModel.prompterWidth) },
                            set: { viewModel.prompterWidth = CGFloat($0) }
                        ),
                        range: 150...600,
                        step: 10,
                        unit: "px"
                    )

                    SettingSlider(
                        label: "Height",
                        value: Binding(
                            get: { Double(viewModel.prompterHeight) },
                            set: { viewModel.prompterHeight = CGFloat($0) }
                        ),
                        range: 80...500,
                        step: 10,
                        unit: "px"
                    )
                }

                SectionHeader(title: "Position")

                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Horizontal Alignment")
                            .font(DS.sublabel)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 6) {
                            ForEach(PrompterHorizontalAlignment.allCases, id: \.self) { alignment in
                                ChipButton(
                                    isSelected: viewModel.horizontalAlignment == alignment,
                                    action: { viewModel.horizontalAlignment = alignment }
                                ) {
                                    VStack(spacing: 3) {
                                        Image(systemName: alignment.icon)
                                            .font(.system(size: 14))
                                        Text(alignment.displayName)
                                            .font(.system(size: 10))
                                    }
                                }
                            }
                        }
                    }
                }

                SectionHeader(title: "Display")

                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Screen")
                            .font(DS.sublabel)
                            .foregroundStyle(.secondary)

                        Picker("", selection: $viewModel.selectedScreenIndex) {
                            ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in
                                Text("\(screen.localizedName) (\(index + 1))").tag(index)
                            }
                        }
                        .labelsHidden()
                        .disabled(viewModel.followActiveDisplay)
                        .opacity(viewModel.followActiveDisplay ? 0.4 : 1.0)
                    }

                    Divider().opacity(0.3)

                    SettingToggle(
                        title: "Follow Active Display",
                        subtitle: "Show prompter on the screen with the mouse cursor",
                        isOn: $viewModel.followActiveDisplay
                    )
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Speech Tab

struct SpeechTabView: View {
    @ObservedObject var viewModel: PrompterViewModel
    @StateObject private var modelManager = WhisperKitModelManager.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {

                GlassCard {
                    SettingToggle(
                        title: "Speech Tracking",
                        subtitle: "Automatically scroll the prompter as you speak",
                        isOn: $viewModel.sttEnabled
                    )
                }

                SectionHeader(title: "Engine")

                GlassCard {
                    HStack(spacing: 6) {
                        ForEach(STTEngineType.allCases, id: \.self) { type in
                            ChipButton(
                                isSelected: viewModel.sttEngineType == type,
                                action: { viewModel.sttEngineType = type }
                            ) {
                                HStack(spacing: 5) {
                                    Image(systemName: type == .apple ? "apple.logo" : "waveform.circle")
                                        .font(.system(size: 12))
                                    Text(type.displayName)
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .padding(.horizontal, 4)
                            }
                        }
                    }

                    if viewModel.sttEngineType == .whisperKit {
                        WhisperKitModelSection(
                            viewModel: viewModel,
                            modelManager: modelManager
                        )
                    }
                }

                SectionHeader(title: "Microphone")

                GlassCard {
                    SettingToggle(
                        title: "Mute Microphone",
                        subtitle: "Stop listening without disabling speech tracking",
                        isOn: $viewModel.micMuted
                    )
                }

                SectionHeader(title: "Tuning")

                GlassCard {
                    SettingSlider(
                        label: "Reading Position",
                        value: $viewModel.readingLineOffset,
                        range: 0.0...0.8,
                        step: 0.05,
                        unit: ""
                    )
                    Text("Where the current word sits in the prompter window")
                        .font(DS.sublabel)
                        .foregroundStyle(.quaternary)

                    Divider().opacity(0.3)

                    SettingSlider(
                        label: "Smoothing",
                        value: $viewModel.sttSmoothing,
                        range: 0.05...0.9,
                        step: 0.05,
                        unit: ""
                    )
                    Text("How smoothly the prompter follows your speech")
                        .font(DS.sublabel)
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(16)
        }
    }
}

// MARK: - WhisperKit Model Section

struct WhisperKitModelSection: View {
    @ObservedObject var viewModel: PrompterViewModel
    @ObservedObject var modelManager: WhisperKitModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.3)

            Text("Model")
                .font(DS.sublabel)
                .foregroundStyle(.secondary)

            Picker("", selection: $viewModel.whisperKitModel) {
                ForEach(modelManager.availableModels, id: \.self) { model in
                    HStack {
                        Text(model)
                        if modelManager.isDownloaded(model) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.system(size: 10))
                        }
                    }
                    .tag(model)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            if !modelManager.isDownloaded(viewModel.whisperKitModel) {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        Task {
                            await modelManager.download(model: viewModel.whisperKitModel)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if modelManager.isDownloading {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 12))
                            }
                            Text(modelManager.isDownloading ? "Downloading…" : "Download")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor.opacity(0.12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 0.5)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(modelManager.isDownloading)

                    if modelManager.isDownloading {
                        ProgressView(value: modelManager.downloadProgress)
                            .progressViewStyle(.linear)
                            .tint(Color.accentColor)
                            .frame(maxWidth: 200)
                    }

                    if let error = modelManager.downloadError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }
            }

            if !modelManager.downloadedModels.isEmpty {
                Divider().opacity(0.3)

                Text("Downloaded")
                    .font(DS.sublabel)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(modelManager.downloadedModels.sorted(), id: \.self) { model in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model)
                                    .font(.system(size: 12, weight: .medium))
                                if let date = modelManager.lastUsedDate(for: model) {
                                    Text("Last used \(date, style: .relative)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                } else {
                                    Text("Never used")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Button {
                                modelManager.delete(model: model)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                            .help("Delete model")
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: DS.innerRadius)
                                .fill(DS.cardBg)
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Reusable Components

/// Chip / Segmented button
private struct ChipButton<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: DS.innerRadius)
                        .fill(isSelected ? Color.accentColor.opacity(0.12) : DS.cardBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.innerRadius)
                                .strokeBorder(
                                    isSelected ? Color.accentColor.opacity(0.4) : DS.cardBorder,
                                    lineWidth: isSelected ? 1 : 0.5
                                )
                        )
                        .shadow(
                            color: isSelected ? Color.accentColor.opacity(0.08) : .clear,
                            radius: 6, x: 0, y: 0
                        )
                )
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Theme preview chip
private struct ThemeChip: View {
    let theme: PrompterTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                // Mini preview
                RoundedRectangle(cornerRadius: 5)
                    .fill(theme.backgroundColor)
                    .frame(height: 28)
                    .overlay(
                        VStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(theme.textColor.opacity(0.6))
                                .frame(width: 24, height: 2)
                            RoundedRectangle(cornerRadius: 1)
                                .fill(theme.textColor.opacity(0.3))
                                .frame(width: 18, height: 2)
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                    )

                Text(theme.displayName)
                    .font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: DS.innerRadius)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.innerRadius)
                            .strokeBorder(
                                isSelected ? Color.accentColor.opacity(0.4) : DS.cardBorder,
                                lineWidth: isSelected ? 1 : 0.5
                            )
                    )
            )
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Toggle with title/subtitle
private struct SettingToggle: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.label)
                Text(subtitle)
                    .font(DS.sublabel)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Slider with label and value display
struct SettingSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    private var displayValue: String {
        if step == Double(Int(step)) {
            return "\(Int(value))"
        } else {
            let formatter = NumberFormatter()
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 2
            return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(DS.sublabel)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(unit.isEmpty ? displayValue : "\(displayValue) \(unit)")
                    .font(DS.monoValue)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(DS.cardBg)
                    )
            }
            Slider(value: $value, in: range, step: step)
                .tint(Color.accentColor)
        }
    }
}
