import Foundation

/// Sorting a playlist, Liked songs or downloads by title, artist, album or date added
/// (the same rules as the computer). Remembered per list.
struct SongSort: Codable, Equatable {
    enum Key: String, Codable, CaseIterable {
        case title, artist, album, added

        var label: String {
            switch self {
            case .title: "Title"
            case .artist: "Artist"
            case .album: "Album"
            case .added: "Recently added"
            }
        }
    }

    var key: Key
    var ascending: Bool

    /// A new sort starts A→Z, or newest first for the date.
    static func first(_ key: Key) -> SongSort { SongSort(key: key, ascending: key != .added) }

    /// "A–Z", "Z–A", "Newest first", "Oldest first".
    var directionLabel: String {
        key == .added ? (ascending ? "Oldest first" : "Newest first") : (ascending ? "A–Z" : "Z–A")
    }

    // MARK: Remembered per list

    static func saved(for list: String) -> SongSort? {
        guard let data = UserDefaults.standard.data(forKey: "sort.\(list)") else { return nil }
        return try? JSONDecoder().decode(SongSort.self, from: data)
    }

    static func save(_ sort: SongSort?, for list: String) {
        if let sort, let data = try? JSONEncoder().encode(sort) {
            UserDefaults.standard.set(data, forKey: "sort.\(list)")
        } else {
            UserDefaults.standard.removeObject(forKey: "sort.\(list)")
        }
    }

    // MARK: Sorting

    /// Leading "The " / "A " and symbols don't count when sorting by name (like Spotify).
    private static func name(_ s: String?) -> String {
        var t = (s ?? "").trimmingCharacters(in: .whitespaces)
        for prefix in ["the ", "a "] where t.lowercased().hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
        return String(t.drop { !$0.isLetter && !$0.isNumber })
    }

    private static func compare(_ a: String?, _ b: String?) -> ComparisonResult {
        name(a).compare(name(b), options: [.caseInsensitive, .diacriticInsensitive, .numeric])
    }

    /// Positions (in `places`, the songs' places in the full list) in sorted order. Songs added before
    /// dates were kept count as older than any dated song, in list order (`newestFirst`: Liked songs,
    /// where the newest is at the top).
    func order(_ tracks: [Track], places: [Int], newestFirst: Bool = false) -> [Int] {
        let sign: (ComparisonResult) -> Bool = { ascending ? $0 == .orderedAscending : $0 == .orderedDescending }
        return tracks.indices.sorted { i, j in
            let a = tracks[i], b = tracks[j]
            switch key {
            case .added:
                let undated = { (k: Int) -> Int in newestFirst ? -places[k] : places[k] }
                let c: ComparisonResult
                switch (a.added, b.added) {
                case let (x?, y?): c = x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
                case (.some, .none): c = .orderedDescending
                case (.none, .some): c = .orderedAscending
                case (.none, .none):
                    let (x, y) = (undated(i), undated(j))
                    c = x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
                }
                return c == .orderedSame ? places[i] < places[j] : sign(c)
            case .title, .artist, .album:
                let field = { (t: Track) -> String? in key == .title ? t.title : key == .artist ? t.artist : t.album }
                var c = Self.compare(field(a), field(b))
                // Same artist or album: keep its songs together in a sensible order.
                if c == .orderedSame, key != .title {
                    c = Self.compare(a.album, b.album)
                    if c == .orderedSame { c = Self.compare(a.title, b.title) }
                }
                return c == .orderedSame ? places[i] < places[j] : sign(c)
            }
        }
    }
}
