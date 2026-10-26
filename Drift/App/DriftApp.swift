import SwiftUI

@main
struct DriftApp: App {
    init() {
        Player.shared.configureAudioSession()
        // Make sure the library is loaded before the first screen.
        _ = Library.shared
        // Reconnect to downloads iOS carried on with in the background.
        _ = DownloadManager.shared
        DownloadManager.registerBackgroundTask()
        Task { await StreamResolver.shared.warmUp() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        // iOS wakes Drift up when background downloads finish.
        .backgroundTask(.urlSession(DownloadManager.sessionID)) {
            await DownloadManager.shared.handleBackgroundEvents()
        }
    }
}
