import ActivityKit
import Foundation

/// Shared between the app and the DriftLyrics widget extension.
struct LyricsActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        /// Current lyric line; empty while there are no synced lyrics or between lines.
        var line: String
        var nextLine: String
        var isPlaying: Bool
        /// "synced", "unsynced" or "none".
        var lyricsKind: String
    }
}
