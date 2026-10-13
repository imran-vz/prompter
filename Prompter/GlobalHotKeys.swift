//
//  GlobalHotKeys.swift
//  Prompter
//
//  System-wide shortcuts through Carbon's RegisterEventHotKey. Unlike a global
//  NSEvent monitor this needs no Accessibility permission (so it works in the
//  sandbox), and it only fires for its exact key combination, so typing in
//  other apps can never play, pause or reset the Prompter.
//

import AppKit
import Carbon.HIToolbox

final class GlobalHotKeys {

    enum Action: UInt32, CaseIterable {
        case togglePlay = 1
        case toggleVisible
        case reset
        case scrollUp
        case scrollDown

        /// ⌃⌥⌘ plus a key: a combination no standard app shortcut uses.
        var keyCode: Int {
            switch self {
            case .togglePlay: return kVK_ANSI_P
            case .toggleVisible: return kVK_ANSI_H
            case .reset: return kVK_ANSI_R
            case .scrollUp: return kVK_UpArrow
            case .scrollDown: return kVK_DownArrow
            }
        }

        static let modifiers = UInt32(controlKey | optionKey | cmdKey)
        static let modifierFlags: NSEvent.ModifierFlags = [.control, .option, .command]
    }

    private let handler: (Action) -> Void
    private var refs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    /// "PRMT"
    private static let signature: OSType = 0x50524D54

    init(handler: @escaping (Action) -> Void) {
        self.handler = handler
    }

    var isRegistered: Bool { !refs.isEmpty }

    func register() {
        guard refs.isEmpty else { return }
        installHandlerIfNeeded()

        for action in Action.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
            let status = RegisterEventHotKey(UInt32(action.keyCode), Action.modifiers, id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
            } else {
                print("[GlobalHotKeys] Could not register \(action): \(status)")
            }
        }
    }

    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == GlobalHotKeys.signature,
                  let action = Action(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            // Carbon delivers hot-key events on the main thread.
            MainActor.assumeIsolated {
                Unmanaged<GlobalHotKeys>.fromOpaque(context).takeUnretainedValue().handler(action)
            }
            return noErr
        }, 1, &spec, context, &eventHandler)
    }

    deinit {
        refs.forEach { UnregisterEventHotKey($0) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
