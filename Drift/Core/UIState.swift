import SwiftUI
import Observation
import CoreImage

/// App-wide UI state (sheets that can be opened from any track menu).
@Observable @MainActor
final class UIState {
    static let shared = UIState()
    var addToPlaylist: Track?
    var showPlayer = false
    private init() {}
}

/// Background color for the player, taken from the artwork and darkened so white text stays readable.
@MainActor
enum ArtworkPalette {
    private static var cache: [URL: UIColor] = [:]
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    static func color(for url: URL?) async -> Color? {
        guard let url else { return nil }
        if let c = cache[url] { return Color(uiColor: c) }
        guard let result = try? await URLSession.shared.data(from: url),
              let ci = CIImage(data: result.0) else { return nil }
        let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ci,
            kCIInputExtentKey: CIVector(cgRect: ci.extent),
        ])
        guard let output = filter?.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &px, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        let avg = UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        avg.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let dark = UIColor(hue: h, saturation: min(s * 1.1, 0.75), brightness: min(max(b * 0.55, 0.12), 0.32), alpha: 1)
        cache[url] = dark
        return Color(uiColor: dark)
    }
}
