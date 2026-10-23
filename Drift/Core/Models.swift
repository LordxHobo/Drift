import Foundation

/// A song (backed by a YouTube video ID).
struct Track: Codable, Hashable, Identifiable {
    var id: String          // YouTube video ID
    var title: String
    var artist: String
    var album: String?
    var duration: Double?   // seconds
    var artworkURL: URL?

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

    enum CoverStyle: String, Codable {
        case auto, color, photo
    }

    var style: CoverStyle { coverStyle ?? .auto }
    var symbol: String { coverSymbol ?? "music.note.list" }
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
