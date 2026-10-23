import Foundation
import UIKit
import Observation

/// A song as listed on a Spotify playlist or album page.
struct SpotifyTrack: Hashable {
    let title: String
    let artist: String
    let duration: Double?   // seconds
}

struct SpotifyList {
    let name: String
    let tracks: [SpotifyTrack]
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
        return SpotifyList(name: name, tracks: tracks)
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
    static func match(_ s: SpotifyTrack) async -> Track? {
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
                hitLimit = list.tracks.count == SpotifyReader.embedLimit
                phase = .matching
                // Keep the screen on: iOS pauses Drift when the phone locks and nothing is playing.
                UIApplication.shared.isIdleTimerDisabled = true
                defer { UIApplication.shared.isIdleTimerDisabled = false }

                // Saved in batches of 30, so a big import keeps what it found if interrupted.
                let id = Library.shared.createPlaylist(list.name).id
                playlistID = id
                var start = 0
                while start < list.tracks.count {
                    let slice = Array(list.tracks[start..<min(start + 30, list.tracks.count)])
                    let matched = await matchAll(slice)
                    var found: [Track] = []
                    for (i, t) in matched.enumerated() {
                        if let t { found.append(t) } else { unmatched.append(slice[i]) }
                    }
                    Library.shared.appendTracks(found, to: id)
                    start += 30
                }
                phase = .done
            } catch {
                phase = .failed(error.localizedDescription)
            }
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
