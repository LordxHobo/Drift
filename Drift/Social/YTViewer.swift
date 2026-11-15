import CryptoKit
import Foundation
import Observation
import WebKit

struct YTAccount: Equatable {
    var name: String
    var handle: String
    var avatar: URL?
    var channelId: String?
}

struct YTChannel: Hashable, Identifiable {
    var id: String
    var name: String
    var avatar: URL?
    var fresh = false
}

struct YTVideo: Hashable, Identifiable {
    var id: String
    var title: String
    var channel: String
    var channelId: String?
    var thumbnail: URL?
    /// Seconds (none for live streams).
    var duration: Double?
    var views: String
    var published: String
    var live: Bool

    /// As something the player can play: an episode that always shows its picture.
    var track: Track {
        Track(id: id, title: title, artist: channel, duration: duration, artworkURL: thumbnail,
              podcast: true, channelID: channelId, upload: true, watch: true)
    }
}

struct YTVideoDetails {
    var id: String
    var title: String
    var views: String
    var published: String
    var description: String
    var channel: YTChannel
    var subscribers: String
    var subscribed: Bool
    var related: [YTVideo]
    /// Where the comments start.
    var commentsToken: String?
}

struct YTComment: Identifiable, Hashable {
    var id: String
    var author: String
    var authorAvatar: URL?
    var authorChannelId: String?
    var text: String
    var published: String
    var likes: String
    var replies: Int
    var pinned: Bool
    var byCreator: Bool
}

struct YTCommentsPage {
    var comments: [YTComment]
    var more: String?
    var newest: String?
    var postParams: String?
}

enum YTFeed: String, Hashable, CaseIterable {
    case subscriptions = "FEsubscriptions", history = "FEhistory", watchLater = "VLWL", liked = "VLLL"
    var title: String {
        switch self {
        case .subscriptions: "Home"
        case .history: "History"
        case .watchLater: "Watch later"
        case .liked: "Liked videos"
        }
    }
}

/// The YouTube viewer: the signed-in account (its YouTube cookies, kept on this iPhone only) and reading its
/// feeds through YouTube's own web API, the same as the computer and Android: new videos from subscriptions,
/// history, Watch later, liked videos, subscribed channels, search, a video's details, comments. Videos play
/// through the normal player (as episodes that show their picture).
@Observable @MainActor
final class YTViewer {
    static let shared = YTViewer()

    private(set) var account: YTAccount?
    private(set) var signedIn = false
    /// Music, or the YouTube viewer.
    private(set) var on = false
    /// The sign-in page is open.
    var signingIn = false

    /// What the sign-in page and requests say they are: Safari (Google refuses sign-in in apps' web views).
    static let signInUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1"
    private static let webVersion = "2.20251105.01.00"
    private static let origin = "https://www.youtube.com"

    @ObservationIgnored private var cookie = ""
    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        cookie = defaults.string(forKey: "yt.cookie") ?? ""
        signedIn = sapisid != nil
        on = signedIn && defaults.bool(forKey: "yt.on")
    }

    func turn(_ value: Bool) {
        if value && !signedIn {
            signingIn = true
            return
        }
        on = value
        defaults.set(on, forKey: "yt.on")
    }

    /// After the sign-in page reached YouTube: keeps its cookies. True when signed in.
    func signedIn(with cookies: [HTTPCookie]) -> Bool {
        let yt = cookies.filter { $0.domain.hasSuffix("youtube.com") }
        guard yt.contains(where: { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }) else { return false }
        cookie = yt.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        defaults.set(cookie, forKey: "yt.cookie")
        signedIn = true
        account = nil
        return true
    }

    func signOut() {
        cookie = ""
        defaults.removeObject(forKey: "yt.cookie")
        defaults.set(false, forKey: "yt.on")
        signedIn = false
        on = false
        account = nil
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                             for: records.filter { $0.displayName.contains("google") || $0.displayName.contains("youtube") }) {}
        }
    }

    private var sapisid: String? {
        for part in cookie.split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces)
            guard let eq = kv.firstIndex(of: "=") else { continue }
            let name = kv[..<eq]
            if name == "SAPISID" || name == "__Secure-3PAPISID" { return String(kv[kv.index(after: eq)...]) }
        }
        return nil
    }

    /// YouTube's signed-in header: a hash of the time, the SAPISID cookie and the site.
    private var auth: String {
        let ts = Int(Date().timeIntervalSince1970)
        let digest = Insecure.SHA1.hash(data: Data("\(ts) \(sapisid ?? "") \(Self.origin)".utf8))
        return "SAPISIDHASH \(ts)_" + digest.map { String(format: "%02x", $0) }.joined()
    }

    enum YTError: LocalizedError {
        case signedOut, failed(Int)
        var errorDescription: String? {
            switch self {
            case .signedOut: "Sign in to YouTube first."
            case .failed(let code): code == 401 || code == 403 ? "YouTube signed you out. Sign in again from the menu." : "YouTube didn't answer (\(code))."
            }
        }
    }

    private func post(_ endpoint: String, _ body: [String: Any] = [:]) async throws -> [String: Any] {
        guard sapisid != nil else { throw YTError.signedOut }
        var payload = body
        payload["context"] = ["client": ["clientName": "WEB", "clientVersion": Self.webVersion, "hl": "en", "gl": "US"]]
        var req = URLRequest(url: URL(string: "\(Self.origin)/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.httpShouldHandleCookies = false
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        for (k, v) in [
            "Content-Type": "application/json", "User-Agent": Self.signInUA, "Cookie": cookie, "Authorization": auth,
            "Origin": Self.origin, "X-Origin": Self.origin, "X-Goog-AuthUser": "0",
            "X-Youtube-Client-Name": "1", "X-Youtube-Client-Version": Self.webVersion,
        ] { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw YTError.failed(code) }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: Account

    func loadAccount() async -> YTAccount? {
        guard signedIn else { return nil }
        if let account { return account }
        var a = YTAccount(name: "YouTube", handle: "", avatar: nil, channelId: nil)
        if let data = try? await post("account/account_menu") {
            let header = YT.find(data, "activeAccountHeaderRenderer")
            a.name = YT.text(YT.get(header, "accountName")).nonEmpty ?? "YouTube"
            a.handle = YT.text(YT.get(header, "channelHandle"))
            a.avatar = YT.lastThumb(YT.get(header, "accountPhoto"))
            if !a.handle.isEmpty { a.channelId = await channel(handle: a.handle) }
        }
        account = a
        return a
    }

    private func channel(handle: String) async -> String? {
        let h = handle.hasPrefix("@") ? handle : "@\(handle)"
        guard let data = try? await post("navigation/resolve_url", ["url": "\(Self.origin)/\(h)"]),
              let id = YT.str(YT.get(YT.find(data, "browseEndpoint"), "browseId")), id.hasPrefix("UC") else { return nil }
        return id
    }

    // MARK: Feeds

    func feed(_ f: YTFeed) async throws -> [YTVideo] {
        YT.videos(try await post("browse", ["browseId": f.rawValue]))
    }

    func channels() async throws -> [YTChannel] {
        let data = try await post("guide")
        var out: [YTChannel] = []
        func walk(_ n: Any?) {
            if let a = n as? [Any] { a.forEach(walk); return }
            guard let o = n as? [String: Any] else { return }
            if let e = o["guideEntryRenderer"] as? [String: Any],
               let id = YT.str(YT.get(YT.get(e["navigationEndpoint"], "browseEndpoint"), "browseId")), id.hasPrefix("UC") {
                if !out.contains(where: { $0.id == id }) {
                    out.append(YTChannel(id: id, name: YT.text(e["formattedTitle"]), avatar: YT.lastThumb(e["thumbnail"]),
                                         fresh: YT.str(e["presentationStyle"]) == "GUIDE_ENTRY_PRESENTATION_STYLE_NEW_CONTENT"))
                }
                return
            }
            o.values.forEach(walk)
        }
        walk(YT.find(data, "guideSubscriptionsSectionRenderer"))
        return out
    }

    func search(_ q: String) async throws -> [YTVideo] {
        YT.videos(try await post("search", ["query": q, "params": "EgIQAQ%3D%3D"]))
    }

    func channel(_ id: String) async throws -> (YTChannel, [YTVideo]) {
        let data = try await post("browse", ["browseId": id, "params": "EgZ2aWRlb3PyBgQKAjoA"])
        let meta = YT.find(data, "channelMetadataRenderer")
        let header = YT.find(data, "pageHeaderViewModel") ?? YT.find(data, "c4TabbedHeaderRenderer")
        let name = YT.str(YT.get(meta, "title")) ?? YT.text(YT.get(header, "title"))
        let list = YT.videos(data).map { v -> YTVideo in
            var v = v
            if v.channel.isEmpty { v.channel = name }
            if v.channelId == nil { v.channelId = id }
            return v
        }
        return (YTChannel(id: id, name: name, avatar: YT.lastThumb(YT.get(meta, "avatar")) ?? YT.lastThumb(YT.find(header, "avatar"))), list)
    }

    func video(_ id: String) async throws -> YTVideoDetails {
        let data = try await post("next", ["videoId": id])
        let primary = YT.find(data, "videoPrimaryInfoRenderer")
        let secondary = YT.find(data, "videoSecondaryInfoRenderer")
        let owner = YT.find(secondary, "videoOwnerRenderer")
        let subscribe = YT.find(secondary, "subscribeButtonRenderer")
        return YTVideoDetails(
            id: id,
            title: YT.text(YT.get(primary, "title")),
            views: YT.text(YT.find(YT.get(primary, "viewCount"), "viewCount")).nonEmpty ?? YT.text(YT.find(primary, "shortViewCount")),
            published: YT.text(YT.get(primary, "relativeDateText")).nonEmpty ?? YT.text(YT.get(primary, "dateText")),
            description: YT.text(YT.get(secondary, "attributedDescription")).nonEmpty ?? YT.text(YT.get(secondary, "description")),
            channel: YTChannel(id: YT.str(YT.get(YT.get(YT.get(owner, "navigationEndpoint"), "browseEndpoint"), "browseId")) ?? "",
                               name: YT.text(YT.get(owner, "title")), avatar: YT.lastThumb(YT.get(owner, "thumbnail"))),
            subscribers: YT.text(YT.get(owner, "subscriberCountText")),
            subscribed: (YT.get(subscribe, "subscribed") as? Bool) == true,
            related: YT.videos(YT.find(data, "secondaryResults")).filter { $0.id != id && !$0.live },
            commentsToken: YT.commentsStart(data)
        )
    }

    // MARK: Doing things

    func subscribe(_ channelId: String, _ on: Bool) async throws {
        if on { _ = try await post("subscription/subscribe", ["channelIds": [channelId], "params": "EgIIAhgA"]) }
        else { _ = try await post("subscription/unsubscribe", ["channelIds": [channelId]]) }
    }

    func like(_ videoId: String) async throws {
        _ = try await post("like/like", ["target": ["videoId": videoId]])
    }

    func watchLater(_ videoId: String) async throws {
        _ = try await post("browse/edit_playlist", ["playlistId": "WL", "actions": [["addedVideoId": videoId, "action": "ACTION_ADD_VIDEO"]]])
    }

    func comments(_ token: String) async throws -> YTCommentsPage {
        YT.comments(try await post("next", ["continuation": token]))
    }

    func postComment(params: String, text: String) async throws {
        _ = try await post("comment/create_comment", ["commentText": text, "createCommentParams": params])
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Reading YouTube's answers: one walker that understands both the older video "renderers" and the newer
/// "lockup" view models (Shorts left out). The same rules as the computer and Android.
enum YT {
    static func get(_ n: Any?, _ key: String) -> Any? { (n as? [String: Any])?[key] }

    static func str(_ n: Any?) -> String? {
        if let s = n as? String { return s }
        if let n = n as? NSNumber { return n.stringValue }
        return nil
    }

    /// The first value under `key` anywhere in `n`.
    static func find(_ n: Any?, _ key: String) -> Any? {
        if let o = n as? [String: Any] {
            if let v = o[key] { return v }
            for v in o.values { if let f = find(v, key) { return f } }
        } else if let a = n as? [Any] {
            for v in a { if let f = find(v, key) { return f } }
        }
        return nil
    }

    static func text(_ t: Any?) -> String {
        if let s = t as? String { return s }
        guard let o = t as? [String: Any] else { return "" }
        if let s = o["simpleText"] as? String { return s }
        if let s = o["content"] as? String { return s }
        if let runs = o["runs"] as? [[String: Any]] { return runs.map { ($0["text"] as? String) ?? "" }.joined() }
        return ""
    }

    static func lastThumb(_ t: Any?) -> URL? {
        let list = (get(t, "thumbnails") ?? get(t, "sources") ?? get(get(t, "image"), "sources")) as? [[String: Any]]
        guard var url = list?.last?["url"] as? String else { return nil }
        if url.hasPrefix("//") { url = "https:" + url }
        return URL(string: url)
    }

    static func seconds(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let parts = t.split(separator: ":")
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return parts.reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }

    static func browseId(_ n: Any?) -> String? { str(get(find(n, "browseEndpoint"), "browseId")) }

    static func video(_ key: String, _ v: [String: Any]) -> YTVideo? {
        if key == "lockupViewModel" {
            if let type = str(v["contentType"]), type != "LOCKUP_CONTENT_TYPE_VIDEO" { return nil }
            guard let id = str(v["contentId"]), let meta = get(get(v, "metadata"), "lockupMetadataViewModel") else { return nil }
            let rows = (get(get(get(meta, "metadata"), "contentMetadataViewModel"), "metadataRows") as? [Any]) ?? []
            let parts = rows.map { r in ((get(r, "metadataParts") as? [Any]) ?? []).map { text(get($0, "text")) }.filter { !$0.isEmpty } }
            var badges: [String] = []
            func badgesIn(_ n: Any?) {
                if let a = n as? [Any] { a.forEach(badgesIn); return }
                guard let o = n as? [String: Any] else { return }
                if let b = o["thumbnailBadgeViewModel"] as? [String: Any] { badges.append(text(b["text"])) }
                o.values.forEach(badgesIn)
            }
            badgesIn(v["contentImage"])
            let len = badges.first { seconds($0) != nil }
            return YTVideo(
                id: id, title: text(get(meta, "title")),
                channel: parts.first?.first ?? "",
                channelId: browseId(get(meta, "image")) ?? browseId(rows.first),
                thumbnail: lastThumb(find(v["contentImage"], "image")) ?? URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"),
                duration: len.flatMap(seconds),
                views: parts.count > 1 ? parts[1].first ?? "" : "",
                published: parts.count > 1 && parts[1].count > 1 ? parts[1][1] : "",
                live: badges.contains { $0.localizedCaseInsensitiveContains("live") }
            )
        }
        guard let id = str(v["videoId"]) else { return nil }
        let owner = v["ownerText"] ?? v["shortBylineText"] ?? v["longBylineText"]
        let lenText = text(v["lengthText"]).nonEmpty ?? text(get(find(v["thumbnailOverlays"], "thumbnailOverlayTimeStatusRenderer"), "text"))
        return YTVideo(
            id: id, title: text(v["title"]).nonEmpty ?? text(v["headline"]),
            channel: text(owner), channelId: browseId(owner),
            thumbnail: lastThumb(v["thumbnail"]) ?? URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"),
            duration: seconds(lenText),
            views: text(v["shortViewCountText"]).nonEmpty ?? text(v["viewCountText"]),
            published: text(v["publishedTimeText"]),
            live: (str(find(v["thumbnailOverlays"], "style")) ?? "").contains("LIVE")
        )
    }

    private static let videoKeys: Set<String> = ["videoRenderer", "gridVideoRenderer", "compactVideoRenderer", "playlistVideoRenderer", "lockupViewModel"]
    private static let shortsKeys: Set<String> = ["reelShelfRenderer", "shortsLockupViewModel", "reelItemRenderer"]

    /// Every video in an answer, in order, once each (Shorts left out).
    static func videos(_ n: Any?) -> [YTVideo] {
        var out: [YTVideo] = []
        var seen = Set<String>()
        func walk(_ x: Any?) {
            if let a = x as? [Any] { a.forEach(walk); return }
            guard let o = x as? [String: Any] else { return }
            // Keys in a stable order, so the videos come out in YouTube's order.
            for k in o.keys.sorted() {
                guard let v = o[k] else { continue }
                if shortsKeys.contains(k) { continue }
                if videoKeys.contains(k), let vo = v as? [String: Any] {
                    if let video = video(k, vo), !video.title.isEmpty, seen.insert(video.id).inserted { out.append(video) }
                    continue
                }
                walk(v)
            }
        }
        walk(n)
        return out
    }

    /// The comments section's first token, in a video's details.
    static func commentsStart(_ data: Any?) -> String? {
        var token: String?
        func walk(_ n: Any?) {
            if token != nil { return }
            if let a = n as? [Any] { a.forEach(walk); return }
            guard let o = n as? [String: Any] else { return }
            if let s = o["itemSectionRenderer"] as? [String: Any], str(s["sectionIdentifier"]) == "comment-item-section" {
                token = str(get(find(s, "continuationCommand"), "token"))
                return
            }
            o.values.forEach(walk)
        }
        walk(data)
        return token
    }

    static func comments(_ data: [String: Any]) -> YTCommentsPage {
        // The comments themselves live in "entity" updates, matched to the threads by key.
        var payloads: [String: [String: Any]] = [:]
        for m in (find(data, "mutations") as? [Any]) ?? [] {
            if let p = get(get(m, "payload"), "commentEntityPayload") as? [String: Any], let key = str(get(m, "entityKey")) {
                payloads[key] = p
            }
        }
        var out: [YTComment] = []
        var more: String?
        var header: Any?
        func walk(_ n: Any?) {
            if let a = n as? [Any] { a.forEach(walk); return }
            guard let o = n as? [String: Any] else { return }
            if let h = o["commentsHeaderRenderer"] { header = h }
            if let thread = o["commentThreadRenderer"] as? [String: Any] {
                let view = get(get(thread, "commentViewModel"), "commentViewModel")
                if let key = str(get(view, "commentKey")), let p = payloads[key] {
                    out.append(comment(p, pinned: get(view, "pinnedText") != nil))
                }
                return
            }
            if let cont = o["continuationItemRenderer"] {
                if let t = str(get(find(cont, "continuationCommand"), "token")) { more = t }
                return
            }
            o.values.forEach(walk)
        }
        walk(find(data, "onResponseReceivedEndpoints"))
        let sorts = find(header, "subMenuItems") as? [Any]
        let newest = (sorts?.count ?? 0) > 1 ? str(get(find(sorts?[1], "continuationCommand"), "token")) : nil
        return YTCommentsPage(comments: out, more: more, newest: newest, postParams: str(find(header, "createCommentParams")))
    }

    private static func comment(_ p: [String: Any], pinned: Bool) -> YTComment {
        let props = get(p, "properties"), author = get(p, "author"), toolbar = get(p, "toolbar")
        return YTComment(
            id: str(get(props, "commentId")) ?? UUID().uuidString,
            author: str(get(author, "displayName")) ?? "",
            authorAvatar: str(get(author, "avatarThumbnailUrl")).flatMap(URL.init(string:)),
            authorChannelId: str(get(author, "channelId")),
            text: str(get(get(props, "content"), "content")) ?? "",
            published: str(get(props, "publishedTime")) ?? "",
            likes: (str(get(toolbar, "likeCountNotliked")) ?? "").trimmingCharacters(in: .whitespaces),
            replies: Int((str(get(toolbar, "replyCount")) ?? "").filter(\.isNumber)) ?? 0,
            pinned: pinned,
            byCreator: (get(author, "isCreator") as? Bool) == true
        )
    }
}
