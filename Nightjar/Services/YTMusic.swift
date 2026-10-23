import Foundation

/// Search through YouTube Music's own web API (the one music.youtube.com uses).
enum YTMusic {
    private static let endpoint = URL(string: "https://music.youtube.com/youtubei/v1/search?prettyPrint=false")!
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"

    /// "Songs" filter: album/official audio only.
    private static let songsParams = "EgWKAQIIAWoMEA4QChADEAQQCRAF"

    /// Same scheme music.youtube.com uses: "1.<today's date>.01.00".
    private static var clientVersion: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd"
        return "1.\(f.string(from: Date())).01.00"
    }

    static func search(_ query: String, songsOnly: Bool) async throws -> [Track] {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        var body: [String: Any] = [
            "context": ["client": [
                "clientName": "WEB_REMIX",
                "clientVersion": clientVersion,
                "hl": "en",
            ]],
            "query": query,
        ]
        if songsOnly { body["params"] = songsParams }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data)

        var out: [Track] = []
        var seen = Set<String>()
        collect(json) { renderer in
            if let t = parse(renderer), seen.insert(t.id).inserted { out.append(t) }
        }
        return out
    }

    // MARK: JSON walking

    private static func collect(_ node: Any, _ found: ([String: Any]) -> Void) {
        if let d = node as? [String: Any] {
            if let r = d["musicResponsiveListItemRenderer"] as? [String: Any] {
                found(r)
                return
            }
            for key in d.keys.sorted() { collect(d[key]!, found) }
        } else if let a = node as? [Any] {
            for v in a { collect(v, found) }
        }
    }

    private static func firstVideoID(_ node: Any) -> String? {
        if let d = node as? [String: Any] {
            if let v = d["videoId"] as? String { return v }
            for key in d.keys.sorted() { if let v = firstVideoID(d[key]!) { return v } }
        } else if let a = node as? [Any] {
            for v in a { if let id = firstVideoID(v) { return id } }
        }
        return nil
    }

    private static func texts(_ column: Any?, renderer: String) -> [String] {
        guard let c = column as? [String: Any],
              let r = c[renderer] as? [String: Any],
              let text = r["text"] as? [String: Any],
              let runs = text["runs"] as? [[String: Any]] else { return [] }
        return runs.compactMap { $0["text"] as? String }
    }

    private static func parse(_ r: [String: Any]) -> Track? {
        guard let cols = r["flexColumns"] as? [Any], let first = cols.first else { return nil }
        let videoID = ((r["playlistItemData"] as? [String: Any])?["videoId"] as? String) ?? firstVideoID(first)
        guard let videoID else { return nil }

        let title = texts(first, renderer: "musicResponsiveListItemFlexColumnRenderer").joined()
        guard !title.isEmpty else { return nil }

        let meta = cols.count > 1 ? texts(cols[1], renderer: "musicResponsiveListItemFlexColumnRenderer").joined() : ""
        var parts = meta.components(separatedBy: "•")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let f = parts.first, ["Song", "Video", "Episode"].contains(f) { parts.removeFirst() }

        var duration: Double?
        if let last = parts.last, let d = parseDuration(last) {
            duration = d
            parts.removeLast()
        }
        if duration == nil, let fixed = (r["fixedColumns"] as? [Any])?.first {
            duration = parseDuration(texts(fixed, renderer: "musicResponsiveListItemFixedColumnRenderer").joined())
        }
        // Artists, albums and playlists have no duration; only keep playable songs/videos.
        guard duration != nil else { return nil }

        let artist = parts.first ?? ""
        let album = parts.count > 1 && !parts[1].lowercased().contains("view") && !parts[1].lowercased().contains("play")
            ? parts[1] : nil

        let thumbs = ((((r["thumbnail"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any])?["thumbnail"]
            as? [String: Any])?["thumbnails"] as? [[String: Any]]) ?? []
        let art = (thumbs.last?["url"] as? String).flatMap(URL.init(string:))

        return Track(id: videoID, title: title, artist: artist, album: album, duration: duration, artworkURL: art)
    }

    static func parseDuration(_ s: String) -> Double? {
        let comps = s.split(separator: ":")
        guard (2...3).contains(comps.count) else { return nil }
        var total = 0.0
        for c in comps {
            guard let n = Int(c) else { return nil }
            total = total * 60 + Double(n)
        }
        return total
    }
}
