import Foundation

/// Regular YouTube (not YouTube Music): podcast/video search, channel episodes and links.
enum YouTubeSearch {
    private static let api = "https://www.youtube.com/youtubei/v1/"

    private static var clientVersion: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd"
        return "2.\(f.string(from: Date().addingTimeInterval(-86400))).00.00"
    }

    private static func post(_ path: String, _ body: [String: Any]) async throws -> Any {
        var req = URLRequest(url: URL(string: api + path + "?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(YTMusic.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        var full = body
        full["context"] = ["client": ["clientName": "WEB", "clientVersion": clientVersion, "hl": "en", "gl": "US"]]
        req.httpBody = try JSONSerialization.data(withJSONObject: full)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: Search

    static func search(_ query: String) async throws -> (channels: [PodcastChannel], episodes: [Track]) {
        let json = try await post("search", ["query": query])
        var channels: [PodcastChannel] = []
        var episodes: [Track] = []
        var seen = Set<String>()
        walk(json) { key, value in
            switch key {
            case "channelRenderer":
                if let c = parseChannel(value), !channels.contains(where: { $0.id == c.id }) { channels.append(c) }
            case "videoRenderer":
                if let t = parseVideo(value), seen.insert(t.id).inserted { episodes.append(t) }
            case "lockupViewModel":
                if let t = parseLockup(value), seen.insert(t.id).inserted { episodes.append(t) }
            default: break
            }
        }
        return (channels, episodes)
    }

    /// A YouTube link (watch, youtu.be, shorts, live, embed, music.youtube) → video ID.
    static func videoID(fromLink text: String) -> String? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.contains("youtu") else { return nil }
        let patterns = ["[?&]v=([A-Za-z0-9_-]{11})", "youtu\\.be/([A-Za-z0-9_-]{11})",
                        "/(?:shorts|live|embed)/([A-Za-z0-9_-]{11})"]
        for p in patterns {
            if let r = s.range(of: p, options: .regularExpression) {
                let m = String(s[r])
                return String(m.suffix(11))
            }
        }
        return nil
    }

    /// Looks up one video from its link.
    static func resolve(link: String) async throws -> Track? {
        guard let id = videoID(fromLink: link) else { return nil }
        if let found = try? await search(id).episodes.first(where: { $0.id == id }) { return found }

        // Fallback: oEmbed gives title and channel name.
        var c = URLComponents(string: "https://www.youtube.com/oembed")!
        c.queryItems = [URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(id)"),
                        URLQueryItem(name: "format", value: "json")]
        struct OEmbed: Decodable { let title: String; let author_name: String? }
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        let o = try JSONDecoder().decode(OEmbed.self, from: data)
        return Track(id: id, title: o.title, artist: o.author_name ?? "YouTube", album: nil, duration: nil,
                     artworkURL: URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg"), podcast: true)
    }

    // MARK: Channel episodes

    /// Latest episodes of a channel: the channel's RSS feed, or its Videos tab if the feed fails.
    static func channelEpisodes(_ channel: PodcastChannel) async throws -> [Track] {
        if let rss = try? await rssEpisodes(channel), !rss.isEmpty { return rss }
        let json = try await post("browse", ["browseId": channel.id, "params": "EgZ2aWRlb3PyBgQKAjoA"])
        var out: [Track] = []
        var seen = Set<String>()
        walk(json) { key, value in
            var t: Track?
            if key == "videoRenderer" { t = parseVideo(value) }
            if key == "lockupViewModel" { t = parseLockup(value) }
            guard var t, seen.insert(t.id).inserted else { return }
            t.channelID = channel.id
            if t.artist.isEmpty || t.artist == "YouTube" { t.artist = channel.name }
            if t.channelAvatar == nil { t.channelAvatar = channel.avatarURL }
            out.append(t)
        }
        return out
    }

    private static func rssEpisodes(_ channel: PodcastChannel) async throws -> [Track] {
        let url = URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channel.id)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let parser = FeedParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { throw URLError(.cannotParseResponse) }
        let iso = ISO8601DateFormatter()
        return parser.entries.compactMap { e in
            guard e.id.count == 11, !e.link.contains("/shorts/") else { return nil }
            return Track(id: e.id, title: e.title, artist: e.author.isEmpty ? channel.name : e.author,
                         album: nil, duration: nil,
                         artworkURL: URL(string: "https://i.ytimg.com/vi/\(e.id)/mqdefault.jpg"),
                         podcast: true, channelID: channel.id, channelAvatar: channel.avatarURL,
                         published: iso.date(from: e.published))
        }
    }

    // MARK: Parsing

    private static func walk(_ node: Any, _ found: (String, [String: Any]) -> Void) {
        if let d = node as? [String: Any] {
            for key in d.keys.sorted() {
                let v = d[key]!
                if ["videoRenderer", "channelRenderer", "lockupViewModel"].contains(key), let r = v as? [String: Any] {
                    found(key, r)
                } else {
                    walk(v, found)
                }
            }
        } else if let a = node as? [Any] {
            for v in a { walk(v, found) }
        }
    }

    private static func dig(_ node: Any?, _ path: [Any]) -> Any? {
        var cur = node
        for k in path {
            if let key = k as? String { cur = (cur as? [String: Any])?[key] }
            else if let i = k as? Int, let a = cur as? [Any], a.indices.contains(i) { cur = a[i] }
            else { return nil }
        }
        return cur
    }

    private static func text(_ node: Any?) -> String? {
        guard let d = node as? [String: Any] else { return nil }
        if let s = d["simpleText"] as? String { return s }
        if let s = d["content"] as? String { return s }
        if let runs = d["runs"] as? [[String: Any]] { return runs.compactMap { $0["text"] as? String }.joined() }
        return nil
    }

    private static func url(_ s: String?) -> URL? {
        guard var s, !s.isEmpty else { return nil }
        if s.hasPrefix("//") { s = "https:" + s }
        return URL(string: s)
    }

    /// Every string in a subtree, in order.
    private static func strings(_ node: Any?) -> [String] {
        if let s = node as? String { return [s] }
        if let d = node as? [String: Any] { return d.keys.sorted().flatMap { strings(d[$0]) } }
        if let a = node as? [Any] { return a.flatMap { strings($0) } }
        return []
    }

    private static func parseVideo(_ r: [String: Any]) -> Track? {
        guard let id = r["videoId"] as? String, let title = text(r["title"]) else { return nil }
        // Live streams have no length; shorts are under a minute.
        guard let len = text(r["lengthText"]), let duration = YTMusic.parseDuration(len), duration >= 60 else { return nil }
        let owner = dig(r, ["ownerText", "runs", 0]) as? [String: Any]
        let channelID = dig(owner, ["navigationEndpoint", "browseEndpoint", "browseId"]) as? String
        let avatar = dig(r, ["channelThumbnailSupportedRenderers", "channelThumbnailWithLinkRenderer",
                             "thumbnail", "thumbnails", 0, "url"]) as? String
        let thumb = ((dig(r, ["thumbnail", "thumbnails"]) as? [[String: Any]])?.last?["url"] as? String)
        return Track(id: id, title: title, artist: (owner?["text"] as? String) ?? "", album: nil,
                     duration: duration,
                     artworkURL: url(thumb) ?? URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg"),
                     podcast: true, channelID: channelID, channelAvatar: url(avatar),
                     published: relativeDate(text(r["publishedTimeText"])))
    }

    private static func parseLockup(_ v: [String: Any]) -> Track? {
        guard let id = v["contentId"] as? String, id.count == 11,
              (v["contentType"] as? String) == "LOCKUP_CONTENT_TYPE_VIDEO" else { return nil }
        let meta = dig(v, ["metadata", "lockupMetadataViewModel"]) as? [String: Any]
        guard let title = text(meta?["title"]) else { return nil }

        let overlays = dig(v, ["contentImage", "thumbnailViewModel", "overlays"])
        guard let duration = strings(overlays).lazy.compactMap({ YTMusic.parseDuration($0) }).first,
              duration >= 60 else { return nil }

        var channel = "", channelID: String?
        let rows = dig(meta, ["metadata", "contentMetadataViewModel", "metadataRows"]) as? [[String: Any]] ?? []
        for row in rows {
            for part in row["metadataParts"] as? [[String: Any]] ?? [] {
                if let browse = dig(part, ["text", "commandRuns", 0, "onTap", "innertubeCommand", "browseEndpoint", "browseId"]) as? String,
                   browse.hasPrefix("UC") {
                    channelID = browse
                    channel = text(part["text"]) ?? channel
                }
            }
        }
        let published = strings(rows).first { $0.hasSuffix(" ago") }
        let thumb = (dig(v, ["contentImage", "thumbnailViewModel", "image", "sources"]) as? [[String: Any]])?.last?["url"] as? String
        let avatar = strings(dig(meta, ["image"])).first { $0.hasPrefix("https://yt3") || $0.hasPrefix("//yt3") }
        return Track(id: id, title: title, artist: channel, album: nil, duration: duration,
                     artworkURL: url(thumb) ?? URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg"),
                     podcast: true, channelID: channelID, channelAvatar: url(avatar),
                     published: relativeDate(published))
    }

    private static func parseChannel(_ r: [String: Any]) -> PodcastChannel? {
        guard let id = r["channelId"] as? String, let name = text(r["title"]) else { return nil }
        let thumb = (dig(r, ["thumbnail", "thumbnails"]) as? [[String: Any]])?.last?["url"] as? String
        let candidates = [text(r["videoCountText"]), text(r["subscriberCountText"])].compactMap { $0 }
        let subtitle = candidates.first { $0.contains("subscriber") } ?? candidates.first
        return PodcastChannel(id: id, name: name, avatarURL: url(thumb), subtitle: subtitle)
    }

    /// "3 days ago", "Streamed 2 weeks ago" → approximate date.
    static func relativeDate(_ s: String?) -> Date? {
        guard let s, let r = s.range(of: "(\\d+)\\s+(second|minute|hour|day|week|month|year)", options: .regularExpression)
        else { return nil }
        let parts = s[r].split(separator: " ")
        guard let n = Double(parts[0]) else { return nil }
        let unit: Double
        switch parts[1].prefix(3) {
        case "sec": unit = 1
        case "min": unit = 60
        case "hou": unit = 3600
        case "day": unit = 86400
        case "wee": unit = 7 * 86400
        case "mon": unit = 30 * 86400
        default: unit = 365 * 86400
        }
        return Date().addingTimeInterval(-n * unit)
    }
}

/// Reads YouTube's channel RSS feed.
private final class FeedParser: NSObject, XMLParserDelegate {
    struct Entry {
        var id = "", title = "", published = "", link = "", author = ""
    }

    var entries: [Entry] = []
    private var current: Entry?
    private var text = ""
    private var inAuthor = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "entry": current = Entry()
        case "author": inAuthor = true
        case "link":
            if current != nil, attributes["rel"] == "alternate" { current?.link = attributes["href"] ?? "" }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "yt:videoId": current?.id = value
        case "title": if current != nil { current?.title = value }
        case "published": if current != nil { current?.published = value }
        case "name": if inAuthor, current != nil { current?.author = value }
        case "author": inAuthor = false
        case "entry":
            if let c = current { entries.append(c) }
            current = nil
        default: break
        }
        text = ""
    }
}
