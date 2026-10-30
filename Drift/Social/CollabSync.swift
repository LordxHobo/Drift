import Foundation
import UIKit

/// Collaborative playlists: one shared document per playlist (collabs/{playlist id}) that every
/// member can change. Each device remembers the list as it last saw it there, so only its own changes
/// are sent, merged into the newest list (the computer does exactly the same, in collab.ts).
@MainActor
final class CollabSync {
    static let shared = CollabSync()

    /// What the server had when this device last synced each playlist.
    private struct Base: Codable {
        var updateTime: String
        var ids: [String]
        var name: String
        /// The cover as it was here after the last sync (to notice a change here), and when the shared
        /// cover last changed (to notice a change by someone else).
        var coverSig: String?
        var coverAt: Int?
    }

    private struct Stored: Codable {
        var bases: [String: Base] = [:]
        var left: [String] = []
    }

    private struct Remote {
        let id: UUID
        let updateTime: String
        var info: CollabInfo
        var name: String
        let colorIndex: Int
        var tracks: [Track]
        var coverStyle: String? = nil
        var coverSymbol: String? = nil
        var cover: Data? = nil
        var coverAt: Int = 0
    }

    private var state: Stored
    private var running = false
    private var again = false
    private var scheduled: Task<Void, Never>?
    private var loop: Task<Void, Never>?
    /// A collaborative playlist on screen: checked every few seconds instead of every 30.
    var watching: UUID? {
        didSet { if watching != nil && oldValue == nil { schedule(after: 0) } }
    }
    private static let key = "collabSync.state"

    private init() {
        state = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// Starts looking for changes from the others: every 4 s while a shared playlist is on screen,
    /// every 30 s otherwise (while Drift is open), and whenever Drift comes back.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            var last = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                let gap: Double = self.watching != nil ? 4 : 30
                if Date().timeIntervalSince(last) >= gap, UIApplication.shared.applicationState != .background {
                    last = Date()
                    await self.run()
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// A change in the library: send it a moment later (only when you have shared playlists).
    func libraryChanged() {
        guard Library.shared.playlists.contains(where: { $0.collab != nil }) else { return }
        schedule(after: 2)
    }

    func schedule(after seconds: Double) {
        scheduled?.cancel()
        scheduled = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await run()
        }
    }

    /// Syncs right away (and waits for it).
    func syncNow() async {
        scheduled?.cancel()
        if running {
            again = true
            while running { try? await Task.sleep(for: .milliseconds(50)) }
            return
        }
        await run()
    }

    private func run() async {
        if running { again = true; return }
        running = true
        defer { running = false }
        repeat {
            again = false
            try? await sync()
        } while again
    }

    private var uid: String? { SocialStore.shared.me?.id }
    private var myName: String { SocialStore.shared.me?.name ?? "Someone" }

    // MARK: Reading and writing the shared document

    private func parse(_ doc: [String: Any]?) -> Remote? {
        guard let doc, let f = doc["fields"] as? [String: Any],
              let name = (doc["name"] as? String)?.split(separator: "/").last.map(String.init),
              let id = UUID(uuidString: name),
              let owner = FV.string(f, "owner"),
              let tracks = LibrarySync.decodeTracks(FV.string(f, "tracks")),
              let updateTime = doc["updateTime"] as? String else { return nil }
        var names: [String: String] = [:]
        for (k, v) in FV.mapFields(f, "names") ?? [:] {
            if let s = (v as? [String: Any])?["stringValue"] as? String { names[k] = s }
        }
        return Remote(id: id, updateTime: updateTime,
                      info: CollabInfo(owner: owner, members: FV.stringArray(f, "members"), names: names),
                      name: FV.string(f, "name") ?? "Playlist", colorIndex: FV.int(f, "colorIndex") ?? 0, tracks: tracks,
                      coverStyle: FV.string(f, "coverStyle"), coverSymbol: FV.string(f, "coverSymbol"),
                      cover: FV.data(f, "cover"), coverAt: FV.int(f, "coverAt") ?? 0)
    }

    private static func infoFields(_ info: CollabInfo) -> [String: Any] {
        var names: [String: Any] = [:]
        for (k, v) in info.names { names[k] = FV.s(v) }
        return ["owner": FV.s(info.owner), "members": FV.strings(info.members), "names": FV.map(names)]
    }

    private static func path(_ id: UUID) -> String { "collabs/\(id.uuidString)" }

    /// Takes the server's version as it is (nothing changed here).
    private func adopt(_ r: Remote) {
        let isNew = Library.shared.playlist(r.id) == nil
        var p = Library.shared.playlist(r.id) ?? Playlist(name: r.name)
        p.id = r.id
        p.name = r.name
        p.tracks = r.tracks
        p.collab = r.info
        if isNew { p.colorIndex = r.colorIndex }
        Library.shared.setCollabPlaylist(p)
        var base = state.bases[r.id.uuidString]
        base = Base(updateTime: r.updateTime, ids: r.tracks.map(\.id), name: r.name,
                    coverSig: base?.coverSig, coverAt: base?.coverAt)
        state.bases[r.id.uuidString] = base
        // A cover set by someone else (or the shared one, the first time).
        if r.coverAt != 0 && (isNew || r.coverAt != base?.coverAt) { adoptCover(r) }
    }

    // MARK: The cover (colour, symbol or photo): whoever changed it last wins

    private func coverSig(_ p: Playlist?) -> String {
        guard let p else { return "" }
        return "\(p.style.rawValue)|\(p.coverSymbol ?? "")|\(p.colorIndex)|\(p.coverFile ?? "")"
    }

    private func adoptCover(_ r: Remote) {
        Library.shared.setCollabCover(r.id, style: r.coverStyle.flatMap(Playlist.CoverStyle.init(rawValue:)) ?? .auto,
                                      symbol: r.coverSymbol, colorIndex: r.colorIndex, photo: r.cover)
        state.bases[r.id.uuidString]?.coverAt = r.coverAt
        state.bases[r.id.uuidString]?.coverSig = coverSig(Library.shared.playlist(r.id))
    }

    /// Sends the cover as it is here (changed here since the last sync).
    private func sendCover(_ p: Playlist) async throws {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let photo = p.style == .photo ? Library.shared.coverData(p) : nil
        let fields: [String: Any] = [
            "coverStyle": FV.s(photo == nil && p.style == .photo ? "auto" : p.style.rawValue),
            "coverSymbol": FV.s(p.coverSymbol ?? ""), "colorIndex": FV.i(p.colorIndex),
            "cover": photo.map(FV.bytes) ?? FV.null, "coverAt": FV.i(now),
        ]
        let updateTime = try await Firestore.patch(Self.path(p.id), fields: fields,
                                                   mask: ["coverStyle", "coverSymbol", "colorIndex", "cover", "coverAt"])
        state.bases[p.id.uuidString]?.coverAt = now
        state.bases[p.id.uuidString]?.coverSig = coverSig(p)
        if let updateTime { state.bases[p.id.uuidString]?.updateTime = updateTime }
    }

    /// After the songs: a cover changed here goes up; one changed by someone else comes down.
    private func syncCover(_ r: Remote) async throws {
        guard let base = state.bases[r.id.uuidString], let local = Library.shared.playlist(r.id) else { return }
        let now = coverSig(local)
        if base.coverSig == nil {
            // First sync with covers: remember how it is now.
            state.bases[r.id.uuidString]?.coverSig = now
            if r.coverAt != 0 { state.bases[r.id.uuidString]?.coverAt = r.coverAt }
        } else if base.coverSig != now {
            try await sendCover(local)
        } else if r.coverAt != 0 && r.coverAt != (base.coverAt ?? 0) {
            adoptCover(r)
        }
    }

    private func sync() async throws {
        guard let uid else { return }
        let docs = try await Firestore.query([
            "from": [["collectionId": "collabs"]],
            "where": ["fieldFilter": ["field": ["fieldPath": "members"], "op": "ARRAY_CONTAINS",
                                      "value": ["stringValue": uid]]],
        ])
        let remotes = docs.compactMap(parse)
        var seen = Set<UUID>()

        for r in remotes {
            seen.insert(r.id)
            if state.left.contains(r.id.uuidString) { continue }
            guard let local = Library.shared.playlist(r.id), let base = state.bases[r.id.uuidString] else {
                // New (invited, or made collaborative on another device of yours).
                adopt(r)
                continue
            }
            if CollabMerge.hasLocalChanges(base: base.ids, baseName: base.name, local: local.tracks, localName: local.name) {
                try await send(r, local: local, base: base, uid: uid)
            } else if r.updateTime != base.updateTime {
                adopt(r)
            } else if local.collab != r.info {
                Library.shared.setCollabInfo(r.id, r.info)
            }
            try? await syncCover(r)
        }

        // Shared playlists that are gone (stopped by their owner, or you were removed).
        for p in Library.shared.playlists where p.collab != nil && !seen.contains(p.id) {
            if p.collab?.owner == uid {
                Library.shared.setCollabInfo(p.id, nil)   // yours: it's a normal playlist again
            } else {
                Library.shared.deletePlaylist(p.id)
            }
            state.bases[p.id.uuidString] = nil
        }
        state.left.removeAll { id in !seen.contains(where: { $0.uuidString == id }) }
        save()
    }

    /// Sends this device's changes, merged into the newest version (tries again if someone was quicker).
    private func send(_ remote: Remote, local: Playlist, base: Base, uid: String) async throws {
        var r = remote
        for _ in 0..<3 {
            let tracks = CollabMerge.mergeTracks(base: base.ids, local: local.tracks, remote: r.tracks, me: uid)
            let name = CollabMerge.mergeName(base: base.name, local: local.name, remote: r.name)
            var info = r.info
            info.names[uid] = myName
            let fields: [String: Any] = [
                "name": FV.s(name), "tracks": FV.s(LibrarySync.tracksJSON(tracks)),
                "names": Self.infoFields(info)["names"]!,
                "updatedAt": FV.i(Int(Date().timeIntervalSince1970 * 1000)), "updatedBy": FV.s(uid),
            ]
            do {
                let updateTime = try await Firestore.patch(Self.path(r.id), fields: fields,
                                                           mask: ["name", "tracks", "names", "updatedAt", "updatedBy"],
                                                           updateTime: r.updateTime)
                var done = r
                done.name = name
                done.tracks = tracks
                done.info = info
                adopt(Remote(id: done.id, updateTime: updateTime ?? r.updateTime, info: done.info,
                             name: done.name, colorIndex: done.colorIndex, tracks: done.tracks))
                return
            } catch SocialError.server(let status, _) where status == 400 || status == 409 || status == 412 {
                // Someone else changed it first: merge into their version instead.
                guard let fresh = parse(try await Firestore.get(Self.path(r.id))) else { return }
                r = fresh
            }
        }
    }

    // MARK: Sharing, inviting, leaving

    /// Makes one of your playlists collaborative (you're the owner), or changes who's in it.
    func share(_ id: UUID, with people: [UserProfile]) async throws {
        guard let uid else { throw SocialError.notSignedIn }
        guard let p = Library.shared.playlist(id) else { return }
        if p.collab != nil { return try await setMembers(id, people) }
        var names = [uid: myName]
        for f in people { names[f.id] = f.name }
        let info = CollabInfo(owner: uid, members: [uid] + people.map(\.id), names: names)
        let tracks = p.tracks.map { t -> Track in
            var t = t
            if t.addedBy == nil { t.addedBy = uid }
            return t
        }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        var fields = Self.infoFields(info)
        fields["name"] = FV.s(p.name)
        fields["tracks"] = FV.s(LibrarySync.tracksJSON(tracks))
        fields["colorIndex"] = FV.i(p.colorIndex)
        fields["createdAt"] = FV.i(now)
        fields["updatedAt"] = FV.i(now)
        fields["updatedBy"] = FV.s(uid)
        let updateTime = try await Firestore.patch(Self.path(id), fields: fields, mustNotExist: true)
        state.left.removeAll { $0 == id.uuidString }
        var shared = p
        shared.tracks = tracks
        shared.collab = info
        Library.shared.setCollabPlaylist(shared)
        state.bases[id.uuidString] = Base(updateTime: updateTime ?? "", ids: tracks.map(\.id), name: p.name,
                                          coverSig: "", coverAt: 0)   // "" = sends the cover on the next sync
        save()
        schedule(after: 0)
    }

    /// The owner changes who's in it.
    private func setMembers(_ id: UUID, _ people: [UserProfile]) async throws {
        guard let uid, let r = parse(try await Firestore.get(Self.path(id))), r.info.owner == uid else { return }
        var names = [uid: myName]
        for f in people { names[f.id] = f.name }
        let info = CollabInfo(owner: uid, members: [uid] + people.map(\.id).filter { $0 != uid }, names: names)
        let updateTime = try await Firestore.patch(Self.path(id), fields: Self.infoFields(info),
                                                   mask: ["owner", "members", "names"], updateTime: r.updateTime)
        Library.shared.setCollabInfo(id, info)
        if let updateTime { state.bases[id.uuidString]?.updateTime = updateTime }
        save()
    }

    /// A member leaves (the playlist goes from their library).
    func leave(_ id: UUID) async throws {
        guard let uid else { return }
        if let r = parse(try await Firestore.get(Self.path(id))), r.info.owner != uid {
            try await Firestore.patch(Self.path(id), fields: ["members": FV.strings(r.info.members.filter { $0 != uid })],
                                      mask: ["members"], updateTime: r.updateTime)
        }
        state.left.append(id.uuidString)
        state.bases[id.uuidString] = nil
        Library.shared.deletePlaylist(id)
        save()
    }

    /// The owner stops sharing: a normal playlist again (and gone from everyone else's library).
    func stop(_ id: UUID) async throws {
        try await Firestore.delete(Self.path(id))
        state.bases[id.uuidString] = nil
        Library.shared.setCollabInfo(id, nil)
        save()
    }
}

/// Merging edits to a collaborative playlist (the same rules as the computer's collabMerge.ts).
enum CollabMerge {
    static func mergeTracks(base: [String], local: [Track], remote: [Track], me: String) -> [Track] {
        let baseSet = Set(base)
        let localIDs = Set(local.map(\.id))
        let removed = Set(base.filter { !localIDs.contains($0) })
        let added = local.filter { !baseSet.contains($0.id) }

        // Songs removed here stay removed.
        var result = remote.filter { !removed.contains($0.id) }

        // Moved here: the songs this device knew about take its order, in the places they hold now.
        let commonLocal = local.filter { baseSet.contains($0.id) }.map(\.id)
        let commonBase = base.filter { localIDs.contains($0) }
        if commonLocal != commonBase {
            var order: [String: Int] = [:]
            for (i, id) in commonLocal.enumerated() { order[id] = i }
            let known = result.filter { order[$0.id] != nil }.sorted { order[$0.id]! < order[$1.id]! }
            var k = 0
            result = result.map { t in
                guard order[t.id] != nil else { return t }
                defer { k += 1 }
                return known[k]
            }
        }

        // Added here: after the song it follows here (or at the start), marked as added by this person.
        for t in added where !result.contains(where: { $0.id == t.id }) {
            let i = local.firstIndex { $0.id == t.id } ?? 0
            var song = t
            if song.addedBy == nil { song.addedBy = me }
            if i == 0 {
                result.insert(song, at: 0)
            } else if let at = result.firstIndex(where: { $0.id == local[i - 1].id }) {
                result.insert(song, at: at + 1)
            } else {
                result.append(song)
            }
        }
        return result
    }

    static func mergeName(base: String, local: String, remote: String) -> String {
        local != base ? local : remote
    }

    static func hasLocalChanges(base: [String], baseName: String, local: [Track], localName: String) -> Bool {
        localName != baseName || base != local.map(\.id)
    }
}
