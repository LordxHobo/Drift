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
    static let bg = Color(hex: 0x0E0E10)
    static let surface = Color(hex: 0x1A1A1F)
    static let surface2 = Color(hex: 0x26262D)
    static let line = Color(hex: 0x3F3F46)
    static let text = Color(hex: 0xF4F4F5)
    static let muted = Color(hex: 0xA1A1AA)
    static let onAccent = Color(hex: 0x1A1205)
    static let miniPlayer = Color(hex: 0x2A1F12)
    static let playerFallback = Color(hex: 0x2B1408)

    /// Amber, violet, coral, teal.
    static let accents: [UInt32] = [0xF5A524, 0x8B7CFF, 0xFF6B5B, 0x2DD4BF]

    /// Tile colors for playlists without artwork.
    static let tiles: [UInt32] = [0xC2410C, 0x0F766E, 0x6D28D9, 0xBE185D, 0x1E3A8A, 0x854D0E, 0x14532D, 0x9F1239]

    static func tile(_ i: Int) -> Color { Color(hex: tiles[abs(i) % tiles.count]) }

    static func tile(seed: String) -> Color {
        tile(seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF })
    }
}
