import Foundation
import UIKit
import Observation

/// A song as listed on a Spotify playlist or album page.
struct SpotifyTrack: Hashable {
    let title: String
    let artist: String
    let duration: Double?   // seconds
    /// When it was added on Spotify (kept as the song's "date added" in Drift).
    var added: Date? = nil
}

struct SpotifyList {
    let name: String
    let tracks: [SpotifyTrack]
    /// How many songs Spotify says the playlist has, when fewer could be read.
    var total: Int? = nil
    /// Only the first 100 could be read (Spotify's embed page).
    var limited = false
}

enum SpotifyImportError: LocalizedError {
    case badLink, notPublic, unreadable

    var errorDescription: String? {
        switch self {
        case .badLink: "That doesn't look like a Spotify playlist or album link."
        case .notPublic: "Couldn't open that playlist. Make sure it's public, then try again."
        case .unreadable: "Spotify's page couldn't be read. Try again in a moment."
        }
    }
}

/// Reads public playlists and albums from Spotify's embed page (no Spotify account or API key needed).
/// Spotify only includes the first 100 songs there.
enum SpotifyReader {
    static let embedLimit = 100

    static func read(link: String) async throws -> SpotifyList {
        var text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        // Share sheets sometimes add text around the link.
        if let r = text.range(of: "https?://\\S+", options: .regularExpression) { text = String(text[r]) }

        // Short links (spotify.link / spoti.fi) redirect to open.spotify.com.
        if let url = URL(string: text), let host = url.host,
           host.contains("spotify.link") || host.contains("spoti.fi") {
            var req = URLRequest(url: url)
            req.setValue(YTMusic.userAgent, forHTTPHeaderField: "User-Agent")
            if let result = try? await URLSession.shared.data(for: req), let final = result.1.url {
                text = final.absoluteString
            }
        }

        guard let match = text.range(of: "(playlist|album)[/:]([A-Za-z0-9]{10,})", options: .regularExpression) else {
            throw SpotifyImportError.badLink
        }
        let parts = text[match].split(whereSeparator: { $0 == "/" || $0 == ":" })
        guard parts.count == 2 else { throw SpotifyImportError.badLink }
        let kind = String(parts[0]), id = String(parts[1])

        // Playlists: read the whole thing through Spotify's web page; the embed below stops at 100.
        if kind == "playlist", let full = try? await SpotifyWebReader.read(playlistID: id), !full.tracks.isEmpty {
            return full
        }

        var req = URLRequest(url: URL(string: "https://open.spotify.com/embed/\(kind)/\(id)")!)
        req.setValue(YTMusic.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { throw SpotifyImportError.notPublic }

        guard let entity = entity(in: html) else { throw SpotifyImportError.unreadable }
        let name = (entity["name"] as? String) ?? (entity["title"] as? String) ?? "Spotify import"
        let list = (entity["trackList"] as? [[String: Any]]) ?? []
        let tracks: [SpotifyTrack] = list.compactMap { t in
            guard let title = t["title"] as? String, !title.isEmpty else { return nil }
            var artist = (t["subtitle"] as? String) ?? ""
            if artist.isEmpty, let artists = t["artists"] as? [[String: Any]] {
                artist = artists.compactMap { $0["name"] as? String }.joined(separator: ", ")
            }
            artist = artist.replacingOccurrences(of: "\u{00A0}", with: " ")
            let ms = (t["duration"] as? NSNumber)?.doubleValue
            return SpotifyTrack(title: title, artist: artist, duration: ms.map { $0 / 1000 })
        }
        guard !tracks.isEmpty else { throw SpotifyImportError.notPublic }
        return SpotifyList(name: name, tracks: tracks, limited: tracks.count >= embedLimit - 5)
    }

    /// The page keeps its data as JSON in a <script>; Spotify has used three formats for it.
    private static func entity(in html: String) -> [String: Any]? {
        let regex = try! NSRegularExpression(pattern: "<script([^>]*)>(.*?)</script>", options: [.dotMatchesLineSeparators])
        let ns = html as NSString
        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let attrs = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if attrs.contains("__NEXT_DATA__") {
                guard let json = jsonObject(Data(body.utf8)) else { continue }
                if let e = dig(json, ["props", "pageProps", "state", "data", "entity"]) { return e }
            } else if attrs.contains("initial-state") {
                guard let d = Data(base64Encoded: body), let json = jsonObject(d) else { continue }
                if let e = dig(json, ["data", "entity"]) { return e }
            } else if attrs.contains("\"resource\"") || attrs.contains("id=resource") {
                guard let d = Data(base64Encoded: body), let json = jsonObject(d) as? [String: Any] else { continue }
                return json
            }
        }
        return nil
    }

    private static func jsonObject(_ d: Data) -> Any? { try? JSONSerialization.jsonObject(with: d) }

    private static func dig(_ node: Any, _ path: [String]) -> [String: Any]? {
        var cur: Any? = node
        for key in path { cur = (cur as? [String: Any])?[key] }
        return cur as? [String: Any]
    }
}

/// Finds each Spotify song on YouTube Music.
enum SongMatcher {
    /// Official YouTube Music song first; if there is none, a regular YouTube upload
    /// (preferably from the artist's own channel).
    static func match(_ s: SpotifyTrack) async -> Track? {
        if let t = await matchOfficial(s) { return t }
        return await matchUpload(s)
    }

    /// Words that mean a different version, unless the song title itself has them.
    private static let otherVersions = ["live", "cover", "remix", "reaction", "karaoke", "instrumental",
                                        "slowed", "spedup", "nightcore", "8d", "1hour", "tutorial", "lesson"]

    static func matchUpload(_ s: SpotifyTrack) async -> Track? {
        let artist = LyricsService.mainArtist(s.artist)
        let query = "\(artist) \(s.title)"
        var results = try? await YouTubeSearch.search(query).episodes
        if results == nil {
            try? await Task.sleep(for: .seconds(2))
            results = try? await YouTubeSearch.search(query).episodes
        }
        guard let results, !results.isEmpty else { return nil }

        let wantTitle = normalize(s.title)
        let wantArtist = normalize(artist)
        guard !wantTitle.isEmpty else { return nil }
        let songWords = s.title.lowercased()
        var best: (Track, Double)?
        for (i, v) in results.prefix(8).enumerated() {
            let title = normalizeLoose(v.title)
            guard title.contains(wantTitle) else { continue }
            var score = 3 - 0.2 * Double(i)
            // The artist's own channel, its "- Topic" channel or VEVO.
            let channel = normalizeLoose(v.artist).replacingOccurrences(of: "topic", with: "")
                .replacingOccurrences(of: "vevo", with: "").replacingOccurrences(of: "official", with: "")
            if !wantArtist.isEmpty, !channel.isEmpty, channel.contains(wantArtist) || wantArtist.contains(channel) {
                score += 3
            } else if !wantArtist.isEmpty, title.contains(wantArtist) {
                score += 1
            } else {
                score -= 1
            }
            if let a = s.duration, let b = v.duration {
                let diff = abs(a - b)
                if diff > 60 { continue }
                if diff <= 3 { score += 3 } else if diff <= 10 { score += 1 } else if diff > 30 { score -= 3 }
            }
            for w in otherVersions where title.contains(w) && !normalizeLoose(songWords).contains(w) { score -= 3 }
            if best == nil || score > best!.1 { best = (v, score) }
        }
        guard let pick = best, pick.1 >= 4 else { return nil }
        let v = pick.0
        return Track(id: v.id, title: s.title, artist: s.artist, album: nil, duration: v.duration,
                     artworkURL: URL(string: "https://i.ytimg.com/vi/\(v.id)/hqdefault.jpg"), upload: true)
    }

    /// Lowercase letters and digits only, keeping words in brackets (for whole video titles).
    static func normalizeLoose(_ s: String) -> String {
        let t = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return String(t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func matchOfficial(_ s: SpotifyTrack) async -> Track? {
        let artist = LyricsService.mainArtist(s.artist)
        let query = "\(s.title) \(artist)"
        var results = try? await YTMusic.search(query, songsOnly: true)
        if results == nil {
            // Big imports can hit YouTube's rate limit: wait and try once more.
            try? await Task.sleep(for: .seconds(2))
            results = try? await YTMusic.search(query, songsOnly: true)
        }
        guard let results, !results.isEmpty else { return nil }

        let wantTitle = normalize(s.title)
        let wantArtist = normalize(artist)
        var best: (Track, Double)?
        for (i, t) in results.prefix(6).enumerated() {
            var score = -0.2 * Double(i)
            let title = normalize(t.title)
            if !wantTitle.isEmpty, title == wantTitle { score += 3 }
            else if !wantTitle.isEmpty, title.contains(wantTitle) || wantTitle.contains(title) { score += 2 }
            if !wantArtist.isEmpty, normalize(t.artist).contains(wantArtist) { score += 2 }
            if let a = s.duration, let b = t.duration {
                let diff = abs(a - b)
                if diff <= 3 { score += 2 } else if diff <= 10 { score += 1 } else if diff > 30 { score -= 3 }
            }
            if best == nil || score > best!.1 { best = (t, score) }
        }
        guard let best, best.1 >= 1 else { return nil }
        return best.0
    }

    /// Lowercase letters and digits only, without "(feat. …)", "- Remastered" and similar.
    static func normalize(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+-\\s+.*$", with: "", options: .regularExpression)
        t = t.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return String(t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}

/// Runs one import: read the list, match every song, save it as a Drift playlist.
@Observable @MainActor
final class SpotifyImporter {
    enum Phase: Equatable {
        case idle, reading, matching, done, failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var listName = ""
    private(set) var total = 0
    private(set) var processed = 0
    private(set) var unmatched: [SpotifyTrack] = []
    private(set) var playlistID: UUID?
    private(set) var hitLimit = false
    /// Spotify said the playlist has this many songs, but gave fewer.
    private(set) var spotifyTotal: Int?
    @ObservationIgnored private var matchStart: Date?

    /// Rough time left, from how fast songs have been found so far.
    var estimate: String? {
        guard phase == .matching, let start = matchStart, total > processed else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        guard processed >= 6, elapsed > 4 else { return "Estimating time left…" }
        return timeLeftText(elapsed / Double(processed) * Double(total - processed))
    }

    func start(link: String) {
        guard phase != .reading, phase != .matching else { return }
        phase = .reading
        unmatched = []
        processed = 0
        playlistID = nil
        Task {
            do {
                let list = try await SpotifyReader.read(link: link)
                listName = list.name
                total = list.tracks.count
                hitLimit = list.limited
                spotifyTotal = list.total
                phase = .matching
                matchStart = Date()
                // Keep the screen on: iOS pauses Drift when the phone locks and nothing is playing.
                UIApplication.shared.isIdleTimerDisabled = true
                defer { UIApplication.shared.isIdleTimerDisabled = false }

                // Saved in batches of 30, so a big import keeps what it found if interrupted.
                // Songs you already have (downloaded first) are reused as they are: no search needed.
                let local = Self.localIndex()
                let id = Library.shared.createPlaylist(list.name).id
                playlistID = id
                var start = 0
                while start < list.tracks.count {
                    let slice = Array(list.tracks[start..<min(start + 30, list.tracks.count)])
                    var matched = [Track?](repeating: nil, count: slice.count)
                    var toSearch: [Int] = []
                    for (i, s) in slice.enumerated() {
                        if let mine = Self.lookup(s, in: local) {
                            matched[i] = mine
                            processed += 1
                        } else {
                            toSearch.append(i)
                        }
                    }
                    let searched = await matchAll(toSearch.map { slice[$0] })
                    for (k, i) in toSearch.enumerated() { matched[i] = searched[k] }
                    var found: [Track] = []
                    for (i, t) in matched.enumerated() {
                        if var t {
                            // Keep Spotify's "date added" (or today's date when there isn't one).
                            t.added = slice[i].added
                            found.append(t)
                        } else {
                            unmatched.append(slice[i])
                        }
                    }
                    Library.shared.appendTracks(found, to: id)
                    start += 30
                }
                phase = .done
                if !unmatched.isEmpty {
                    let missing = unmatched.map { MissingSong(title: $0.title, artist: $0.artist, duration: $0.duration) }
                    NotificationStore.shared.post(AppNotification(
                        kind: .importReport,
                        title: "\(missing.count) \(missing.count == 1 ? "song" : "songs") not found in “\(list.name)”",
                        detail: "\(total - missing.count) of \(total) songs imported. Tap to see and copy the missing ones.",
                        playlistID: id, missing: missing))
                }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Your songs by title + main artist: downloaded songs first, then liked songs, then playlists.
    private static func localIndex() -> [String: [Track]] {
        let lib = Library.shared
        var index: [String: [Track]] = [:]
        var seen = Set<String>()
        for t in lib.downloaded + lib.liked + lib.playlists.flatMap(\.tracks) where !t.isEpisode {
            guard seen.insert(t.id).inserted else { continue }
            index[key(t.title, t.artist), default: []].append(t)
        }
        return index
    }

    private static func key(_ title: String, _ artist: String) -> String {
        SongMatcher.normalize(title) + "|" + SongMatcher.normalize(LyricsService.mainArtist(artist))
    }

    /// The copy you already have of this song, if any (same title and artist, about the same length).
    private static func lookup(_ s: SpotifyTrack, in index: [String: [Track]]) -> Track? {
        guard let candidates = index[key(s.title, s.artist)] else { return nil }
        return candidates.first { t in
            guard let a = s.duration, let b = t.duration else { return true }
            return abs(a - b) <= 10
        }
    }

    /// Matches in parallel (6 at a time) and keeps the original order.
    private func matchAll(_ tracks: [SpotifyTrack]) async -> [Track?] {
        var results = [Track?](repeating: nil, count: tracks.count)
        await withTaskGroup(of: (Int, Track?).self) { group in
            var next = 0
            func add() {
                guard next < tracks.count else { return }
                let i = next, t = tracks[i]
                next += 1
                group.addTask { (i, await SongMatcher.match(t)) }
            }
            for _ in 0..<6 { add() }
            while let result = await group.next() {
                results[result.0] = result.1
                processed += 1
                add()
            }
        }
        return results
    }
}
