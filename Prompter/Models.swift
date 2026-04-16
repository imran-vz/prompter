//
//  Models.swift
//  Prompter
//
//  Shared type definitions used across the app.
//

import SwiftUI

// MARK: - Font.Design Persistence

extension Font.Design: @retroactive RawRepresentable {
    public init?(rawValue: String) {
        switch rawValue {
        case "default": self = .default
        case "serif": self = .serif
        case "rounded": self = .rounded
        case "monospaced": self = .monospaced
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .default: return "default"
        case .serif: return "serif"
        case .rounded: return "rounded"
        case .monospaced: return "monospaced"
        @unknown default: return "default"
        }
    }

    var displayName: String {
        switch self {
        case .default: return "Default"
        case .serif: return "Serif"
        case .rounded: return "Rounded"
        case .monospaced: return "Monospaced"
        @unknown default: return "Default"
        }
    }
}

// MARK: - Prompter Theme

enum PrompterTheme: String, CaseIterable {
    case midnight
    case dark
    case light

    var displayName: String {
        switch self {
        case .midnight: return "Midnight"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }

    var backgroundColor: Color {
        switch self {
        case .midnight: return Color(red: 0.04, green: 0.05, blue: 0.10)
        case .dark: return .black
        case .light: return Color(red: 0.96, green: 0.97, blue: 0.98)
        }
    }

    var textColor: Color {
        switch self {
        case .midnight: return Color(red: 0.88, green: 0.92, blue: 1.0)
        case .dark: return .white
        case .light: return Color(red: 0.1, green: 0.1, blue: 0.12)
        }
    }

    var fadeColor: Color { backgroundColor }

    var accentColor: Color {
        switch self {
        case .midnight: return Color(red: 0.0, green: 0.82, blue: 1.0)
        case .dark: return Color(red: 0.55, green: 0.62, blue: 0.75)
        case .light: return Color(red: 0.22, green: 0.48, blue: 1.0)
        }
    }

    var glowColor: Color {
        switch self {
        case .midnight: return Color(red: 0.0, green: 0.82, blue: 1.0)
        case .dark: return .white
        case .light: return Color(red: 0.22, green: 0.48, blue: 1.0)
        }
    }

    var borderColor: Color {
        switch self {
        case .midnight: return Color.white.opacity(0.08)
        case .dark: return Color.white.opacity(0.10)
        case .light: return Color.black.opacity(0.08)
        }
    }
}

// MARK: - Horizontal Alignment (window position)

enum PrompterHorizontalAlignment: String, CaseIterable {
    case left, center, right

    var displayName: String {
        switch self {
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        }
    }

    var icon: String {
        switch self {
        case .left: return "arrow.left.to.line"
        case .center: return "arrow.left.and.right"
        case .right: return "arrow.right.to.line"
        }
    }
}

// MARK: - Text Alignment (within the prompter)

enum PrompterTextAlignment: String, CaseIterable {
    case leading, center, trailing

    var displayName: String {
        switch self {
        case .leading: return "Left"
        case .center: return "Center"
        case .trailing: return "Right"
        }
    }

    var icon: String {
        switch self {
        case .leading: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .trailing: return "text.alignright"
        }
    }

    var swiftUIAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

// MARK: - STT Engine Type

enum STTEngineType: String, CaseIterable {
    case apple
    case whisperKit

    var displayName: String {
        switch self {
        case .apple: return "Apple Speech"
        case .whisperKit: return "WhisperKit"
        }
    }
}

// MARK: - Notch-Connected Shape

/// A shape with concave (inverted) corners at the top that blend into the
/// macOS notch / menu-bar, and regular rounded corners at the bottom.
///
///     ╮                              ╭   ← inverted corners (top)
///     │        prompter area         │
///     ╰──────────────────────────────╯   ← rounded corners (bottom)
///
struct NotchConnectedShape: Shape {
    var topInvertedRadius: CGFloat = 10
    var bottomRadius: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        let ti = topInvertedRadius
        let br = bottomRadius
        var p = Path()

        p.move(to: CGPoint(x: ti, y: 0))
        p.addLine(to: CGPoint(x: rect.width - ti, y: 0))

        // Top-right inverted (concave) corner
        p.addQuadCurve(
            to: CGPoint(x: rect.width, y: ti),
            control: CGPoint(x: rect.width, y: 0)
        )

        p.addLine(to: CGPoint(x: rect.width, y: rect.height - br))

        // Bottom-right rounded corner
        p.addQuadCurve(
            to: CGPoint(x: rect.width - br, y: rect.height),
            control: CGPoint(x: rect.width, y: rect.height)
        )

        p.addLine(to: CGPoint(x: br, y: rect.height))

        // Bottom-left rounded corner
        p.addQuadCurve(
            to: CGPoint(x: 0, y: rect.height - br),
            control: CGPoint(x: 0, y: rect.height)
        )

        p.addLine(to: CGPoint(x: 0, y: ti))

        // Top-left inverted (concave) corner
        p.addQuadCurve(
            to: CGPoint(x: ti, y: 0),
            control: CGPoint(x: 0, y: 0)
        )

        p.closeSubpath()
        return p
    }
}
