import UIKit

/// The home screen icon follows the style: Drift's green icon, or the pink one for the Apple Music style.
@MainActor
enum AppIconSwitcher {
    /// Name of the other icon in the asset catalog (nil = the main one).
    private static var wanted: String? {
        AppSettings.shared.uiStyle == .music ? "AppIcon-Music" : nil
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
