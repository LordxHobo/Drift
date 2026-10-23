import Foundation

struct LyricLine: Hashable {
    let time: Double
    let text: String
}

enum LyricsResult {
    case synced([LyricLine], source: String)
    case plain(String, source: String)
    case notFound
}

/// Synced lyrics from LRCLIB, with Genius (unsynced) as the fallback.
actor LyricsService {
    static let shared = LyricsService()

    private var cache: [String: LyricsResult] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpAdditionalHeaders = ["User-Agent": "Nightjar/1.0 (personal iOS music player)"]
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    func lyrics(for track: Track) async -> LyricsResult {
        if let cached = cache[track.id] { return cached }
        let title = Self.cleanTitle(track.title, artist: track.artist)
        let artist = Self.mainArtist(track.artist)

        var result = LyricsResult.notFound
        var plainFallback: String?

        if let lr = await lrclib(title: title, artist: artist, album: track.album, duration: track.duration) {
            if let synced = lr.synced, !synced.isEmpty {
                result = .synced(synced, source: "LRCLIB")
            } else if let plain = lr.plain, !plain.isEmpty {
                plainFallback = plain
            }
        }
        if case .notFound = result {
            if let genius = await genius(title: title, artist: artist) {
                result = .plain(genius, source: "Genius")
            } else if let plainFallback {
                result = .plain(plainFallback, source: "LRCLIB")
            }
        }
        if case .notFound = result {} else { cache[track.id] = result }
        return result
    }

    // MARK: LRCLIB

    private struct LRCLibEntry: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let duration: Double?
    }

    private func lrclib(title: String, artist: String, album: String?, duration: Double?)
        async -> (synced: [LyricLine]?, plain: String?)? {
        // 1. Exact lookup.
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        var items = [URLQueryItem(name: "track_name", value: title),
                     URLQueryItem(name: "artist_name", value: artist)]
        if let album { items.append(URLQueryItem(name: "album_name", value: album)) }
        if let duration { items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        c.queryItems = items
        if let url = c.url, let entry: LRCLibEntry = await fetchJSON(url),
           entry.syncedLyrics != nil || entry.plainLyrics != nil {
            return (entry.syncedLyrics.map(Self.parseLRC), entry.plainLyrics)
        }

        // 2. Search, preferring synced results close to the song's length.
        var s = URLComponents(string: "https://lrclib.net/api/search")!
        s.queryItems = [URLQueryItem(name: "track_name", value: title),
                        URLQueryItem(name: "artist_name", value: artist)]
        guard let url = s.url, let list: [LRCLibEntry] = await fetchJSON(url), !list.isEmpty else { return nil }
        func close(_ e: LRCLibEntry) -> Bool {
            guard let duration, let d = e.duration else { return true }
            return abs(d - duration) <= 5
        }
        if let best = list.first(where: { $0.syncedLyrics != nil && close($0) }) {
            return (best.syncedLyrics.map(Self.parseLRC), best.plainLyrics)
        }
        if let best = list.first(where: { $0.plainLyrics != nil && close($0) }) {
            return (nil, best.plainLyrics)
        }
        return nil
    }

    static func parseLRC(_ lrc: String) -> [LyricLine] {
        let tag = try! NSRegularExpression(pattern: "\\[(\\d+):(\\d+(?:\\.\\d+)?)\\]")
        var lines: [LyricLine] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = tag.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length)
                .trimmingCharacters(in: .whitespaces)
            for m in matches {
                let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
                lines.append(LyricLine(time: min * 60 + sec, text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    // MARK: Genius

    private struct GeniusSearch: Decodable {
        struct Response: Decodable { let sections: [Section] }
        struct Section: Decodable { let type: String; let hits: [Hit] }
        struct Hit: Decodable { let result: Result }
        struct Result: Decodable { let url: String? }
        let response: Response
    }

    private func genius(title: String, artist: String) async -> String? {
        var c = URLComponents(string: "https://genius.com/api/search/multi")!
        c.queryItems = [URLQueryItem(name: "q", value: "\(artist) \(title)")]
        guard let url = c.url,
              let search: GeniusSearch = await fetchJSON(url),
              let pageURL = search.response.sections.first(where: { $0.type == "song" })?
                  .hits.first?.result.url.flatMap(URL.init(string:))
        else { return nil }

        var req = URLRequest(url: pageURL)
        req.setValue(YTMusic.userAgent, forHTTPHeaderField: "User-Agent")
        guard let result = try? await session.data(for: req),
              let html = String(data: result.0, encoding: .utf8) else { return nil }
        return Self.extractGeniusLyrics(html)
    }

    /// Content ranges of every `<div ... marker ...>` element, matching nested divs.
    private static func divRanges(in html: String, marker: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = html.startIndex
        while let m = html.range(of: marker, range: searchStart..<html.endIndex),
              let open = html.range(of: ">", range: m.upperBound..<html.endIndex) {
            var depth = 1
            var i = open.upperBound
            var end = html.endIndex
            while i < html.endIndex {
                if html[i] == "<" {
                    let rest = html[i...]
                    if rest.hasPrefix("<div") { depth += 1 }
                    else if rest.hasPrefix("</div") {
                        depth -= 1
                        if depth == 0 { end = i; break }
                    }
                }
                i = html.index(after: i)
            }
            ranges.append(open.upperBound..<end)
            searchStart = end
        }
        return ranges
    }

    static func extractGeniusLyrics(_ html: String) -> String? {
        var parts: [String] = []
        for r in divRanges(in: html, marker: "data-lyrics-container=\"true\"") {
            var chunk = String(html[r])
            // Remove headers Genius injects into the container (contributors, "Lyrics" title...).
            while let ex = divRanges(in: chunk, marker: "data-exclude-from-selection=\"true\"").first,
                  let start = chunk[..<ex.lowerBound].range(of: "<div", options: .backwards),
                  let close = chunk.range(of: "</div>", range: ex.upperBound..<chunk.endIndex) {
                chunk.removeSubrange(start.lowerBound..<close.upperBound)
            }
            parts.append(chunk)
        }
        guard !parts.isEmpty else { return nil }
        var text = parts.joined(separator: "<br/>")
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        let named = ["&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&apos;": "'",
                     "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        let numeric = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        for m in numeric.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            guard let whole = Range(m.range, in: out),
                  let hexR = Range(m.range(at: 1), in: out),
                  let numR = Range(m.range(at: 2), in: out) else { continue }
            let radix = out[hexR].isEmpty ? 10 : 16
            if let code = UInt32(out[numR], radix: radix), let scalar = Unicode.Scalar(code) {
                out.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return out
    }

    // MARK: Helpers

    private func fetchJSON<T: Decodable>(_ url: URL) async -> T? {
        guard let result = try? await session.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: result.0)
    }

    static func cleanTitle(_ t: String, artist: String) -> String {
        var s = t.replacingOccurrences(
            of: "\\s*[\\(\\[][^\\)\\]]*(official|video|audio|lyric|visuali[sz]er|\\bhd\\b|4k|\\bmv\\b|remaster)[^\\)\\]]*[\\)\\]]",
            with: "", options: [.regularExpression, .caseInsensitive])
        // "Artist - Title" style video titles.
        let main = mainArtist(artist).lowercased()
        if !main.isEmpty, s.lowercased().hasPrefix(main), let dash = s.range(of: " - ") {
            s = String(s[dash.upperBound...])
        }
        // "Title - Remastered 2011" and similar.
        s = s.replacingOccurrences(of: "\\s+-\\s+.*(remaster|version|edit|mix).*$", with: "",
                                   options: [.regularExpression, .caseInsensitive])
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func mainArtist(_ a: String) -> String {
        let separators = [", ", " & ", " x ", " feat. ", " ft. "]
        var s = a
        for sep in separators {
            if let r = s.range(of: sep, options: .caseInsensitive) { s = String(s[..<r.lowerBound]) }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
