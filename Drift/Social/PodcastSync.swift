import Foundation
import Observation

/// Keeps the shows you follow and where you are in each episode the same on all your devices, in one
/// document (users/{uid}/library/podcasts), the same as the computer's and Android's:
/// - shows: the followed shows (JSON), with showsAt, when they last changed (the newest list wins);
/// - progress: episode id → where it was left (JSON), each episode's newest place winning.
@MainActor
final class PodcastSync {
    static let shared = PodcastSync()

    /// One episode's place, as stored: the episode, position and length (s), when (ms since 1970), finished.
    private struct Entry: Codable {
        var t: Track
        var p: Double
        var d: Double
        var u: Int
        var f: Bool?
    }

    /// At most this many episodes' places are kept on the server (the most recent).
    private static let keep = 300

    private var pending: Task<Void, Never>?
    private var loop: Task<Void, Never>?
    private var running = false

    private init() {}

    /// Every 2 minutes while Drift runs.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                await self?.sync()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    /// Something changed here. A follow or a jump: sent in a moment. A place while playing: at most once a
    /// minute (it changes every second).
    func changed(soon: Bool) {
        guard SocialStore.shared.me != nil else { return }
        if !soon, pending != nil { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(soon ? 2 : 60))
            guard !Task.isCancelled else { return }
            self?.pending = nil
            await self?.sync()
        }
    }

    /// Back in Drift, or leaving it.
    func syncNow() {
        Task { await sync() }
    }

    /// Each item on its own, so one this app can't read doesn't drop the rest.
    private static func decode<T: Decodable>(_ type: T.Type, _ object: Any) -> T? {
        guard let d = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    func sync() async {
        guard !running, let uid = SocialStore.shared.me?.id else { return }
        running = true
        defer { running = false }
        let path = "users/\(uid)/library/podcasts"
        let doc: [String: Any]
        do { doc = try await Firestore.get(path) ?? [:] } catch { return }
        let f = doc["fields"] as? [String: Any]

        var remoteShows: [PodcastChannel]?
        if let s = FV.string(f, "shows"), let list = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [Any] {
            remoteShows = list.compactMap { Self.decode(PodcastChannel.self, $0) }
        }
        let remoteShowsAt = FV.int(f, "showsAt") ?? 0
        var remote: [String: Entry] = [:]
        if let s = FV.string(f, "progress"), let map = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
            for (id, v) in map { if let e = Self.decode(Entry.self, v) { remote[id] = e } }
        }

        let store = PodcastStore.shared
        let now = PodcastStore.nowMs
        let local = store.subscriptions
        var shows = local
        var showsAt = store.showsChanged
        var sendShows = false
        if let remoteShows {
            if store.syncedUid != uid {
                // First sync on this phone: both (the profile's first, then any followed only here).
                let ids = Set(remoteShows.map(\.id))
                let extra = local.filter { !ids.contains($0.id) }
                shows = remoteShows + extra
                sendShows = !extra.isEmpty
                showsAt = sendShows ? now : remoteShowsAt
            } else if remoteShowsAt > showsAt {
                shows = remoteShows
                showsAt = remoteShowsAt
            } else if showsAt > remoteShowsAt {
                sendShows = true
            }
        } else {
            sendShows = !local.isEmpty || showsAt > 0
            if showsAt == 0 { showsAt = now }
        }
        if shows != local || showsAt != store.showsChanged { store.adoptShows(shows, changedAt: showsAt) }

        // Each episode: the newest place wins.
        let mine = store.progress
        func ms(_ d: Date) -> Int { Int(d.timeIntervalSince1970 * 1000) }
        var newer: [String: EpisodeProgress] = [:]
        for (id, e) in remote {
            if let m = mine[id], ms(m.updated) >= e.u { continue }
            newer[id] = EpisodeProgress(track: e.t, position: e.p, duration: e.d,
                                        updated: Date(timeIntervalSince1970: Double(e.u) / 1000), finished: e.f ?? false)
        }
        var all = remote
        for (id, p) in mine {
            if let r = all[id], r.u >= ms(p.updated) { continue }
            all[id] = Entry(t: p.track, p: p.position, d: p.duration, u: ms(p.updated), f: p.finished)
        }
        store.adoptProgress(newer)
        let kept = Dictionary(uniqueKeysWithValues: all.sorted { $0.value.u > $1.value.u }.prefix(Self.keep).map { ($0.key, $0.value) })
        let sendProgress = kept.mapValues(\.u) != remote.mapValues(\.u)
        store.markSynced(uid)

        guard sendShows || sendProgress,
              let showsJSON = try? JSONEncoder().encode(shows),
              let progressJSON = try? JSONEncoder().encode(kept) else { return }
        _ = try? await Firestore.patch(path, fields: [
            "shows": FV.s(String(decoding: showsJSON, as: UTF8.self)),
            "showsAt": FV.i(showsAt),
            "progress": FV.s(String(decoding: progressJSON, as: UTF8.self)),
            "updatedAt": FV.i(PodcastStore.nowMs),
            "deleted": FV.b(false),
        ])
    }
}
