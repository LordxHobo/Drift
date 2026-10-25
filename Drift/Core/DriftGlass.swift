import SwiftUI

/// Apple's Liquid Glass (iOS 26+), used when "Glass effects" is on in Settings → Appearance.
/// Builds with older Xcode versions too; there everything keeps its solid look.
enum DriftGlass {
    /// Glass can be shown on this iPhone (iOS 26 or newer, and Drift built with Xcode 26).
    static var isSupported: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    /// Glass is supported and switched on.
    static var isOn: Bool { isSupported && AppSettings.shared.glassEffects }
}

extension View {
    /// Glass in `shape` when glass is on; otherwise the solid `fallback` (or nothing).
    /// `clear` is the see-through glass; otherwise the frostier "regular" glass.
    @ViewBuilder
    func driftGlass<S: Shape>(in shape: S, clear: Bool = true, tint: Color? = nil,
                              interactive: Bool = false, fallback: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), DriftGlass.isOn {
            self.glassEffect(makeGlass(clear: clear, tint: tint, interactive: interactive), in: shape)
        } else {
            self.solidBackground(fallback, in: shape)
        }
        #else
        self.solidBackground(fallback, in: shape)
        #endif
    }

    @ViewBuilder
    fileprivate func solidBackground<S: Shape>(_ color: Color?, in shape: S) -> some View {
        if let color { self.background(color, in: shape) } else { self }
    }
}

#if compiler(>=6.2)
@available(iOS 26.0, *)
private func makeGlass(clear: Bool, tint: Color?, interactive: Bool) -> Glass {
    var g: Glass = clear ? .clear : .regular
    if let tint { g = g.tint(tint) }
    if interactive { g = g.interactive() }
    return g
}
#endif
