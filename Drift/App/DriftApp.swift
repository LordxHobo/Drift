import SwiftUI

@main
struct DriftApp: App {
    init() {
        Player.shared.configureAudioSession()
        // Make sure the library is loaded before the first screen.
        _ = Library.shared
        Task { await StreamResolver.shared.warmUp() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}
