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

    static func post(_ path: String, _ body: [String: Any]) async throws -> Any {
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
                // A podcast (YouTube's podcast playlists) in the results: a show of its own.
                if let c = podcastFromLockup(value), !channels.contains(where: { $0.id == c.id }) { channels.append(c) }
            default: break
            }
        }
        return (channels, episodes)
    }

    /// A YouTube link (watch, youtu.be, shorts, live, embed, music.youtube) → video ID.
    /// Videos only, a page at a time (about 20): the first page for a query, then the next ones
    /// with the `more` link from the page before. `more` is nil when YouTube has nothing else.
    static func videos(_ query: String, more: String? = nil) async throws -> (videos: [Track], more: String?) {
        let body: [String: Any] = more != nil ? ["continuation": more!] : ["query": query]
        let json = try await post("search", body)
        var out: [Track] = []
        var seen = Set<String>()
        var next: String?
        walk(json) { key, value in
            switch key {
            case "videoRenderer":
                if let t = parseVideo(value), seen.insert(t.id).inserted { out.append(t) }
            case "lockupViewModel":
                if let t = parseLockup(value), seen.insert(t.id).inserted { out.append(t) }
            case "continuationItemRenderer":
                if let token = dig(value, ["continuationEndpoint", "continuationCommand", "token"]) as? String { next = token }
            default: break
            }
        }
        return (out, next)
    }

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

    /// A channel's episodes: its Videos tab (a few pages, so whole back catalogues show up), with exact
    /// dates from its RSS feed. The feed alone has only the latest 15 uploads, shorts and clips included,
    /// which for channels that post a lot of clips can leave just a handful of episodes.
    static func channelEpisodes(_ channel: PodcastChannel) async throws -> [Track] {
        // One podcast followed on its own.
        if isPlaylistShow(channel.id) { return try await playlistEpisodes(channel) }
        // A channel with a Podcasts tab: just its podcasts' episodes, not every video it posts.
        if let podcasts = try? await channelPodcasts(channel), !podcasts.isEmpty {
            var all: [Track] = []
            var seen = Set<String>()
            for p in podcasts.prefix(4) {
                var show = p
                if let a = channel.avatarURL { show.avatarURL = a }
                let eps = (try? await playlistEpisodes(show, artist: channel.name, channelID: channel.id)) ?? []
                for t in eps where seen.insert(t.id).inserted { all.append(t) }
            }
            if !all.isEmpty { return newestFirst(all) }
        }
        async let feed = try? rssEpisodes(channel)
        var out: [Track] = []
        var seen = Set<String>()
        var token: String?
        do {
            for page in 0..<4 {
                let body: [String: Any] = page == 0
                    ? ["browseId": channel.id, "params": "EgZ2aWRlb3PyBgQKAjoA"]
                    : ["continuation": token ?? ""]
                let json = try await post("browse", body)
                token = nil
                var added = 0
                walk(json) { key, value in
                    if key == "continuationItemRenderer" {
                        if let next = dig(value, ["continuationEndpoint", "continuationCommand", "token"]) as? String { token = next }
                        return
                    }
                    var t: Track?
                    if key == "videoRenderer" { t = parseVideo(value) }
                    if key == "lockupViewModel" { t = parseLockup(value) }
                    guard var t, seen.insert(t.id).inserted else { return }
                    t.channelID = channel.id
                    if t.artist.isEmpty || t.artist == "YouTube" { t.artist = channel.name }
                    if t.channelAvatar == nil { t.channelAvatar = channel.avatarURL }
                    out.append(t)
                    added += 1
                }
                if token == nil || added == 0 || out.count >= 120 { break }
            }
        } catch {
            if out.isEmpty, let rss = await feed, !rss.isEmpty { return rss }
            if out.isEmpty { throw error }
        }
        let rss = await feed ?? []
        if out.isEmpty { return rss }
        // The feed's exact dates (the Videos tab only says "2 weeks ago"), and anything newer than the tab shows.
        var dates: [String: Date] = [:]
        for t in rss { if let d = t.published { dates[t.id] = d } }
        for i in out.indices { if let d = dates[out[i].id] { out[i].published = d } }
        let newest = out.compactMap(\.published).max() ?? .distantPast
        let fresh = rss.filter { !seen.contains($0.id) && ($0.published ?? .distantPast) > newest }
        return fresh + out
    }

    // MARK: YouTube podcasts (playlists marked as podcasts, on a channel's Podcasts tab)

    /// A show's id is its playlist's ("PL…") when it's one podcast, or the channel's ("UC…").
    static func isPlaylistShow(_ id: String) -> Bool { id.hasPrefix("PL") || id.hasPrefix("VL") }

    /// Every value under these keys, in the order they appear.
    private static func findAll(_ node: Any, _ keys: Set<String>, _ found: (String, [String: Any]) -> Void) {
        if let d = node as? [String: Any] {
            for (k, v) in d {
                if keys.contains(k), let r = v as? [String: Any] { found(k, r) } else { findAll(v, keys, found) }
            }
        } else if let a = node as? [Any] {
            for v in a { findAll(v, keys, found) }
        }
    }

    private static func image(in node: Any?) -> URL? {
        let s = strings(node).first { s in
            (s.hasPrefix("https://") || s.hasPrefix("//")) && (s.contains("ytimg.com") || s.contains("yt3."))
        }
        return url(s)
    }

    private static func podcastFromLockup(_ v: [String: Any], anyPlaylist: Bool = false) -> PodcastChannel? {
        guard let id = v["contentId"] as? String, id.hasPrefix("PL"),
              anyPlaylist || ((v["contentType"] as? String) ?? "").contains("PODCAST") else { return nil }
        let meta = dig(v, ["metadata", "lockupMetadataViewModel"]) as? [String: Any]
        guard let name = text(meta?["title"]) else { return nil }
        let rows = strings(dig(meta, ["metadata", "contentMetadataViewModel", "metadataRows"]))
        let by = rows.first { t in
            !t.trimmingCharacters(in: .whitespaces).isEmpty && t.range(of: "\\d+ (episode|video)", options: .regularExpression) == nil
        }
        return PodcastChannel(id: id, name: name, avatarURL: image(in: v["contentImage"]),
                              subtitle: by.map { "Podcast · \($0)" } ?? "Podcast")
    }

    /// The podcasts on a channel's Podcasts tab (none when it has no such tab).
    static func channelPodcasts(_ channel: PodcastChannel) async throws -> [PodcastChannel] {
        guard channel.id.hasPrefix("UC") else { return [] }
        let home = try await post("browse", ["browseId": channel.id])
        var params: String?
        findAll(home, ["tabRenderer"]) { _, tab in
            if let u = dig(tab, ["endpoint", "commandMetadata", "webCommandMetadata", "url"]) as? String, u.hasSuffix("/podcasts") {
                params = dig(tab, ["endpoint", "browseEndpoint", "params"]) as? String
            }
        }
        guard let params else { return [] }
        let json = try await post("browse", ["browseId": channel.id, "params": params])
        var out: [PodcastChannel] = []
        findAll(json, ["lockupViewModel", "gridPlaylistRenderer", "playlistRenderer"]) { key, v in
            var show: PodcastChannel?
            if key == "lockupViewModel" {
                // On the Podcasts tab every playlist is a podcast, whatever kind YouTube calls it.
                show = podcastFromLockup(v, anyPlaylist: true)
            } else if let id = v["playlistId"] as? String, id.hasPrefix("PL"), let name = text(v["title"]) {
                show = PodcastChannel(id: id, name: name, avatarURL: image(in: v["thumbnail"] ?? v["thumbnails"]))
            }
            guard var show, !out.contains(where: { $0.id == show.id }) else { return }
            show.subtitle = "Podcast · \(channel.name)"
            if show.avatarURL == nil { show.avatarURL = channel.avatarURL }
            out.append(show)
        }
        return out
    }

    private static func episode(fromPlaylistVideo r: [String: Any]) -> Track? {
        guard let id = r["videoId"] as? String, let title = text(r["title"]) else { return nil }
        let duration = (r["lengthSeconds"] as? String).flatMap { Double($0) }
            ?? text(r["lengthText"]).flatMap { YTMusic.parseDuration($0) }
        if let duration, duration < 60 { return nil }
        let ago = strings(r["videoInfo"]).first { $0.hasSuffix(" ago") }
        return Track(id: id, title: title, artist: "", album: nil, duration: duration,
                     artworkURL: URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg"), podcast: true,
                     published: relativeDate(ago))
    }

    /// Newest first: by date where there is one; undated ones keep their place in the list.
    private static func newestFirst(_ list: [Track]) -> [Track] {
        guard list.contains(where: { $0.published != nil }) else { return list }
        var last: Date?
        let dated = list.enumerated().map { (i, t) -> (Int, Track, Date) in
            if let p = t.published { last = p }
            return (i, t, t.published ?? last ?? .distantPast)
        }
        return dated.sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }.map { $0.1 }
    }

    /// A YouTube podcast's episodes (its playlist), newest first.
    static func playlistEpisodes(_ show: PodcastChannel, artist: String? = nil, channelID: String? = nil) async throws -> [Track] {
        let list = show.id.hasPrefix("VL") ? String(show.id.dropFirst(2)) : show.id
        async let feed = try? rssEpisodes(show, which: "playlist_id=\(list)")
        var out: [Track] = []
        var seen = Set<String>()
        var token: String?
        for page in 0..<6 {
            let body: [String: Any] = page == 0 ? ["browseId": "VL" + list] : ["continuation": token ?? ""]
            let json = try await post("browse", body)
            token = nil
            var added = 0
            walk(json) { key, value in
                if key == "continuationItemRenderer",
                   let next = dig(value, ["continuationEndpoint", "continuationCommand", "token"]) as? String { token = next }
            }
            findAll(json, ["playlistVideoRenderer", "lockupViewModel", "videoRenderer"]) { key, v in
                let found: Track?
                switch key {
                case "playlistVideoRenderer": found = episode(fromPlaylistVideo: v)
                case "videoRenderer": found = parseVideo(v)
                default: found = parseLockup(v)
                }
                guard var t = found, seen.insert(t.id).inserted else { return }
                t.artist = artist ?? show.name
                t.channelID = channelID ?? show.id
                t.channelAvatar = show.avatarURL
                out.append(t)
                added += 1
            }
            if token == nil || added == 0 || out.count >= 400 { break }
        }
        var dates: [String: Date] = [:]
        for t in await feed ?? [] { if let d = t.published { dates[t.id] = d } }
        for i in out.indices { if let d = dates[out[i].id] { out[i].published = d } }
        return newestFirst(out)
    }

    private static func rssEpisodes(_ channel: PodcastChannel, which: String? = nil) async throws -> [Track] {
        let url = URL(string: "https://www.youtube.com/feeds/videos.xml?\(which ?? "channel_id=\(channel.id)")")!
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
                if ["videoRenderer", "channelRenderer", "lockupViewModel", "continuationItemRenderer"].contains(key),
                   let r = v as? [String: Any] {
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

// MARK: Chapters

struct Chapter: Hashable {
    let start: Double
    let title: String
}

extension YouTubeSearch {
    /// Chapters of a video: YouTube's own chapter data, or timestamps in the description.
    static func chapters(for videoID: String, duration: Double) async -> [Chapter] {
        if let json = try? await post("next", ["videoId": videoID]) {
            let fromPlayerBar = (dig(json, ["playerOverlays", "playerOverlayRenderer", "decoratedPlayerBarRenderer",
                                            "decoratedPlayerBarRenderer", "playerBar", "chapteredPlayerBarRenderer",
                                            "chapters"]) as? [[String: Any]] ?? [])
                .compactMap { c -> Chapter? in
                    guard let r = c["chapterRenderer"] as? [String: Any],
                          let ms = (r["timeRangeStartMillis"] as? NSNumber)?.doubleValue,
                          let title = text(r["title"]) else { return nil }
                    return Chapter(start: ms / 1000, title: title)
                }
            if let valid = clean(fromPlayerBar, duration: duration) { return valid }

            // Chapter list in the side panel ("In this video").
            var fromPanel: [Chapter] = []
            collect(json, key: "macroMarkersListItemRenderer") { r in
                guard let title = text(r["title"]), let time = text(r["timeDescription"]),
                      let start = YTMusic.parseDuration(time) ?? (time.hasPrefix("0:") ? 0 : nil) else { return }
                fromPanel.append(Chapter(start: start, title: title))
            }
            if let valid = clean(fromPanel, duration: duration) { return valid }
        }

        // Timestamps in the description ("12:34 Topic" or "Topic - 12:34").
        if let player = try? await post("player", ["videoId": videoID]),
           let description = dig(player, ["videoDetails", "shortDescription"]) as? String {
            return clean(parseDescription(description), duration: duration) ?? []
        }
        return []
    }

    private static func collect(_ node: Any, key: String, _ found: ([String: Any]) -> Void) {
        if let d = node as? [String: Any] {
            for k in d.keys.sorted() {
                if k == key, let r = d[k] as? [String: Any] { found(r) } else { collect(d[k]!, key: key, found) }
            }
        } else if let a = node as? [Any] {
            for v in a { collect(v, key: key, found) }
        }
    }

    static func parseDescription(_ text: String) -> [Chapter] {
        let time = "((?:\\d{1,2}:)?\\d{1,2}:\\d{2})"
        let leading = try! NSRegularExpression(pattern: "^\\W*\\(?\(time)\\)?\\W*\\s+(.+?)\\s*$")
        let trailing = try! NSRegularExpression(pattern: "^\\s*(.+?)\\W*\\s+\\(?\(time)\\)?\\s*$")
        var a: [Chapter] = [], b: [Chapter] = []
        for line in text.components(separatedBy: .newlines) {
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let m = leading.firstMatch(in: line, range: range),
               let start = parseTimestamp(ns.substring(with: m.range(at: 1))) {
                a.append(Chapter(start: start, title: ns.substring(with: m.range(at: 2))))
            } else if let m = trailing.firstMatch(in: line, range: range),
                      let start = parseTimestamp(ns.substring(with: m.range(at: 2))) {
                b.append(Chapter(start: start, title: ns.substring(with: m.range(at: 1))))
            }
        }
        return a.count >= b.count ? a : b
    }

    private static func parseTimestamp(_ s: String) -> Double? {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard parts.count >= 2 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// At least 2 chapters, starting near 0:00, in order, within the episode.
    private static func clean(_ list: [Chapter], duration: Double) -> [Chapter]? {
        var out: [Chapter] = []
        for c in list {
            let title = c.title.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—|:•")))
            guard !title.isEmpty else { continue }
            if let last = out.last, c.start <= last.start { continue }
            if duration > 0, c.start >= duration { continue }
            out.append(Chapter(start: c.start, title: title))
        }
        guard out.count >= 2, let first = out.first, first.start <= 10 else { return nil }
        if first.start > 0 { out[0] = Chapter(start: 0, title: first.title) }
        return out
    }
}
