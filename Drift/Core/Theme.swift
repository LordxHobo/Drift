import SwiftUI
import UIKit

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

enum Theme {
    /// A color with a dark-mode and a light-mode version (follows the chosen appearance).
    static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .light ? UIColor(hex: light) : UIColor(hex: dark) })
    }

    /// The Apple Music–style look (Settings → Appearance → Style).
    static var isMusic: Bool { AppSettings.shared.uiStyle == .music }

    private static let spotify = Palette(
        bg: dynamic(dark: 0x0E0E10, light: 0xFFFFFF), surface: dynamic(dark: 0x1A1A1F, light: 0xF1F1F3),
        surface2: dynamic(dark: 0x26262D, light: 0xE4E4E8), line: dynamic(dark: 0x3F3F46, light: 0xD4D4D8),
        text: dynamic(dark: 0xF4F4F5, light: 0x111113), text2: dynamic(dark: 0xD4D4D8, light: 0x3F3F46),
        muted: dynamic(dark: 0xA1A1AA, light: 0x6B6B73), searchField: dynamic(dark: 0xF4F4F5, light: 0xE9E9EC),
        searchText: Color(hex: 0x18181B), onAccent: Color(hex: 0x0E0E10))
    private static let music = Palette(
        bg: dynamic(dark: 0x000000, light: 0xFFFFFF), surface: dynamic(dark: 0x1C1C1E, light: 0xF2F2F7),
        surface2: dynamic(dark: 0x2C2C2E, light: 0xE5E5EA), line: dynamic(dark: 0x38383A, light: 0xD1D1D6),
        text: dynamic(dark: 0xFFFFFF, light: 0x000000), text2: dynamic(dark: 0xEBEBF0, light: 0x3C3C43),
        muted: dynamic(dark: 0x8E8E93, light: 0x8A8A8E), searchField: dynamic(dark: 0x1C1C1E, light: 0xEEEEF0),
        searchText: dynamic(dark: 0xFFFFFF, light: 0x000000), onAccent: Color(hex: 0xFFFFFF))

    private struct Palette {
        let bg, surface, surface2, line, text, text2, muted, searchField, searchText, onAccent: Color
    }

    private static var p: Palette { isMusic ? music : spotify }

    static var bg: Color { p.bg }
    static var surface: Color { p.surface }
    static var surface2: Color { p.surface2 }
    static var line: Color { p.line }
    static var text: Color { p.text }
    /// Slightly softer than `text`.
    static var text2: Color { p.text2 }
    static var muted: Color { p.muted }
    static var searchField: Color { p.searchField }
    static var searchText: Color { p.searchText }
    static var onAccent: Color { p.onAccent }

    /// Big page titles ("Home", "Library"…).
    static var titleFont: Font {
        isMusic ? .system(size: 34, weight: .bold) : .system(size: 26, weight: .heavy)
    }

    /// Apple Music's red.
    static let musicRed: UInt32 = 0xFA2D48
    // The player and mini player always stay dark.
    static let miniPlayer = Color(hex: 0x16241B)
    static let playerFallback = Color(hex: 0x1A2B21)

    /// Green (matches the icon), amber, violet, coral, teal.
    static let accents: [UInt32] = [0x1ED760, 0xF5A524, 0x8B7CFF, 0xFF6B5B, 0x2DD4BF]
    static let accentNames = ["Green", "Amber", "Violet", "Coral", "Teal"]

    /// Tile colors for playlists without artwork.
    static let tiles: [UInt32] = [0xC2410C, 0x0F766E, 0x6D28D9, 0xBE185D, 0x1E3A8A, 0x854D0E, 0x14532D, 0x9F1239]

    static func tile(_ i: Int) -> Color { Color(hex: tiles[abs(i) % tiles.count]) }

    static func tile(seed: String) -> Color {
        tile(seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF })
    }
}
