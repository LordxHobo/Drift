import SwiftUI

@main
struct DriftApp: App {
    init() {
        Player.shared.configureAudioSession()
        // Make sure the library is loaded before the first screen.
        _ = Library.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}
