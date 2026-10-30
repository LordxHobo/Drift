import Foundation
import UIKit

/// A playlist someone shows on their profile, as others see it.
struct SharedPlaylist: Hashable, Identifiable {
    let id: String
    let ownerID: String
    let ownerName: String
    var name: String
    var position: Int
    var count: Int
    var duration: Int
    var style: Playlist.CoverStyle
    var colorIndex: Int
    var symbol: String
    var cover: Data?
    /// First songs, for the cover mosaic.
    var preview: [Track]

    init?(document d: [String: Any], ownerName: String) {
        guard let path = d["name"] as? String, let f = d["fields"] as? [String: Any],
              let name = FV.string(f, "name") else { return nil }
        // …/users/{uid}/playlists/{id}
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 4 else { return nil }
        id = parts[parts.count - 1]
        ownerID = parts[parts.count - 3]
        self.ownerName = ownerName
        self.name = name
        position = FV.int(f, "position") ?? 0
        count = FV.int(f, "count") ?? 0
        duration = FV.int(f, "duration") ?? 0
        style = FV.string(f, "style").flatMap(Playlist.CoverStyle.init(rawValue:)) ?? .auto
        colorIndex = FV.int(f, "colorIndex") ?? 0
        symbol = FV.string(f, "symbol") ?? "music.note.list"
        cover = FV.data(f, "cover")
        preview = FV.string(f, "preview").flatMap(SharedTracks.decode) ?? []
    }

    var subtitle: String {
        var parts = ["\(count) \(count == 1 ? "song" : "songs")"]
        if duration > 0 { parts.append(formatLength(Double(duration))) }
        return parts.joined(separator: " · ")
    }

    private static let summaryFields = ["name", "position", "count", "duration", "style", "colorIndex",
                                        "symbol", "cover", "preview"]

    /// Someone's public playlists, in the order they have them.
    static func list(of user: UserProfile) async throws -> [SharedPlaylist] {
        let docs = try await Firestore.list("users/\(user.id)/playlists", fields: summaryFields)
        return docs.compactMap { SharedPlaylist(document: $0, ownerName: user.name) }
            .sorted { $0.position < $1.position }
    }

    /// All the songs of the playlist.
    func tracks() async throws -> [Track] {
        guard let doc = try await Firestore.get("users/\(ownerID)/playlists/\(id)"),
              let json = FV.string(doc["fields"] as? [String: Any], "tracks") else { return [] }
        return SharedTracks.decode(json) ?? []
    }
}

/// Songs stored compactly as one JSON text (keeps big playlists well under Firestore's limits).
enum SharedTracks {
    private struct T: Codable {
        var i: String           // video ID
        var t: String           // title
        var a: String           // artist
        var d: Int?             // seconds
        var w: String?          // artwork
        var p: Bool?            // podcast episode
    }

    static func encode(_ tracks: [Track], artwork: Bool = true) -> String {
        let list = tracks.map { tr in
            T(i: tr.id, t: tr.title, a: tr.artist, d: tr.duration.map { Int($0) },
              w: artwork ? tr.artworkURL?.absoluteString : nil, p: tr.isEpisode ? true : nil)
        }
        guard let data = try? JSONEncoder().encode(list) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ s: String) -> [Track]? {
        guard let list = try? JSONDecoder().decode([T].self, from: Data(s.utf8)) else { return nil }
        return list.map { x in
            Track(id: x.i, title: x.t, artist: x.a, album: nil, duration: x.d.map(Double.init),
                  artworkURL: x.w.flatMap(URL.init(string:)), podcast: x.p)
        }
    }
}

/// Keeps the playlists you show on your profile up to date on Drift's server.
@MainActor
final class PlaylistSharing {
    static let shared = PlaylistSharing()

    private var scheduled: Task<Void, Never>?
    private var running = false
    private var again = false
    /// Checked once per launch against what's on the server.
    private var reconciled = false

    private init() {}

    /// Called whenever the library is saved; uploads what changed a few seconds later.
    func libraryChanged() { schedule(after: 3) }

    /// Profile loaded or just created.
    func profileReady() {
        reconciled = false
        schedule(after: 1)
    }

    /// Profile deleted: remove its playlists from the server.
    func removeAll(uid: String) async {
        let docs = (try? await Firestore.list("users/\(uid)/playlists", fields: ["position"])) ?? []
        for id in docs.compactMap(Self.docID) {
            try? await Firestore.delete("users/\(uid)/playlists/\(id)")
        }
        UserDefaults.standard.removeObject(forKey: key(uid))
    }

    private func schedule(after seconds: Double) {
        if running { again = true; return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            await self.run()
        }
    }

    private func run() async {
        running = true
        repeat {
            again = false
            await sync()
        } while again
        running = false
    }

    private func key(_ uid: String) -> String { "social.sharedPlaylists.\(uid)" }

    private static func docID(_ doc: [String: Any]) -> String? {
        (doc["name"] as? String)?.split(separator: "/").last.map(String.init)
    }

    private func sync() async {
        guard let uid = SocialStore.shared.me?.id else { return }
        let shown = Library.shared.playlists.filter(\.isShared)
        let wanted = Set(shown.map { $0.id.uuidString })
        // Playlist ID → fingerprint of what was last uploaded.
        var done = (UserDefaults.standard.dictionary(forKey: key(uid)) as? [String: String]) ?? [:]
        let defaultsKey = key(uid)

        if !reconciled {
            guard let docs = try? await Firestore.list("users/\(uid)/playlists", fields: ["position"]) else { return }
            let remote = Set(docs.compactMap(Self.docID))
            for id in remote.subtracting(wanted) {
                try? await Firestore.delete("users/\(uid)/playlists/\(id)")
            }
            // Anything missing on the server is uploaded again.
            for id in Array(done.keys) where !remote.contains(id) { done[id] = nil }
            UserDefaults.standard.set(done, forKey: defaultsKey)
            reconciled = true
        }

        for (position, p) in shown.enumerated() {
            let id = p.id.uuidString
            let sig = Self.fingerprint(p, position)
            guard done[id] != sig else { continue }
            do {
                try await Firestore.patch("users/\(uid)/playlists/\(id)", fields: Self.fields(p, position))
                done[id] = sig
                UserDefaults.standard.set(done, forKey: defaultsKey)
            } catch {
                if Task.isCancelled { return }
            }
        }

        // Made private or deleted since.
        for id in Array(done.keys) where !wanted.contains(id) {
            do {
                try await Firestore.delete("users/\(uid)/playlists/\(id)")
                done[id] = nil
                UserDefaults.standard.set(done, forKey: defaultsKey)
            } catch {}
        }
    }

    private static func fingerprint(_ p: Playlist, _ position: Int) -> String {
        let s = "\(position)|\(p.name)|\(p.style.rawValue)|\(p.colorIndex)|\(p.symbol)|\(p.coverFile ?? "")|"
            + p.tracks.map(\.id).joined(separator: ",")
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100_0000_01b3
        }
        return String(h, radix: 16)
    }

    private static func fields(_ p: Playlist, _ position: Int) -> [String: Any] {
        let limit = 850_000
        var list = p.tracks
        var json = SharedTracks.encode(list)
        if json.utf8.count > limit { json = SharedTracks.encode(list, artwork: false) }
        while json.utf8.count > limit && list.count > 100 {
            list = Array(list.prefix(list.count * 3 / 4))
            json = SharedTracks.encode(list, artwork: false)
        }
        let total = Int(p.tracks.compactMap(\.duration).reduce(0, +))
        var f: [String: Any] = [
            "name": FV.s(p.name),
            "position": FV.i(position),
            "count": FV.i(list.count),
            "duration": FV.i(total),
            "style": FV.s(p.style.rawValue),
            "colorIndex": FV.i(p.colorIndex),
            "symbol": FV.s(p.symbol),
            "preview": FV.s(SharedTracks.encode(Array(p.tracks.prefix(4)))),
            "tracks": FV.s(json),
            "updatedAt": FV.i(Int(Date().timeIntervalSince1970)),
        ]
        if p.style == .photo, let image = Library.shared.coverImage(p), let data = jpeg(image, side: 300) {
            f["cover"] = FV.bytes(data)
        } else {
            f["cover"] = FV.null
        }
        return f
    }

    private static func jpeg(_ image: UIImage, side target: CGFloat) -> Data? {
        let side = min(image.size.width, image.size.height)
        guard side > 0 else { return nil }
        let scale = target / side
        let draw = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let out = UIGraphicsImageRenderer(size: CGSize(width: target, height: target), format: format).image { _ in
            image.draw(in: CGRect(x: (target - draw.width) / 2, y: (target - draw.height) / 2,
                                  width: draw.width, height: draw.height))
        }
        return out.jpegData(compressionQuality: 0.75)
    }
}
