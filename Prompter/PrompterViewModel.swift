//
//  PrompterViewModel.swift
//  Prompter
//
//  Created by Imran on 13/04/26.
//

import Combine
import Foundation
import QuartzCore
import SwiftUI

final class PrompterViewModel: ObservableObject {

    // MARK: - Published State

    /// First-run Script: doubles as a short guide the user can read aloud.
    @Published var text: String = """
        Welcome to Prompter.

        This text sits just under your notch. Hover over it for controls, or scroll it by hand with your trackpad.

        To use your own words, open Settings from the menu bar icon and paste your script into the Script tab, or import a text file.

        Press Play to scroll at a steady speed. Or turn on Speech Tracking in the Speech tab and read aloud. Prompter listens on your Mac, follows along, and highlights each word as you say it.

        [pause]

        Words in square brackets are stage directions. They are dimmed, and Prompter doesn't expect you to say them.

        Happy recording.
        """

    @Published var isPlaying = false
    @Published var offset: CGFloat = 0
    @Published var speed: Double = 12.0
    @Published var fontSize: Double = 14.0
    @Published var lineHeight: Double = 8.0
    @Published var pauseOnHover = true
    @Published var prompterWidth: CGFloat = 300
    @Published var prompterHeight: CGFloat = 150
    @Published var isPrompterVisible = true
    @Published var fontDesign: Font.Design = .default
    @Published var selectedScreenIndex = 0
    @Published var enableTopFade = true
    @Published var enableBottomFade = true
    @Published var topFadeHeight: Double = 40.0
    @Published var bottomFadeHeight: Double = 40.0
    @Published var showHoverControls = true
    @Published var prompterTheme: PrompterTheme = .midnight
    @Published var horizontalAlignment: PrompterHorizontalAlignment = .center
    @Published var textAlignment: PrompterTextAlignment = .center
    @Published var showProgressBar = true
    @Published var followActiveDisplay = true
    /// Keep the Prompter out of screen sharing and recordings.
    @Published var hideFromScreenSharing = true
    /// ⌃⌥⌘ shortcuts that work while another app is focused.
    @Published var globalShortcutsEnabled = true

    // STT
    @Published var sttEnabled = false
    @Published var sttSmoothing: Double = 0.2
    @Published var sttReadUpToOffset = 0
    @Published var sttCurrentWordRange: NSRange?
    @Published var readingLineOffset: Double = 0.35
    @Published var contentHeight: CGFloat = 0
    @Published var sttEngineType: STTEngineType = .apple
    @Published var whisperKitModel = "tiny"
    @Published var micMuted = false
    /// Recognition language identifier, or "" to follow the system language.
    @Published var speechLanguage = ""

    var backScrollAmount: Double = 30.0

    let sttController: STTController

    /// Space above the Script inside the Prompter, clear of the notch.
    static let scriptTopInset: CGFloat = 40

    /// Set by the Prompter's text view; maps Script offsets to screen lines.
    weak var layoutProvider: ScriptLayoutProviding?

    // MARK: - Private

    private let manualOverrideDuration: TimeInterval = 3.0
    private var lastManualScrollTime = Date.distantPast
    private var targetOffset: CGFloat = 0
    private var timerCancellable: AnyCancellable?
    private var lastTick: CFTimeInterval?
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Init

    init() {
        sttController = STTController(script: "")
        loadSettings()
        sttController.setLocale(speechLocale)
        updateEngine()
        sttController.updateScript(text)
        sttController.onAlignment = { [weak self] in self?.handleAlignment($0) }
        startTimer()
        observeSettingsChanges()

        if sttEnabled, !Self.isRunningTests { syncSTTState(enabled: true) }
    }

    /// True when hosting unit tests: no microphone, no permission prompts.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Maximum scroll offset — stop when the last text is still visible,
    /// leaving 25% of the prompter height as bottom padding.
    private var maxOffset: CGFloat {
        guard contentHeight > 0 else { return 0 }
        return max(0, contentHeight - prompterHeight * 0.25)
    }

    // MARK: - Playback

    func play()  { lastTick = nil; isPlaying = true }
    func pause() { isPlaying = false }

    func reset() {
        isPlaying = false
        offset = 0
        targetOffset = 0
        lastTick = nil
        sttReadUpToOffset = 0
        sttCurrentWordRange = nil
        sttController.resetAlignment()

        if sttEnabled {
            sttController.stop()
            sttController.start()
        }
    }

    func scrollBack() {
        offset = max(0, offset - backScrollAmount)
        lastManualScrollTime = Date()
    }

    /// Replace the Script with the contents of a text, Markdown, RTF or Word file.
    func importScript(from url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        switch url.pathExtension.lowercased() {
        case "rtf", "rtfd", "doc", "docx", "odt", "html", "htm":
            text = try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
        default:
            text = try String(contentsOf: url, encoding: .utf8)
        }
    }

    func applyManualScroll(delta: CGFloat) {
        offset = max(0, min(offset - delta, maxOffset))
        lastManualScrollTime = Date()
    }

    // MARK: - STT

    func syncSTTState(enabled: Bool) {
        if enabled {
            sttController.start()
        } else {
            sttController.stop()
        }
    }

    var speechLocale: Locale {
        speechLanguage.isEmpty ? .current : Locale(identifier: speechLanguage)
    }

    private func updateEngine() {
        let locale = speechLocale
        let engine: STTEngine = (sttEngineType == .apple)
            ? AppleSpeechEngine(locale: locale)
            : WhisperKitEngine(modelName: whisperKitModel,
                               language: locale.language.languageCode?.identifier)
        sttController.setLocale(locale)
        sttController.setEngine(engine)
        sttController.updateScript(text)
    }

    private func handleAlignment(_ result: AlignmentResult) {
        guard sttEnabled, contentHeight > 0, result.confidence >= 0.25 else { return }

        // Put the line holding the Current word on the Reading position. The
        // word-count fraction is only a fallback before the text is laid out.
        let wordY: CGFloat
        if let lineY = layoutProvider?.lineMidY(forUTF16Offset: result.currentWordRange.location) {
            wordY = Self.scriptTopInset + lineY
        } else {
            wordY = CGFloat(result.progress) * contentHeight
        }
        let newTarget = wordY - CGFloat(readingLineOffset) * prompterHeight
        let clamped = max(0, min(newTarget, maxOffset))

        let backwardThreshold: CGFloat = 60
        if clamped > targetOffset {
            targetOffset = clamped
        } else if clamped < targetOffset - backwardThreshold {
            targetOffset = clamped
        }

        sttReadUpToOffset = result.readUpToOffset
        sttCurrentWordRange = result.currentWordRange
    }

    // MARK: - Display Link Tick

    private var isManualOverrideActive: Bool {
        Date().timeIntervalSince(lastManualScrollTime) < manualOverrideDuration
    }

    private func startTimer() {
        timerCancellable = DisplayLinkPublisher()
            .sink { [weak self] ts in self?.tick(current: ts) }
    }

    /// Runs every display frame. Works on a local copy and publishes `offset`
    /// only when it actually moves: every `@Published` write re-renders the
    /// Prompter, and doing that each frame while idle cost ~55% CPU.
    private func tick(current: CFTimeInterval) {
        let dt: CFTimeInterval = lastTick.map { current - $0 } ?? 0
        lastTick = current

        var offset = self.offset
        defer {
            offset = offset.clamped(to: 0...maxOffset)
            if abs(offset - self.offset) > 0.01 { self.offset = offset }
        }

        if isPlaying {
            offset += CGFloat(speed) * CGFloat(dt)
        }

        // STT-driven scroll: chase targetOffset only during speech or manual play.
        // Holds position during silence so turn gaps don't drift the teleprompter.
        if sttEnabled, contentHeight > 0, !isManualOverrideActive,
           sttController.vadState != .silence || isPlaying {
            let delta = targetOffset - offset
            let allowBackward = !isPlaying
            let minStep: CGFloat = 1.5

            if abs(delta) < minStep {
                if delta > 0 || allowBackward { offset = targetOffset }
            } else {
                let t = 1 - pow(CGFloat(sttSmoothing), CGFloat(dt) * 60)
                var step = delta * t
                if abs(step) < minStep { step = delta > 0 ? minStep : -minStep }
                step = step.clamped(to: -prompterHeight * 6 * CGFloat(dt)...prompterHeight * 6 * CGFloat(dt))
                if !allowBackward && step < 0 { step = 0 }
                offset += step
            }
        }
    }

    // MARK: - Settings Persistence

    private enum K {
        static let text = "PrompterText"
        static let speed = "PrompterSpeed"
        static let fontSize = "PrompterFontSize"
        static let lineHeight = "PrompterLineHeight"
        static let pauseOnHover = "PrompterPauseOnHover"
        static let width = "PrompterWidth"
        static let height = "PrompterHeight"
        static let fontDesign = "FontDesign"
        static let screenIndex = "SelectedScreenIndex"
        static let enableTopFade = "EnableTopFade"
        static let enableBottomFade = "EnableBottomFade"
        static let topFadeHeight = "TopFadeHeight"
        static let bottomFadeHeight = "BottomFadeHeight"
        static let showHoverControls = "ShowHoverControls"
        static let theme = "PrompterTheme"
        static let hAlign = "HorizontalAlignment"
        static let tAlign = "TextAlignment"
        static let showProgress = "ShowProgressBar"
        static let sttEnabled = "STTEnabled"
        static let sttSmoothing = "STTSmoothing"
        static let readingLine = "ReadingLineOffset"
        static let followDisplay = "FollowActiveDisplay"
        static let sttEngine = "STTEngineType"
        static let whisperModel = "WhisperKitModel"
        static let micMuted = "MicMuted"
        static let hideFromSharing = "HideFromScreenSharing"
        static let globalShortcuts = "GlobalShortcutsEnabled"
        static let speechLanguage = "SpeechLanguage"
    }

    /// Observe all published properties and auto-persist changes.
    private func observeSettingsChanges() {
        // Properties that just need a save
        let saveOnly: [AnyPublisher<Void, Never>] = [
            $speed.map { _ in }.eraseToAnyPublisher(),
            $fontSize.map { _ in }.eraseToAnyPublisher(),
            $lineHeight.map { _ in }.eraseToAnyPublisher(),
            $pauseOnHover.map { _ in }.eraseToAnyPublisher(),
            $prompterWidth.map { _ in }.eraseToAnyPublisher(),
            $prompterHeight.map { _ in }.eraseToAnyPublisher(),
            $fontDesign.map { _ in }.eraseToAnyPublisher(),
            $selectedScreenIndex.map { _ in }.eraseToAnyPublisher(),
            $enableTopFade.map { _ in }.eraseToAnyPublisher(),
            $enableBottomFade.map { _ in }.eraseToAnyPublisher(),
            $topFadeHeight.map { _ in }.eraseToAnyPublisher(),
            $bottomFadeHeight.map { _ in }.eraseToAnyPublisher(),
            $showHoverControls.map { _ in }.eraseToAnyPublisher(),
            $prompterTheme.map { _ in }.eraseToAnyPublisher(),
            $horizontalAlignment.map { _ in }.eraseToAnyPublisher(),
            $textAlignment.map { _ in }.eraseToAnyPublisher(),
            $showProgressBar.map { _ in }.eraseToAnyPublisher(),
            $sttSmoothing.map { _ in }.eraseToAnyPublisher(),
            $readingLineOffset.map { _ in }.eraseToAnyPublisher(),
            $followActiveDisplay.map { _ in }.eraseToAnyPublisher(),
            $hideFromScreenSharing.map { _ in }.eraseToAnyPublisher(),
            $globalShortcutsEnabled.map { _ in }.eraseToAnyPublisher(),
        ]

        Publishers.MergeMany(saveOnly)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] in self?.saveSettings() }
            .store(in: &cancellables)

        // Text: update the STT script and start over from the top, including
        // the speech-tracking target, or tracking would drag the Prompter back.
        $text.dropFirst()
            .sink { [weak self] t in
                guard let self else { return }
                self.sttController.updateScript(t)
                self.sttController.resetAlignment()
                self.offset = 0
                self.targetOffset = 0
                self.sttReadUpToOffset = 0
                self.sttCurrentWordRange = nil
                self.saveSettings()
            }
            .store(in: &cancellables)

        $speechLanguage.dropFirst()
            .sink { [weak self] _ in self?.saveSettings(); self?.updateEngine() }
            .store(in: &cancellables)

        // STT enabled: start/stop engine
        $sttEnabled.dropFirst()
            .sink { [weak self] enabled in
                self?.saveSettings()
                self?.syncSTTState(enabled: enabled)
            }
            .store(in: &cancellables)

        // Engine / model: swap engine
        $sttEngineType.dropFirst()
            .sink { [weak self] _ in self?.saveSettings(); self?.updateEngine() }
            .store(in: &cancellables)

        $whisperKitModel.dropFirst()
            .sink { [weak self] _ in self?.saveSettings(); self?.updateEngine() }
            .store(in: &cancellables)

        // Mic mute: sync global state
        $micMuted
            .sink { [weak self] muted in
                MicState.shared.isMuted = muted
                self?.saveSettings()
            }
            .store(in: &cancellables)
    }

    private func loadSettings() {
        let d = UserDefaults.standard

        text              = d.string(forKey: K.text) ?? text
        speed             = d.double(forKey: K.speed).nonZero ?? 12.0
        fontSize          = d.double(forKey: K.fontSize).nonZero ?? 14.0
        lineHeight        = d.double(forKey: K.lineHeight).nonZero ?? 8.0
        pauseOnHover      = d.object(forKey: K.pauseOnHover) as? Bool ?? true
        prompterWidth     = CGFloat(d.double(forKey: K.width).nonZero ?? 300)
        prompterHeight    = CGFloat(d.double(forKey: K.height).nonZero ?? 150)
        fontDesign        = d.string(forKey: K.fontDesign).flatMap(Font.Design.init) ?? .default
        selectedScreenIndex = d.integer(forKey: K.screenIndex)
        enableTopFade     = d.object(forKey: K.enableTopFade) as? Bool ?? true
        enableBottomFade  = d.object(forKey: K.enableBottomFade) as? Bool ?? true
        topFadeHeight     = d.double(forKey: K.topFadeHeight).nonZero ?? 40.0
        bottomFadeHeight  = d.double(forKey: K.bottomFadeHeight).nonZero ?? 40.0
        showHoverControls = d.object(forKey: K.showHoverControls) as? Bool ?? true
        prompterTheme     = d.string(forKey: K.theme).flatMap(PrompterTheme.init) ?? .midnight
        horizontalAlignment = d.string(forKey: K.hAlign).flatMap(PrompterHorizontalAlignment.init) ?? .center
        textAlignment     = d.string(forKey: K.tAlign).flatMap(PrompterTextAlignment.init) ?? .center
        showProgressBar   = d.object(forKey: K.showProgress) as? Bool ?? true
        sttEnabled        = d.object(forKey: K.sttEnabled) as? Bool ?? false
        sttSmoothing      = d.double(forKey: K.sttSmoothing).nonZero ?? 0.3
        readingLineOffset = d.double(forKey: K.readingLine).nonZero ?? 0.35
        followActiveDisplay = d.object(forKey: K.followDisplay) as? Bool ?? true
        sttEngineType     = d.string(forKey: K.sttEngine).flatMap(STTEngineType.init) ?? .apple
        whisperKitModel   = d.string(forKey: K.whisperModel) ?? "tiny"
        micMuted          = d.object(forKey: K.micMuted) as? Bool ?? false
        hideFromScreenSharing = d.object(forKey: K.hideFromSharing) as? Bool ?? true
        globalShortcutsEnabled = d.object(forKey: K.globalShortcuts) as? Bool ?? true
        speechLanguage    = d.string(forKey: K.speechLanguage) ?? ""
        MicState.shared.isMuted = micMuted
    }

    private func saveSettings() {
        let d = UserDefaults.standard
        d.set(text, forKey: K.text)
        d.set(speed, forKey: K.speed)
        d.set(fontSize, forKey: K.fontSize)
        d.set(lineHeight, forKey: K.lineHeight)
        d.set(pauseOnHover, forKey: K.pauseOnHover)
        d.set(Double(prompterWidth), forKey: K.width)
        d.set(Double(prompterHeight), forKey: K.height)
        d.set(fontDesign.rawValue, forKey: K.fontDesign)
        d.set(selectedScreenIndex, forKey: K.screenIndex)
        d.set(enableTopFade, forKey: K.enableTopFade)
        d.set(enableBottomFade, forKey: K.enableBottomFade)
        d.set(topFadeHeight, forKey: K.topFadeHeight)
        d.set(bottomFadeHeight, forKey: K.bottomFadeHeight)
        d.set(showHoverControls, forKey: K.showHoverControls)
        d.set(prompterTheme.rawValue, forKey: K.theme)
        d.set(horizontalAlignment.rawValue, forKey: K.hAlign)
        d.set(textAlignment.rawValue, forKey: K.tAlign)
        d.set(showProgressBar, forKey: K.showProgress)
        d.set(sttEnabled, forKey: K.sttEnabled)
        d.set(sttSmoothing, forKey: K.sttSmoothing)
        d.set(readingLineOffset, forKey: K.readingLine)
        d.set(followActiveDisplay, forKey: K.followDisplay)
        d.set(sttEngineType.rawValue, forKey: K.sttEngine)
        d.set(whisperKitModel, forKey: K.whisperModel)
        d.set(micMuted, forKey: K.micMuted)
        d.set(hideFromScreenSharing, forKey: K.hideFromSharing)
        d.set(globalShortcutsEnabled, forKey: K.globalShortcuts)
        d.set(speechLanguage, forKey: K.speechLanguage)
    }
}

// MARK: - Display Link Publisher

private final class DisplayLinkProxy: NSObject {
    let subject = PassthroughSubject<CFTimeInterval, Never>()
    private var displayLink: CADisplayLink?

    override init() {
        super.init()
        let link = NSScreen.main?.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        subject.send(link.timestamp)
    }

    deinit { displayLink?.invalidate() }
}

private struct DisplayLinkPublisher: Publisher {
    typealias Output = CFTimeInterval
    typealias Failure = Never

    func receive<S: Subscriber>(subscriber: S) where S.Input == CFTimeInterval, S.Failure == Never {
        let proxy = DisplayLinkProxy()
        subscriber.receive(subscription: Sub(subscriber: subscriber, proxy: proxy))
    }

    private final class Sub<S: Subscriber>: Subscription where S.Input == CFTimeInterval, S.Failure == Never {
        private var subscriber: S?
        private var proxy: DisplayLinkProxy?
        private var bag: Set<AnyCancellable> = []

        init(subscriber: S, proxy: DisplayLinkProxy) {
            self.subscriber = subscriber
            self.proxy = proxy
            proxy.subject
                .sink { [weak self] v in _ = self?.subscriber?.receive(v) }
                .store(in: &bag)
        }

        func request(_ demand: Subscribers.Demand) {}
        func cancel() { subscriber = nil; proxy = nil; bag.removeAll() }
    }
}

// MARK: - Helpers

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
