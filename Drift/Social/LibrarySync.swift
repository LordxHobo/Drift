import Foundation
import UIKit

/// Keeps your library (playlists, albums, liked songs, followed artists) the same on all your devices,
/// through your Drift profile. Only you can read it (see the Firestore rules).
///
/// Each item is one document in users/{uid}/library: "liked", "artists" and "pl-<playlist id>".
/// Changes are spotted by comparing a fingerprint of each item with the last one synced; the newest
/// change wins. Deleted playlists leave a small "deleted" marker so other devices remove them too.
@MainActor
final class LibrarySync {
    static let shared = LibrarySync()

    /// What was last sent or received for each document.
    private struct Synced: Codable {
        var fingerprint: String
        var updatedAt: Int
    }

    private var synced: [String: Synced] = [:]
    private var syncedUID: String?
    private var scheduled: Task<Void, Never>?
    private var running = false
    private var again = false
    private var pulledThisLaunch = false
    private var lastPull = Date.distantPast

    private init() {}

    private func key(_ uid: String) -> String { "librarySync.\(uid)" }

    private func loadState(for uid: String) {
        guard syncedUID != uid else { return }
        syncedUID = uid
        if let data = UserDefaults.standard.data(forKey: key(uid)),
           let s = try? JSONDecoder().decode([String: Synced].self, from: data) {
            synced = s
        } else {
            synced = [:]
        }
    }

    private func saveState() {
        guard let uid = syncedUID, let data = try? JSONEncoder().encode(synced) else { return }
        UserDefaults.standard.set(data, forKey: key(uid))
    }

    // MARK: Triggers

    /// Something in the library changed on this phone: send it a few seconds later.
    func localChanged() { schedule(after: 3, pull: false) }

    /// Profile loaded, or Drift came back to the foreground: fetch changes from other devices first.
    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastPull) > 60 else { return }
        schedule(after: 0.5, pull: true)
    }

    private var wantsPull = false

    private func schedule(after seconds: Double, pull: Bool) {
        if pull { wantsPull = true }
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

    // MARK: Sync

    private func sync() async {
        guard let uid = SocialStore.shared.me?.id else { return }
        loadState(for: uid)
        // Always look at the server once per launch before sending anything (so a fresh install
        // gets your library instead of overwriting it).
        if wantsPull || !pulledThisLaunch {
            guard await pull(uid) else { return }
            wantsPull = false
            pulledThisLaunch = true
            lastPull = Date()
        }
        await push(uid)
    }

    private static let summaryFields = ["updatedAt", "deleted"]

    /// Fetches what changed on other devices. Returns false when the server couldn't be reached.
    private func pull(_ uid: String) async -> Bool {
        guard let docs = try? await Firestore.list("users/\(uid)/library", fields: Self.summaryFields) else {
            return false
        }
        var firstSync = synced.isEmpty
        for doc in docs {
            guard let name = (doc["name"] as? String)?.split(separator: "/").last.map(String.init) else { continue }
            let f = doc["fields"] as? [String: Any]
            let updatedAt = FV.int(f, "updatedAt") ?? 0
            if let known = synced[name], known.updatedAt >= updatedAt { continue }
            if FV.bool(f, "deleted") == true {
                applyDeletion(name)
                synced[name] = Synced(fingerprint: "deleted", updatedAt: updatedAt)
                continue
            }
            guard let full = try? await Firestore.get("users/\(uid)/library/\(name)"),
                  let fields = full["fields"] as? [String: Any] else { continue }
            apply(name, fields, firstSync: firstSync)
            synced[name] = Synced(fingerprint: currentFingerprint(name) ?? "", updatedAt: updatedAt)
            firstSync = false
        }
        saveState()
        return true
    }

    /// Sends everything that changed here since the last sync.
    private func push(_ uid: String) async {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        var items: [(String, String)] = []   // (document, fingerprint)
        if let fp = currentFingerprint("liked") { items.append(("liked", fp)) }
        if let fp = currentFingerprint("artists") { items.append(("artists", fp)) }
        let playlists = Library.shared.playlists
        // Collaborative playlists sync through their shared document instead (CollabSync).
        for p in playlists where p.collab == nil { items.append(("pl-\(p.id.uuidString)", Self.fingerprint(p, playlists))) }

        for (name, fp) in items where synced[name]?.fingerprint != fp {
            guard let fields = documentFields(name, updatedAt: now) else { continue }
            do {
                try await Firestore.patch("users/\(uid)/library/\(name)", fields: fields)
                synced[name] = Synced(fingerprint: fp, updatedAt: now)
                saveState()
            } catch {
                return
            }
        }

        // Playlists deleted here: leave a marker so other devices delete them too.
        let present = Set(playlists.map { "pl-\($0.id.uuidString)" })
        for (name, state) in synced where name.hasPrefix("pl-") && !present.contains(name) && state.fingerprint != "deleted" {
            do {
                try await Firestore.patch("users/\(uid)/library/\(name)",
                                          fields: ["deleted": FV.b(true), "updatedAt": FV.i(now)])
                synced[name] = Synced(fingerprint: "deleted", updatedAt: now)
                saveState()
            } catch {
                return
            }
        }
    }

    // MARK: Documents

    private func currentFingerprint(_ name: String) -> String? {
        switch name {
        case "liked":
            return Self.hash(Library.shared.liked.map(\.id).joined(separator: ","))
        case "artists":
            return Self.hash(ArtistStore.shared.followed.map(\.id).joined(separator: ","))
        default:
            let playlists = Library.shared.playlists
            guard let id = UUID(uuidString: String(name.dropFirst(3))),
                  let p = playlists.first(where: { $0.id == id }) else { return nil }
            return Self.fingerprint(p, playlists)
        }
    }

    private static func fingerprint(_ p: Playlist, _ all: [Playlist]) -> String {
        let position = all.firstIndex(where: { $0.id == p.id }) ?? 0
        let s = [String(position), p.name, p.style.rawValue, String(p.colorIndex), p.symbol, p.coverFile ?? "",
                 String(p.isShared), String(p.isAlbum == true), p.albumArtist ?? ""].joined(separator: "|")
            + "|" + p.tracks.map(\.id).joined(separator: ",")
        return hash(s)
    }

    private static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100_0000_01b3
        }
        return String(h, radix: 16)
    }

    /// Songs as JSON text; very large lists drop artwork links to stay under Firestore's 1 MB limit.
    static func tracksJSON(_ tracks: [Track]) -> String {
        let enc = JSONEncoder()
        if let d = try? enc.encode(tracks), d.count < 850_000 { return String(decoding: d, as: UTF8.self) }
        let slim = tracks.map { t -> Track in
            var t = t
            t.artworkURL = nil
            t.channelAvatar = nil
            return t
        }
        let d = (try? enc.encode(slim)) ?? Data("[]".utf8)
        return String(decoding: d, as: UTF8.self)
    }

    static func decodeTracks(_ s: String?) -> [Track]? {
        guard let s else { return nil }
        return try? JSONDecoder().decode([Track].self, from: Data(s.utf8))
    }

    private func documentFields(_ name: String, updatedAt: Int) -> [String: Any]? {
        var f: [String: Any] = ["updatedAt": FV.i(updatedAt), "deleted": FV.b(false)]
        switch name {
        case "liked":
            f["tracks"] = FV.s(Self.tracksJSON(Library.shared.liked))
        case "artists":
            guard let d = try? JSONEncoder().encode(ArtistStore.shared.followed) else { return nil }
            f["artists"] = FV.s(String(decoding: d, as: UTF8.self))
        default:
            let playlists = Library.shared.playlists
            guard let id = UUID(uuidString: String(name.dropFirst(3))),
                  let i = playlists.firstIndex(where: { $0.id == id }) else { return nil }
            let p = playlists[i]
            f["name"] = FV.s(p.name)
            f["position"] = FV.i(i)
            f["tracks"] = FV.s(Self.tracksJSON(p.tracks))
            f["style"] = FV.s(p.style.rawValue)
            f["colorIndex"] = FV.i(p.colorIndex)
            f["symbol"] = FV.s(p.symbol)
            f["isPublic"] = FV.b(p.isShared)
            f["isAlbum"] = FV.b(p.isAlbum == true)
            if let a = p.albumArtist { f["albumArtist"] = FV.s(a) }
            if let cover = Library.shared.coverData(p), cover.count < 200_000 { f["cover"] = FV.bytes(cover) }
        }
        return f
    }

    private func apply(_ name: String, _ f: [String: Any], firstSync: Bool) {
        switch name {
        case "liked":
            guard let remote = Self.decodeTracks(FV.string(f, "tracks")) else { return }
            if synced["liked"] == nil {
                // First time on this device: keep both (remote first, then anything only liked here).
                let ids = Set(remote.map(\.id))
                Library.shared.replaceLiked(remote + Library.shared.liked.filter { !ids.contains($0.id) })
            } else {
                Library.shared.replaceLiked(remote)
            }
        case "artists":
            guard let s = FV.string(f, "artists"),
                  let remote = try? JSONDecoder().decode([FollowedArtist].self, from: Data(s.utf8)) else { return }
            if synced["artists"] == nil {
                let ids = Set(remote.map(\.id))
                ArtistStore.shared.replaceFollowed(remote + ArtistStore.shared.followed.filter { !ids.contains($0.id) })
            } else {
                ArtistStore.shared.replaceFollowed(remote)
            }
        default:
            guard let id = UUID(uuidString: String(name.dropFirst(3))),
                  Library.shared.playlist(id)?.collab == nil,
                  let title = FV.string(f, "name"),
                  let tracks = Self.decodeTracks(FV.string(f, "tracks")) else { return }
            var p = Library.shared.playlist(id) ?? Playlist(name: title)
            p.id = id
            p.name = title
            p.tracks = tracks
            p.coverStyle = FV.string(f, "style").flatMap(Playlist.CoverStyle.init(rawValue:))
            p.colorIndex = FV.int(f, "colorIndex") ?? 0
            p.coverSymbol = FV.string(f, "symbol")
            p.isPublic = FV.bool(f, "isPublic")
            p.isAlbum = FV.bool(f, "isAlbum") == true ? true : nil
            p.albumArtist = FV.string(f, "albumArtist")
            Library.shared.applyRemotePlaylist(p, cover: FV.data(f, "cover"), position: FV.int(f, "position") ?? 0)
        }
    }

    private func applyDeletion(_ name: String) {
        guard name.hasPrefix("pl-"), let id = UUID(uuidString: String(name.dropFirst(3))),
              let p = Library.shared.playlist(id), p.collab == nil else { return }
        Library.shared.deletePlaylist(id)
    }

    /// Profile deleted: remove the synced library from the server.
    func removeAll(uid: String) async {
        let docs = (try? await Firestore.list("users/\(uid)/library", fields: ["updatedAt"])) ?? []
        for name in docs.compactMap({ ($0["name"] as? String)?.split(separator: "/").last.map(String.init) }) {
            try? await Firestore.delete("users/\(uid)/library/\(name)")
        }
        UserDefaults.standard.removeObject(forKey: key(uid))
        synced = [:]
        syncedUID = nil
        pulledThisLaunch = false
    }
}
