//
//  CursorAppearance.swift
//  Sage
//
//  Sage's colors. The menu bar menu is a native macOS menu and uses the
//  system's own styling, so the only custom colors are for the on-screen
//  cursor overlay.
//

import AppKit
import SwiftUI

enum CursorAppearance {
    enum Colors {
        /// Sage green, bright enough to stand out on both light and dark apps.
        static let cursor = Color(hex: "#3DDC97")
        /// Dark text that stays readable on top of the green cursor bubble.
        static let textOnCursor = Color(hex: "#06281A")
    }
}

/// The cursor colors offered in the menu. `invisible` hides the overlay
/// entirely: Sage still listens and talks, but nothing is drawn on screen.
enum CursorColorOption: String, CaseIterable, Identifiable {
    case sage
    case blue
    case purple
    case pink
    case orange
    case invisible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sage: return "Sage Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .orange: return "Orange"
        case .invisible: return "Invisible (Voice Only)"
        }
    }

    var isInvisible: Bool { self == .invisible }

    /// Hex values for the cursor and for text on top of it, picked so labels
    /// stay readable: dark text on light colors, white text on deep ones.
    private var cursorHex: String {
        switch self {
        case .sage, .invisible: return "#3DDC97"
        case .blue: return "#3B9EFF"
        case .purple: return "#A57CFF"
        case .pink: return "#FF6FB5"
        case .orange: return "#FF9F40"
        }
    }

    private var textHex: String {
        switch self {
        case .sage, .invisible: return "#06281A"
        case .blue, .purple: return "#FFFFFF"
        case .pink: return "#3A0A22"
        case .orange: return "#2E1600"
        }
    }

    var cursorColor: Color { Color(hex: cursorHex) }
    var textColor: Color { Color(hex: textHex) }

    /// The same color for AppKit, used for the swatch in the menu.
    var menuSwatchColor: NSColor {
        let rgbValue = UInt64(cursorHex.dropFirst(), radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((rgbValue & 0xFF0000) >> 16) / 255,
                       green: CGFloat((rgbValue & 0x00FF00) >> 8) / 255,
                       blue: CGFloat(rgbValue & 0x0000FF) / 255,
                       alpha: 1)
    }
}

/// The chosen colors travel through the SwiftUI environment, so every piece
/// of the overlay (triangle, waveform, spinner, bubbles) recolors at once.
private struct CursorColorEnvironmentKey: EnvironmentKey {
    static let defaultValue = CursorAppearance.Colors.cursor
}

private struct CursorTextColorEnvironmentKey: EnvironmentKey {
    static let defaultValue = CursorAppearance.Colors.textOnCursor
}

extension EnvironmentValues {
    var sageCursorColor: Color {
        get { self[CursorColorEnvironmentKey.self] }
        set { self[CursorColorEnvironmentKey.self] = newValue }
    }

    var sageCursorTextColor: Color {
        get { self[CursorTextColorEnvironmentKey.self] }
        set { self[CursorTextColorEnvironmentKey.self] = newValue }
    }
}

// MARK: - Hex Colors

extension Color {
    /// Creates a color from a hex string like "#3DDC97".
    init(hex: String) {
        let hexDigits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgbValue: UInt64 = 0
        Scanner(string: hexDigits).scanHexInt64(&rgbValue)

        self.init(
            red: Double((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: Double((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgbValue & 0x0000FF) / 255.0
        )
    }
}
