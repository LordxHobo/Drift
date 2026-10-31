import Foundation

/// One song you listened to (30 seconds or more, like Spotify counts it).
struct PlayRecord: Codable, Hashable {
    var id: String
    var title: String
    var artist: String
    var art: String?
    /// When it started (seconds since 1970).
    var at: Double
    /// How long you listened.
    var secs: Double
}

/// What you've listened to, for Listening stats. Kept on this phone, and (with a Drift profile) also in your
/// synced library, one document per device and month ("plays-<device>-<yyyy-mm>"), so the stats add up
/// what you played on every device. Only you can read it.
@MainActor
final class PlayHistory {
    static let shared = PlayHistory()

    private(set) var plays: [PlayRecord] = []
    /// Songs count once you've listened this long.
    static let minimum: Double = 30

    private struct Stored: Codable {
        var plays: [PlayRecord]
        var dirty: [String]
    }

    private let url = AppFiles.data.appending(path: "plays.json")
    private var dirty = Set<String>()
    private var saveTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?

    // The song playing now.
    private var track: Track?
    private var listened: Double = 0
    private var lastTick: Date?
    private var recorded: Int?

    /// This phone's name in the synced history (made once, at random).
    let device: String = {
        if let d = UserDefaults.standard.string(forKey: "playHistory.device") { return d }
        let d = "ios" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        UserDefaults.standard.set(d, forKey: "playHistory.device")
        return d
    }()

    private init() {
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            plays = s.plays
            dirty = Set(s.dirty)
        }
    }

    // MARK: Counting (from the player)

    /// A new song started loading.
    func started(_ t: Track) {
        track = t.isEpisode ? nil : t
        listened = 0
        lastTick = nil
        recorded = nil
    }

    /// Called a few times a second while a song is loaded.
    func tick(playing: Bool) {
        guard playing, let t = track else {
            lastTick = nil
            return
        }
        let now = Date()
        if let last = lastTick {
            let d = now.timeIntervalSince(last)
            if d > 0 && d < 2 { listened += d }
        }
        lastTick = now
        guard listened >= Self.minimum else { return }
        if let i = recorded, plays.indices.contains(i) {
            // Only every few seconds (the list is saved after each change).
            guard listened - plays[i].secs >= 5 else { return }
            plays[i].secs = listened.rounded()
            markDirty(plays[i].at)
        } else {
            let start = now.timeIntervalSince1970 - listened
            plays.append(PlayRecord(id: t.id, title: t.title, artist: t.artist,
                                    art: t.artwork(size: 226)?.absoluteString, at: start.rounded(), secs: listened.rounded()))
            recorded = plays.count - 1
            markDirty(start)
        }
        scheduleSave()
    }

    private func markDirty(_ at: Double) {
        dirty.insert(Self.month(at))
    }

    static func month(_ at: Double) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month], from: Date(timeIntervalSince1970: at))
        return String(format: "%04d-%02d", c.year ?? 2000, c.month ?? 1)
    }

    // MARK: Saving and syncing

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            self?.saveTask = nil
            self?.save()
        }
        scheduleUpload(after: 300)
    }

    private func save() {
        let s = Stored(plays: plays, dirty: Array(dirty))
        let target = self.url
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(s) { try? data.write(to: target, options: .atomic) }
        }
    }

    private func scheduleUpload(after seconds: Double) {
        guard uploadTask == nil else { return }
        uploadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.upload()
            self?.uploadTask = nil
        }
    }

    /// Drift went to the background: save now, and send what's new.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        save()
        uploadTask?.cancel()
        uploadTask = nil
        Task { await upload() }
    }

    private func upload() async {
        guard let uid = SocialStore.shared.me?.id, !dirty.isEmpty else { return }
        for month in dirty.sorted() {
            let list = plays.filter { Self.month($0.at) == month }
            let fields: [String: Any] = [
                "plays": FV.s(Self.encode(list)),
                "device": FV.s(device),
                "updatedAt": FV.i(Int(Date().timeIntervalSince1970 * 1000)),
                "deleted": FV.b(false),
            ]
            do {
                try await Firestore.patch("users/\(uid)/library/plays-\(device)-\(month)", fields: fields)
                dirty.remove(month)
            } catch {
                return
            }
        }
        save()
    }

    /// The shared format (same as the computer's): songs once, then [id, start, seconds] for each play.
    static func encode(_ list: [PlayRecord]) -> String {
        var tracks: [String: [String]] = [:]
        for p in list where tracks[p.id] == nil { tracks[p.id] = [p.title, p.artist, p.art ?? ""] }
        let rows: [[Any]] = list.map { [$0.id, Int($0.at), Int($0.secs)] }
        let obj: [String: Any] = ["tracks": tracks, "plays": rows]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ s: String) -> [PlayRecord] {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { return [] }
        let tracks = obj["tracks"] as? [String: [String]] ?? [:]
        let rows = obj["plays"] as? [[Any]] ?? []
        return rows.compactMap { r in
            guard r.count >= 3, let id = r[0] as? String, let info = tracks[id], info.count >= 2 else { return nil }
            let at = (r[1] as? NSNumber)?.doubleValue ?? 0
            let secs = (r[2] as? NSNumber)?.doubleValue ?? 0
            return PlayRecord(id: id, title: info[0], artist: info[1], art: info.count > 2 && !info[2].isEmpty ? info[2] : nil,
                              at: at, secs: secs)
        }
    }

    /// Everything you've listened to: this phone, plus your other devices when you have a profile.
    func everything() async -> (plays: [PlayRecord], devices: Int) {
        let local = plays
        guard let uid = SocialStore.shared.me?.id,
              let docs = try? await Firestore.list("users/\(uid)/library", fields: ["plays", "device"]) else {
            return (local, 1)
        }
        var all = local
        var devices = Set([device])
        for d in docs {
            guard let name = (d["name"] as? String)?.split(separator: "/").last, name.hasPrefix("plays-"),
                  let f = d["fields"] as? [String: Any],
                  let other = FV.string(f, "device"), other != device,
                  let s = FV.string(f, "plays") else { continue }
            devices.insert(other)
            all += Self.decode(s)
        }
        return (all, devices.count)
    }
}
