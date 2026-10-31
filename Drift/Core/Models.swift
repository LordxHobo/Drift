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
    /// Marked explicit on YouTube Music (the "E" badge).
    var explicit: Bool?
    /// When it was added to its playlist or Liked songs (shown and sorted on the computer).
    var added: Date?
    /// Picked by hand with "Replace with another version": played exactly as it is.
    var chosen: Bool?
    /// Collaborative playlists: who added it (their profile ID).
    var addedBy: String?
    /// A podcast episode from a show's feed: its audio file (not on YouTube)…
    var audioURL: URL?
    /// …and the feed it's from (to open its show).
    var feedURL: URL?

    var isEpisode: Bool { podcast == true }
    /// From a show's feed (an audio file) rather than YouTube.
    var isFeedEpisode: Bool { audioURL != nil }

    var durationText: String {
        guard let duration else { return "" }
        return formatTime(duration)
    }

    /// Artwork at roughly the requested pixel size.
    func artwork(size: Int) -> URL? {
        guard let artworkURL else {
            return isFeedEpisode ? nil : URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
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
    /// Collaborative: shared with friends who can add, remove and move songs too.
    var collab: CollabInfo?
    /// The folder it's in (Your Library), if any.
    var folder: UUID?

    enum CoverStyle: String, Codable {
        case auto, color, photo
    }

    var style: CoverStyle { coverStyle ?? .auto }
    var symbol: String { coverSymbol ?? "music.note.list" }
    var isShared: Bool { isPublic ?? true }
}

/// A folder of playlists in Your Library.
struct PlaylistFolder: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
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
    var id: String          // "UC…" channel ID, or "rss-…" for a show from its feed
    var name: String
    var avatarURL: URL?
    var subtitle: String?   // e.g. "1.2M subscribers"
    /// A show from its own feed (RSS) rather than a YouTube channel.
    var feedURL: URL? = nil

    var isFeed: Bool { feedURL != nil }
    /// A square cover: a show from its feed, or one podcast (playlist) from a YouTube channel.
    var hasSquareCover: Bool { isFeed || id.hasPrefix("PL") }
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

/// Who a collaborative playlist is shared with.
struct CollabInfo: Codable, Hashable {
    /// Who made it (their profile ID).
    var owner: String
    var members: [String]
    /// Profile ID → username.
    var names: [String: String]

    /// "You, mira and echo"
    func names(me: String?) -> String {
        let list = members.map { $0 == me ? "You" : (names[$0] ?? "Someone") }
        guard list.count > 1 else { return list.joined() }
        return list.dropLast().joined(separator: ", ") + " and " + list.last!
    }
}
