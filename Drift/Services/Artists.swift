import Foundation

/// An artist as found in search.
struct ArtistRef: Hashable, Codable {
    let id: String          // YouTube Music browse ID ("UC…")
    let name: String
    let thumbnail: URL?
}

/// An album or single on an artist's page.
struct AlbumRef: Hashable, Codable {
    let id: String          // browse ID ("MPREb_…")
    let title: String
    let subtitle: String    // e.g. "Album • 2019"
    let thumbnail: URL?

    var year: String? {
        subtitle.range(of: "\\b(19|20)\\d{2}\\b", options: .regularExpression).map { String(subtitle[$0]) }
    }
}

/// A "See all" link on YouTube Music (browse ID + parameters).
struct BrowseRef: Hashable, Codable {
    let id: String
    let params: String?
}

struct ArtistPage {
    var name: String
    var thumbnail: URL?
    var subtitle: String?
    var topSongs: [Track] = []
    var albums: [AlbumRef] = []
    var singles: [AlbumRef] = []
    var albumsMore: BrowseRef?
    var singlesMore: BrowseRef?
}

struct AlbumPage {
    var title: String
    var subtitle: String
    var artist: String
    var thumbnail: URL?
    var tracks: [Track]
    /// The album is marked explicit.
    var explicit = false
    /// Other editions (clean/explicit, deluxe…), from "Other versions" on YouTube Music.
    var otherVersions: [OtherVersion] = []
    /// Opened the explicit edition instead of this clean one (its browse ID).
    var cleanID: String?
}

struct OtherVersion: Hashable {
    let ref: AlbumRef
    let explicit: Bool
}

/// YouTube Music artist pages, discographies and albums.
enum Artists {
    // MARK: Search

    static func search(_ query: String) async throws -> [ArtistRef] {
        let json = try await YTMusic.post("search", ["query": query, "params": "EgWKAQIgAWoMEA4QChADEAQQCRAF"])
        var out: [ArtistRef] = []
        YTMusic.collect(json) { r in
            guard let browse = dig(r, ["navigationEndpoint", "browseEndpoint"]) as? [String: Any],
                  let id = browse["browseId"] as? String, id.hasPrefix("UC"),
                  let first = (r["flexColumns"] as? [Any])?.first else { return }
            let name = YTMusic.texts(first, renderer: "musicResponsiveListItemFlexColumnRenderer").joined()
            guard !name.isEmpty, !out.contains(where: { $0.id == id }) else { return }
            out.append(ArtistRef(id: id, name: name, thumbnail: thumbnail(r)))
        }
        return out
    }

    /// The artist the search is most likely about (name matches what was typed).
    static func bestMatch(_ artists: [ArtistRef], for query: String) -> ArtistRef? {
        let q = SongMatcher.normalize(query)
        guard !q.isEmpty else { return nil }
        return artists.prefix(3).first { a in
            let n = SongMatcher.normalize(a.name)
            return n == q || (q.count >= 3 && (n.hasPrefix(q) || q.hasPrefix(n)))
        }
    }

    // MARK: Artist page

    static func page(_ artist: ArtistRef) async throws -> ArtistPage {
        let json = try await YTMusic.post("browse", ["browseId": artist.id])
        let header = (dig(json, ["header", "musicImmersiveHeaderRenderer"])
            ?? dig(json, ["header", "musicVisualHeaderRenderer"])) as? [String: Any]

        var page = ArtistPage(name: text(header?["title"]) ?? artist.name,
                              thumbnail: thumbnail(header) ?? artist.thumbnail)
        if let subs = dig(header, ["subscriptionButton", "subscribeButtonRenderer", "subscriberCountText"]),
           let s = text(subs) {
            page.subtitle = "\(s) subscribers"
        }
        if let monthly = text(header?["monthlyListenerCount"]) {
            page.subtitle = monthly.replacingOccurrences(of: " monthly audience", with: " monthly listeners")
        }

        let sections = (dig(json, ["contents", "singleColumnBrowseResultsRenderer", "tabs", 0, "tabRenderer",
                                   "content", "sectionListRenderer", "contents"])
            ?? dig(json, ["contents", "twoColumnBrowseResultsRenderer", "tabs", 0, "tabRenderer",
                          "content", "sectionListRenderer", "contents"])) as? [[String: Any]] ?? []

        for section in sections {
            if let shelf = section["musicShelfRenderer"] as? [String: Any], page.topSongs.isEmpty {
                page.topSongs = ((shelf["contents"] as? [[String: Any]]) ?? []).compactMap { item in
                    guard let r = item["musicResponsiveListItemRenderer"] as? [String: Any],
                          var t = YTMusic.parse(r, requireDuration: false) else { return nil }
                    if t.artist.isEmpty { t.artist = page.name }
                    return t
                }
            }
            guard let carousel = section["musicCarouselShelfRenderer"] as? [String: Any] else { continue }
            let titleNode = dig(carousel, ["header", "musicCarouselShelfBasicHeaderRenderer", "title"])
            let title = (text(titleNode) ?? "").lowercased()
            let items = ((carousel["contents"] as? [[String: Any]]) ?? []).compactMap { item in
                (item["musicTwoRowItemRenderer"] as? [String: Any]).flatMap(albumRef)
            }
            let more = (dig(titleNode, ["runs", 0, "navigationEndpoint", "browseEndpoint"]) as? [String: Any])
                .flatMap { b in (b["browseId"] as? String).map { BrowseRef(id: $0, params: b["params"] as? String) } }
            if title.contains("single") || title.contains(" ep") {
                page.singles = items
                page.singlesMore = more
            } else if title.contains("album") {
                page.albums = items
                page.albumsMore = more
            }
        }
        return page
    }

    /// Every album (or single) of the artist, from the page's "See all" link.
    static func discography(_ ref: BrowseRef) async throws -> [AlbumRef] {
        var fields: [String: Any] = ["browseId": ref.id]
        if let p = ref.params { fields["params"] = p }
        let json = try await YTMusic.post("browse", fields)
        var out: [AlbumRef] = []
        walk(json, key: "musicTwoRowItemRenderer") { r in
            if let a = albumRef(r), !out.contains(where: { $0.id == a.id }) { out.append(a) }
        }
        return out
    }

    // MARK: Album page

    static func album(_ ref: AlbumRef, artistName: String) async throws -> AlbumPage {
        let json = try await YTMusic.post("browse", ["browseId": ref.id])
        var header: [String: Any]?
        walk(json, key: "musicResponsiveHeaderRenderer") { if header == nil { header = $0 } }
        if header == nil { walk(json, key: "musicDetailHeaderRenderer") { if header == nil { header = $0 } } }

        let title = text(header?["title"]) ?? ref.title
        let subtitle = text(header?["subtitle"]) ?? ref.subtitle
        let artist = text(header?["straplineTextOne"]) ?? artistName
        let art = thumbnail(header) ?? ref.thumbnail

        var tracks: [Track] = []
        var seen = Set<String>()
        YTMusic.collect(json) { r in
            guard var t = YTMusic.parse(r, requireDuration: false), seen.insert(t.id).inserted else { return }
            if t.artist.isEmpty { t.artist = artist }
            t.album = title
            if t.artworkURL == nil { t.artworkURL = art }
            tracks.append(t)
        }
        var page = AlbumPage(title: title, subtitle: subtitle, artist: artist, thumbnail: art, tracks: tracks)
        page.explicit = (header.map { YTMusic.isExplicit($0) } ?? false) || tracks.contains { $0.explicit == true }
        walk(json, key: "musicTwoRowItemRenderer") { r in
            guard let other = albumRef(r), other.id != ref.id,
                  !page.otherVersions.contains(where: { $0.ref.id == other.id }) else { return }
            page.otherVersions.append(OtherVersion(ref: other, explicit: YTMusic.isExplicit(r)))
        }
        return page
    }

    /// The explicit edition of a clean album, when YouTube Music lists one under "Other versions".
    static func explicitEdition(of page: AlbumPage) async -> (ref: AlbumRef, page: AlbumPage)? {
        guard !page.explicit else { return nil }
        let want = SongMatcher.normalize(page.title)
        func rank(_ o: OtherVersion) -> Int {
            o.ref.title.lowercased() == page.title.lowercased() ? 2 : SongMatcher.normalize(o.ref.title) == want ? 1 : 0
        }
        let candidates = page.otherVersions.filter(\.explicit).sorted { rank($0) > rank($1) }
        for c in candidates.prefix(3) {
            guard let other = try? await AlbumCache.shared.page(c.ref) else { continue }
            if other.explicit || other.tracks.contains(where: { $0.explicit == true }) { return (c.ref, other) }
        }
        return nil
    }

    // MARK: Parsing helpers

    private static func albumRef(_ r: [String: Any]) -> AlbumRef? {
        guard let id = dig(r, ["navigationEndpoint", "browseEndpoint", "browseId"]) as? String,
              id.hasPrefix("MPRE"), let title = text(r["title"]) else { return nil }
        let thumbs = dig(r, ["thumbnailRenderer", "musicThumbnailRenderer", "thumbnail", "thumbnails"]) as? [[String: Any]]
        let thumb = (thumbs?.last?["url"] as? String).flatMap(URL.init(string:))
        return AlbumRef(id: id, title: title, subtitle: text(r["subtitle"]) ?? "", thumbnail: thumb)
    }

    private static func thumbnail(_ node: Any?) -> URL? {
        let paths: [[Any]] = [
            ["thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails"],
            ["thumbnail", "croppedSquareThumbnailRenderer", "thumbnail", "thumbnails"],
        ]
        for p in paths {
            if let list = dig(node, p) as? [[String: Any]], let s = list.last?["url"] as? String {
                return URL(string: s.hasPrefix("//") ? "https:" + s : s)
            }
        }
        return nil
    }

    private static func walk(_ node: Any, key: String, _ found: ([String: Any]) -> Void) {
        if let d = node as? [String: Any] {
            for k in d.keys.sorted() {
                if k == key, let r = d[k] as? [String: Any] { found(r) } else { walk(d[k]!, key: key, found) }
            }
        } else if let a = node as? [Any] {
            for v in a { walk(v, key: key, found) }
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
        if let runs = d["runs"] as? [[String: Any]] {
            let s = runs.compactMap { $0["text"] as? String }.joined()
            return s.isEmpty ? nil : s
        }
        return nil
    }
}

/// Bigger or smaller version of a YouTube Music image (they carry their size in the URL).
func resizedImage(_ url: URL?, size: Int) -> URL? {
    guard let url else { return nil }
    let s = url.absoluteString
    guard s.contains("googleusercontent.com") || s.contains("ggpht.com") else { return url }
    let resized = s.replacingOccurrences(of: "=w\\d+-h\\d+", with: "=w\(size)-h\(size)", options: .regularExpression)
    return URL(string: resized) ?? url
}

/// Album pages seen lately (a clean album's songs all look at the same pages).
actor AlbumCache {
    static let shared = AlbumCache()
    private var pages: [String: AlbumPage] = [:]
    private var order: [String] = []

    func page(_ ref: AlbumRef) async throws -> AlbumPage {
        if let known = pages[ref.id] { return known }
        let page = try await Artists.album(ref, artistName: "")
        pages[ref.id] = page
        order.append(ref.id)
        if order.count > 60 { pages[order.removeFirst()] = nil }
        return page
    }

    func page(id: String) async throws -> AlbumPage {
        try await page(AlbumRef(id: id, title: "", subtitle: "", thumbnail: nil))
    }
}
