import Foundation

/// Podcasts from their own feeds (RSS), like Apple Podcasts and Spotify have them: shows found in
/// Apple's podcast directory, or any feed link pasted in. Episodes are plain audio files.
/// The computer does the same (feedParse.ts); both give the same ids.
enum PodcastFeeds {
    private static let userAgent = "Drift/1.0 (podcast app)"

    // MARK: Ids

    /// 64-bit FNV-1a of the text (UTF-8), as 16 hex digits.
    static func fnv64(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// A show's or episode's id: "rss-" and 14 hex digits.
    static func id(_ key: String) -> String { "rss-" + String(fnv64(key).prefix(14)) }

    // MARK: Finding shows

    /// Shows in Apple's podcast directory (this country's, then the US one if that finds nothing).
    static func search(_ term: String) async throws -> [PodcastChannel] {
        let here = Locale.current.region?.identifier ?? "US"
        let found = try await search(term, country: here)
        if found.isEmpty && here != "US" { return try await search(term, country: "US") }
        return found
    }

    private static func search(_ term: String, country: String) async throws -> [PodcastChannel] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "term", value: term),
        ]
        let (data, response) = try await URLSession.shared.data(from: c.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = body["results"] as? [[String: Any]] else { throw URLError(.badServerResponse) }
        var out: [PodcastChannel] = []
        for r in results {
            guard let feed = r["feedUrl"] as? String, !feed.isEmpty, !out.contains(where: { $0.feedURL?.absoluteString == feed }),
                  let feedURL = URL(string: feed) else { continue }
            let count = r["trackCount"] as? Int ?? 0
            let author = r["artistName"] as? String ?? ""
            let sub = [author, count > 0 ? "\(count) episodes" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
            out.append(PodcastChannel(
                id: id(feed),
                name: r["collectionName"] as? String ?? r["trackName"] as? String ?? "Podcast",
                avatarURL: (r["artworkUrl600"] as? String ?? r["artworkUrl100"] as? String).flatMap(URL.init(string:)),
                subtitle: sub.isEmpty ? nil : sub,
                feedURL: feedURL))
        }
        return out
    }

    /// A pasted link that isn't YouTube: maybe a show's feed.
    static func feedLink(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: t), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil, YouTubeSearch.videoID(fromLink: t) == nil,
              !(url.host ?? "").contains("youtu") else { return nil }
        return url
    }

    /// The show behind a feed link, with its episodes.
    static func show(from link: URL) async throws -> (channel: PodcastChannel, episodes: [Track])? {
        let base = PodcastChannel(id: id(link.absoluteString), name: "", avatarURL: nil, subtitle: nil, feedURL: link)
        let parsed = parse(try await fetch(link), base)
        guard !parsed.title.isEmpty || !parsed.episodes.isEmpty else { return nil }
        return (parsed.channel, parsed.episodes)
    }

    /// A followed show's episodes, newest first.
    static func episodes(_ c: PodcastChannel) async throws -> [Track] {
        guard let url = c.feedURL else { return [] }
        return parse(try await fetch(url), c).episodes
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/rss+xml, application/xml, text/xml, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: Reading a feed

    /// Shows can have many hundreds of episodes; the newest this many are kept.
    static let maxEpisodes = 500

    struct Parsed {
        var title: String
        var channel: PodcastChannel
        var episodes: [Track]
    }

    static func parse(_ data: Data, _ c: PodcastChannel) -> Parsed {
        let reader = FeedReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldProcessNamespaces = false
        parser.parse()

        let image = (reader.showImage ?? reader.showImageURL).flatMap(httpsURL)
        let channel = PodcastChannel(
            id: c.id,
            name: c.name.isEmpty ? (reader.showTitle.isEmpty ? "Podcast" : reader.showTitle) : c.name,
            avatarURL: c.avatarURL ?? image,
            subtitle: c.subtitle ?? (reader.showAuthor.isEmpty ? nil : reader.showAuthor),
            feedURL: c.feedURL)

        var seen = Set<String>()
        var episodes: [Track] = []
        for item in reader.items {
            guard let audio = item.audio.flatMap({ URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else { continue }
            let guid = item.guid.isEmpty ? audio.absoluteString : item.guid
            let eid = id("\(c.id)|\(guid)")
            guard seen.insert(eid).inserted else { continue }
            var t = Track(id: eid,
                          title: item.title.isEmpty ? (item.itunesTitle.isEmpty ? "Episode" : item.itunesTitle) : item.title,
                          artist: channel.name, album: nil,
                          duration: parseDuration(item.duration),
                          artworkURL: item.image.flatMap(httpsURL) ?? channel.avatarURL,
                          podcast: true)
            t.channelID = c.id
            t.channelAvatar = channel.avatarURL
            t.published = parseDate(item.pubDate)
            t.audioURL = audio
            t.feedURL = c.feedURL
            episodes.append(t)
        }
        // Newest first (most feeds already are, a few list oldest first).
        episodes.sort { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
        return Parsed(title: reader.showTitle, channel: channel, episodes: Array(episodes.prefix(maxEpisodes)))
    }

    private static func httpsURL(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let fixed = t.lowercased().hasPrefix("http://") ? "https://" + t.dropFirst(7) : t
        return URL(string: fixed)
    }

    /// "1:02:03", "62:03", "3723" or "3723.5" → seconds.
    static func parseDuration(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false).map { Double($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        let secs = parts.reduce(0.0) { $0 * 60 + ($1 ?? 0) }
        return secs > 0 ? secs.rounded() : nil
    }

    private static let dateFormats = [
        "EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ",
    ]

    /// RFC 822 dates ("Tue, 27 Oct 2026 21:00:00 GMT"), and a few looser ones seen in the wild.
    static func parseDate(_ s: String) -> Date? {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard !text.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        for format in dateFormats {
            f.dateFormat = format
            if let d = f.date(from: text) { return d }
        }
        return nil
    }
}

/// Collects what a feed says about the show and each episode.
private final class FeedReader: NSObject, XMLParserDelegate {
    struct Item {
        var title = "", itunesTitle = "", guid = "", pubDate = "", duration = ""
        var audio: String?
        var image: String?
    }

    var showTitle = "", showAuthor = ""
    var showImage: String?      // <itunes:image href>
    var showImageURL: String?   // <image><url>
    var items: [Item] = []

    private var item: Item?
    private var inImage = false
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        switch name.lowercased() {
        case "item":
            item = Item()
        case "image":
            if item == nil { inImage = true }
        case "itunes:image":
            if let href = attributes["href"] ?? attributes["url"] {
                if item != nil { item?.image = item?.image ?? href } else if showImage == nil { showImage = href }
            }
        case "enclosure":
            if item != nil, item?.audio == nil, let url = attributes["url"] { item?.audio = url }
        case "media:content":
            if item != nil, item?.audio == nil, let url = attributes["url"],
               (attributes["type"] ?? "audio/").hasPrefix("audio/") { item?.audio = url }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }
        let key = name.lowercased()
        if key == "item" {
            if let item { items.append(item) }
            item = nil
            return
        }
        if item != nil {
            switch key {
            case "title": if item?.title.isEmpty == true { item?.title = value }
            case "itunes:title": item?.itunesTitle = value
            case "guid": item?.guid = value
            case "pubdate": item?.pubDate = value
            case "itunes:duration": item?.duration = value
            default: break
            }
            return
        }
        switch key {
        case "image": inImage = false
        case "url": if inImage, showImageURL == nil { showImageURL = value }
        case "title": if !inImage, showTitle.isEmpty { showTitle = value }
        case "itunes:author": if showAuthor.isEmpty { showAuthor = value }
        default: break
        }
    }
}
