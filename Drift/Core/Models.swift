import Foundation

/// A song (backed by a YouTube video ID).
struct Track: Codable, Hashable, Identifiable {
    var id: String          // YouTube video ID
    var title: String
    var artist: String
    var album: String?
    var duration: Double?   // seconds
    var artworkURL: URL?
    /// Podcast episode (any YouTube video played as a podcast) rather than a song.
    var podcast: Bool?
    var channelID: String?
    var channelAvatar: URL?
    var published: Date?
    /// Not on YouTube Music: a regular YouTube upload (often a fan upload) found for an imported song.
    var upload: Bool?

    var isEpisode: Bool { podcast == true }

    var durationText: String {
        guard let duration else { return "" }
        return formatTime(duration)
    }

    /// Artwork at roughly the requested pixel size.
    func artwork(size: Int) -> URL? {
        guard let artworkURL else {
            return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
        }
        let s = artworkURL.absoluteString
        if s.contains("googleusercontent.com") || s.contains("ggpht.com") {
            let resized = s.replacingOccurrences(
                of: "=w\\d+-h\\d+", with: "=w\(size)-h\(size)", options: .regularExpression)
            return URL(string: resized) ?? artworkURL
        }
        return artworkURL
    }
}

struct Playlist: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var tracks: [Track] = []
    var colorIndex: Int = 0
    /// How the cover is drawn. nil = automatic (artwork of the first songs).
    var coverStyle: CoverStyle?
    /// SF Symbol shown on a color cover.
    var coverSymbol: String?
    /// File name of a custom photo in Documents/Covers.
    var coverFile: String?
    /// Shown on your Drift profile. nil = yes (the default, like Spotify).
    var isPublic: Bool?
    /// Saved from an album page (listed under Albums in the Apple Music style).
    var isAlbum: Bool?
    var albumArtist: String?

    enum CoverStyle: String, Codable {
        case auto, color, photo
    }

    var style: CoverStyle { coverStyle ?? .auto }
    var symbol: String { coverSymbol ?? "music.note.list" }
    var isShared: Bool { isPublic ?? true }
}

func formatTime(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let s = Int(t.rounded(.down))
    if s >= 3600 {
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
    return String(format: "%d:%02d", s / 60, s % 60)
}

func formatTotal(_ tracks: [Track]) -> String {
    let total = Int(tracks.compactMap(\.duration).reduce(0, +))
    let h = total / 3600, m = (total % 3600) / 60
    return h > 0 ? "\(h) h \(m) min" : "\(m) min"
}

/// A YouTube channel followed as a podcast.
struct PodcastChannel: Codable, Hashable, Identifiable {
    var id: String          // "UC…" channel ID
    var name: String
    var avatarURL: URL?
    var subtitle: String?   // e.g. "1.2M subscribers"
}

/// Where someone stopped in an episode.
struct EpisodeProgress: Codable, Hashable {
    var track: Track
    var position: Double
    var duration: Double
    var updated: Date
    var finished: Bool
}

/// "1 hr 23 min" / "45 min".
func formatLength(_ seconds: Double) -> String {
    let m = max(1, Int((seconds / 60).rounded()))
    return m >= 60 ? "\(m / 60) hr \(m % 60) min" : "\(m) min"
}

func formatPublished(_ date: Date?) -> String? {
    guard let date else { return nil }
    if Date().timeIntervalSince(date) < 7 * 86400 {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate(Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "d MMM" : "d MMM yyyy")
    return f.string(from: date)
}
