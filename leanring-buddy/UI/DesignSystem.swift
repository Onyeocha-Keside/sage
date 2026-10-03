//
//  DesignSystem.swift
//  Sage
//
//  Sage's colors. The menu bar menu is a native macOS menu and uses the
//  system's own styling, so the only custom colors are for the on-screen
//  cursor overlay.
//

import SwiftUI

enum DS {
    enum Colors {
        /// Sage green, bright enough to stand out on both light and dark apps.
        static let cursor = Color(hex: "#3DDC97")
        /// Dark text that stays readable on top of the green cursor bubble.
        static let textOnCursor = Color(hex: "#06281A")
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
