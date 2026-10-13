# Menu-bar accessory app with a notch-attached panel

Prompter has no Dock icon and runs from a `MenuBarExtra`. Its activation policy is `.accessory`, switched to `.regular` only while Settings is open (`PrompterApp.swift`). The Prompter itself is a borderless, non-activating `NSPanel` at `.screenSaver` level that joins all Spaces and full-screen apps (`.canJoinAllSpaces`, `.fullScreenAuxiliary`). It is pinned to the top edge of the screen (`frame.y = screen.maxY - height`) and clipped to `NotchConnectedShape`, whose concave top corners "blend into the macOS notch / menu-bar" (`PrompterWindow.swift`, `Models.swift`).

## Consequences

- System-wide control uses ⌃⌥⌘ hot keys registered with Carbon's `RegisterEventHotKey` (`GlobalHotKeys.swift`). An earlier global `NSEvent` key monitor was removed: it needs Accessibility permission in the sandbox, and where it worked, typing Space or R in any other app toggled Playback or reset the Script. Plain Space, arrows and R are handled only for key-downs in the Prompter's own panel.
- The panel is shown with `orderFrontRegardless()` and never activates the app, so the app being presented from keeps focus. It sets `sharingType = .none` (user setting, on by default) to stay out of screen shares and recordings.
- "Follow active display" re-checks the mouse position on a 0.5 s timer and moves the panel to that screen.
- On every Space change the panel is brought back to the front, without activating the app.
- `LSUIElement` is set, so there is no Dock icon even at launch.

_Reason for the notch placement: not recorded in the code._
