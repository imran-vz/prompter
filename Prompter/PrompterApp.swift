//
//  PrompterApp.swift
//  Prompter
//
//  Created by Imran on 13/04/26.
//

import AppKit
import SwiftUI

@main
struct PrompterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(viewModel: appDelegate.viewModel)
                .onAppear { NSApp.setActivationPolicy(.regular) }
                .onDisappear { NSApp.setActivationPolicy(.accessory) }
        }

        MenuBarExtra {
            MenuContent(viewModel: appDelegate.viewModel)
        } label: {
            Image(systemName: "text.alignleft")
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = PrompterViewModel()
    private var prompterWindow: PrompterWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        prompterWindow = PrompterWindow(viewModel: viewModel)
        prompterWindow.show()
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MenuContent: View {
    @ObservedObject var viewModel: PrompterViewModel

    var body: some View {
        Button {
            if !viewModel.isPrompterVisible {
                NSApp.activate(ignoringOtherApps: true)
            }
            viewModel.isPrompterVisible.toggle()
        } label: {
            Label(
                viewModel.isPrompterVisible ? "Hide Prompter" : "Show Prompter",
                systemImage: viewModel.isPrompterVisible ? "eye.slash" : "eye")
        }
        .keyboardShortcut("h", modifiers: [.command, .option])

        Divider()

        Button {
            viewModel.isPlaying ? viewModel.pause() : viewModel.play()
        } label: {
            Label(
                viewModel.isPlaying ? "Pause" : "Play",
                systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill")
        }
        .keyboardShortcut("p", modifiers: [.command, .option])

        Button {
            viewModel.reset()
        } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
        }

        Divider()

        SettingsLink {
            Label("Settings", systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: [.command])

        Divider()

        Button(role: .destructive) {
            NSApp.terminate(nil)
        } label: {
            Label("Exit", systemImage: "xmark.circle")
        }
        .keyboardShortcut("q", modifiers: [.command])
    }
}
