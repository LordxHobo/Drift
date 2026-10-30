import SwiftUI

@main
struct DriftApp: App {
    init() {
        // Older builds kept everything in Documents (now shown in the Files app): move Drift's own files.
        AppFiles.migrate()
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
                // The home screen icon follows the style (in case it was changed elsewhere).
                .task {
                    AppIconSwitcher.match()
                    // Collaborative playlists: changes from the others every 30 s while open.
                    CollabSync.shared.start()
                    // Listen Together invites from friends (every 20 s while open).
                    JamInvites.shared.start()
                }
        }
        // iOS wakes Drift up when background downloads finish.
        .backgroundTask(.urlSession(DownloadManager.sessionID)) {
            await DownloadManager.shared.handleBackgroundEvents()
        }
    }
}
