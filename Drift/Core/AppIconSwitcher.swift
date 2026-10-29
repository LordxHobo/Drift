import SwiftUI
import UIKit

/// The home screen icon follows the style: Drift's green icon, or the pink or white one (picked in
/// Settings) for the Apple Music style.
@MainActor
enum AppIconSwitcher {
    /// Name of the other icon in the asset catalog (nil = the main one).
    private static var wanted: String? {
        let s = AppSettings.shared
        guard s.uiStyle == .music else { return nil }
        return s.musicIcon == .white ? "AppIcon-MusicLight" : "AppIcon-Music"
    }

    static func match() {
        let app = UIApplication.shared
        // Only when it's different: iOS shows a short "icon changed" message each time.
        guard app.supportsAlternateIcons, app.alternateIconName != wanted else { return }
        app.setAlternateIconName(wanted) { error in
            if let error { print("Couldn't change the icon:", error.localizedDescription) }
        }
    }
}

/// A small drawing of an Apple Music style icon (the real icon files can't be shown inside the app).
struct AppIconPreview: View {
    let icon: MusicIcon
    var size: CGFloat

    private static let pink = LinearGradient(colors: [Color(red: 1, green: 85 / 255, blue: 135 / 255),
                                                      Color(red: 1, green: 0, blue: 70 / 255)],
                                             startPoint: .top, endPoint: .bottom)
    /// Drift's four bars, as fractions of the icon (x, top, bottom), each 96/1024 wide.
    private static let bars: [(CGFloat, CGFloat, CGFloat)] = [
        (266, 301, 721), (398, 371, 651), (530, 251, 771), (662, 331, 691),
    ]

    var body: some View {
        let unit = size / 1024
        ZStack(alignment: .topLeading) {
            if icon == .pink { Self.pink } else { Color.white }
            ForEach(Self.bars.indices, id: \.self) { i in
                let b = Self.bars[i]
                Capsule()
                    .fill(icon == .pink ? AnyShapeStyle(Color.white) : AnyShapeStyle(Self.pink))
                    .frame(width: 96 * unit, height: (b.2 - b.1) * unit)
                    .offset(x: b.0 * unit, y: b.1 * unit)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .accessibilityHidden(true)
    }
}
