//
//  PrompterWindow.swift
//  Prompter
//
//  Created by Imran on 13/04/26.
//

import AppKit
import SwiftUI
import Combine

// MARK: - Overlay Panel

final class PrompterOverlayPanel: NSPanel {
    override var canBecomeKey: Bool  { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Prompter Window Controller

final class PrompterWindow {
    private var window: NSWindow!
    private let viewModel: PrompterViewModel
    private var cancellables: Set<AnyCancellable> = []
    private var activeDisplayTimer: Timer?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    init(viewModel: PrompterViewModel) {
        self.viewModel = viewModel

        let hosting = NSHostingView(rootView: PrompterView(viewModel: viewModel))
        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = false

        window = PrompterOverlayPanel(
            contentRect: NSRect(x: 0, y: 0,
                                width: viewModel.prompterWidth + controlStripTotalWidth,
                                height: viewModel.prompterHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.hasShadow = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                     .ignoresCycle, .stationary, .transient]
        window.isMovableByWindowBackground = false
        window.isRestorable = false
        window.isExcludedFromWindowsMenu = true
        window.contentView = hosting

        observeViewModel()
        installKeyMonitors()

        NotificationCenter.default.addObserver(
            self, selector: #selector(spaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    // MARK: - Show / Resize

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        guard let screen = selectedScreen else { window.center(); window.makeKeyAndOrderFront(nil); return }
        window.setFrame(frame(on: screen), display: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func resize() {
        guard let screen = selectedScreen else { return }
        window.setFrame(frame(on: screen), display: true, animate: true)
    }

    // MARK: - View-Model Bindings

    private func observeViewModel() {
        viewModel.$prompterWidth.combineLatest(viewModel.$prompterHeight)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.resize() }
            .store(in: &cancellables)

        viewModel.$selectedScreenIndex
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resize() }
            .store(in: &cancellables)

        viewModel.$horizontalAlignment
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resize() }
            .store(in: &cancellables)

        viewModel.$isPrompterVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] vis in vis ? self?.animateShow() : self?.animateHide() }
            .store(in: &cancellables)

        viewModel.$followActiveDisplay
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.updateDisplayTracking(on) }
            .store(in: &cancellables)

        updateDisplayTracking(viewModel.followActiveDisplay)
    }

    // MARK: - Keyboard Shortcuts

    private func installKeyMonitors() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.handleKey(e) == true ? nil : e
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.handleKey(e)
        }
    }

    @discardableResult
    private func handleKey(_ event: NSEvent) -> Bool {
        guard viewModel.isPrompterVisible else { return false }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }

        switch event.keyCode {
        case 49:  DispatchQueue.main.async { self.viewModel.isPlaying ? self.viewModel.pause() : self.viewModel.play() }; return true  // Space
        case 126: DispatchQueue.main.async { self.viewModel.applyManualScroll(delta:  30) }; return true  // ↑
        case 125: DispatchQueue.main.async { self.viewModel.applyManualScroll(delta: -30) }; return true  // ↓
        case 123: DispatchQueue.main.async { self.viewModel.speed = max(1,   self.viewModel.speed - 2) }; return true  // ←
        case 124: DispatchQueue.main.async { self.viewModel.speed = min(100, self.viewModel.speed + 2) }; return true  // →
        case 15:  DispatchQueue.main.async { self.viewModel.reset() }; return true  // R
        default:  return false
        }
    }

    // MARK: - Screen Helpers

    @objc private func spaceDidChange() {
        guard viewModel.isPrompterVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private var selectedScreen: NSScreen? {
        if viewModel.followActiveDisplay {
            let pt = NSEvent.mouseLocation
            return NSScreen.screens.first { $0.frame.contains(pt) } ?? NSScreen.main
        }
        let idx = viewModel.selectedScreenIndex
        let screens = NSScreen.screens
        return (idx >= 0 && idx < screens.count) ? screens[idx] : NSScreen.main
    }

    private func updateDisplayTracking(_ enabled: Bool) {
        activeDisplayTimer?.invalidate()
        activeDisplayTimer = nil
        guard enabled else { return }
        activeDisplayTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.viewModel.isPrompterVisible else { return }
            self.resize()
        }
    }

    // MARK: - Frame Calculation

    private func frame(on screen: NSScreen) -> CGRect {
        let totalW = viewModel.prompterWidth + controlStripTotalWidth
        let prompterW = viewModel.prompterWidth
        let align: CGFloat = {
            switch viewModel.horizontalAlignment {
            case .left: return 0; case .center: return 0.5; case .right: return 1
            }
        }()
        let padding: CGFloat = 20
        let x = screen.frame.minX + padding + (screen.frame.width - prompterW - padding * 2) * align
        let y = screen.frame.maxY - viewModel.prompterHeight
        return CGRect(x: x, y: y, width: totalW, height: viewModel.prompterHeight)
    }

    // MARK: - Animations

    private let animDuration: TimeInterval = 0.35

    private func animateShow() {
        guard let screen = selectedScreen else { return }
        let final = frame(on: screen)

        var start = final
        start.size.height = 4
        start.origin.y = final.maxY - 4

        window.setFrame(start, display: false)
        window.alphaValue = 0.4
        window.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animDuration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            window.animator().setFrame(final, display: true)
            window.animator().alphaValue = 1.0
        }
    }

    private func animateHide() {
        guard selectedScreen != nil else { window.orderOut(nil); return }
        let cur = window.frame
        var target = cur
        target.size.height = 4
        target.origin.y = cur.maxY - 4

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animDuration * 0.7
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 1, 0.45)
            window.animator().setFrame(target, display: true)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.window.orderOut(nil)
            self?.window.alphaValue = 1
        })
    }
}
