import Foundation

/// Where Drift keeps things on the phone. Downloads live in Documents, which the Files app shows
/// (On My iPhone › Drift › Downloads); everything else Drift saves for itself (library, settings,
/// covers…) lives out of sight, so it can't be moved or deleted there by accident.
enum AppFiles {
    /// Drift's own data, hidden from the Files app.
    static let data: URL = {
        let url = URL.applicationSupportDirectory.appending(path: "Drift", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Songs saved for offline (shown in the Files app).
    static let downloads = URL.documentsDirectory.appending(path: "Downloads", directoryHint: .isDirectory)

    /// Moves Drift's own files out of Documents (where older builds kept them). Runs before anything loads.
    static func migrate() {
        let fm = FileManager.default
        let docs = URL.documentsDirectory
        let names = ["library.json", "notifications.json", "playback.json", "artists.json", "podcasts.json",
                     "downloads-pending.json", "download-names.json", "spotify-import.log", "DownloadParts", "Covers"]
        for name in names {
            let from = docs.appending(path: name)
            let to = data.appending(path: name)
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
            try? fm.moveItem(at: from, to: to)
        }
        try? fm.createDirectory(at: downloads, withIntermediateDirectories: true)
    }
}
