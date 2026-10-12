# Menu-bar accessory app with a notch-attached panel

Prompter has no Dock icon and runs from a `MenuBarExtra`. Its activation policy is `.accessory`, switched to `.regular` only while Settings is open (`PrompterApp.swift`). The Prompter itself is a borderless, non-activating `NSPanel` at `.screenSaver` level that joins all Spaces and full-screen apps (`.canJoinAllSpaces`, `.fullScreenAuxiliary`). It is pinned to the top edge of the screen (`frame.y = screen.maxY - height`) and clipped to `NotchConnectedShape`, whose concave top corners "blend into the macOS notch / menu-bar" (`PrompterWindow.swift`, `Models.swift`).

## Consequences

- Space, the arrow keys and R are handled by a global `NSEvent` key monitor, so they work while another app is focused. They are acted on only while the Prompter is visible and no ⌘/⌃/⌥ modifier is held (`PrompterWindow.handleKey`).
- "Follow active display" re-checks the mouse position on a 0.5 s timer and moves the panel to that screen.
- On every Space change the panel is brought back to the front.

_Reason for the notch placement: not recorded in the code._
