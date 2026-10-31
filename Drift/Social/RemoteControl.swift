import Foundation
import UIKit

/// What a device (this phone, or your computer) is playing, as it tells your other devices.
/// Same JSON as the computer's (desktop/src/shared/remote.ts).
struct RemoteDevice: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// "phone" or "computer".
    var kind: String
    /// When it last said so (ms since 1970).
    var at: Double
    var track: Track?
    /// What comes next (up to 30 songs).
    var queue: [Track]?
    var playing: Bool
    var position: Double
    /// When `position` was measured (ms since 1970).
    var positionAt: Double
    var duration: Double
    var volume: Double
    var shuffle: Bool
    var repeatMode: String
    var source: String?

    enum CodingKeys: String, CodingKey {
        case id, name, kind, at, track, queue, playing, position, positionAt, duration, volume, shuffle, source
        case repeatMode = "repeat"
    }

    /// Heard from in the last 75 s.
    var online: Bool { Date().timeIntervalSince1970 * 1000 - at < 75_000 }

    /// Where it is now (moving on from the last report while it plays).
    func positionNow() -> Double {
        guard playing else { return position }
        let p = position + max(0, Date().timeIntervalSince1970 * 1000 - positionAt) / 1000
        return duration > 0 ? min(p, duration) : p
    }

    var symbol: String { kind == "phone" ? "iphone" : "laptopcomputer" }
}

/// Something to do on another device: play, pause, skip, seek, volume, play these songs…
struct RemoteCommand: Codable {
    var id: Double = 0
    var from: String = ""
    var type: String
    var track: Track?
    var tracks: [Track]?
    var queue: [Track]?
    var start: Int?
    var position: Double?
    var playing: Bool?
    var value: Double?
    var on: Bool?
    var mode: String?
    var source: String?

    init(type: String) { self.type = type }
}

/// Control other device: play on your computer from your phone (and the other way round), like Spotify
/// Connect. Everything goes through your synced library, which only you can read:
/// - library/devices: one field per device ("d_<device>") with what it's playing, updated when that
///   changes and every 30 s;
/// - library/remote-<device>: the last commands sent to that device, which it checks every 6 s, or every
///   second while something controls it ("awakeUntil").
/// No push notifications (they'd need a paid Apple account), so a command takes up to a second, and the
/// first one up to a few seconds while the other device wakes up. The phone can be controlled while Drift
/// is open or playing.
@Observable @MainActor
final class RemoteControl {
    static let shared = RemoteControl()

    /// Your other devices (newest first).
    private(set) var devices: [RemoteDevice] = []
    /// The device this phone controls, or nil (playing here).
    private(set) var target: String?
    /// The Devices sheet is open (devices are refreshed more often).
    var pickerOpen = false {
        didSet { if pickerOpen { Task { await refreshDevices() } } }
    }
    private(set) var lastError: String?

    var targetDevice: RemoteDevice? { target.flatMap { id in devices.first { $0.id == id } } }

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastCommand: Double?
    @ObservationIgnored private var awakeUntil: Double = 0
    @ObservationIgnored private var lastPoll = Date.distantPast
    @ObservationIgnored private var lastDevices = Date.distantPast
    @ObservationIgnored private var lastPublish = Date.distantPast
    @ObservationIgnored private var changedAt: Date?
    @ObservationIgnored private var lastWake = Date.distantPast

    private var device: String { PlayHistory.shared.device }
    private var uid: String? { SocialStore.shared.me?.id }

    private init() {}

    // MARK: Running

    /// Starts checking for commands and telling your other devices what's playing (once there's a profile).
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.step()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Something changed here (song, play/pause, position): tell your other devices soon.
    func localChanged() {
        if changedAt == nil { changedAt = Date() }
    }

    private var appActive: Bool { UIApplication.shared.applicationState == .active }

    private func step() async {
        guard uid != nil else { return }
        // Drift in the background and not playing: iOS will suspend it soon anyway.
        let awake = appActive || Player.shared.isPlaying
        guard awake else { return }
        let now = Date()

        // Commands for this phone: every second while something controls it, otherwise every 6 s.
        let fast = now.timeIntervalSince1970 * 1000 < awakeUntil
        if now.timeIntervalSince(lastPoll) >= (fast ? 1 : 6) {
            lastPoll = now
            await pollCommands()
        }

        // What's playing here: soon after a change, and every 30 s so the others know it's on.
        if let c = changedAt, now.timeIntervalSince(c) >= 0.4 {
            changedAt = nil
            await publish()
        } else if now.timeIntervalSince(lastPublish) >= 30 {
            await publish()
        }

        // Controlling another device (or choosing one): its state every 1.5 s, and keep it awake.
        if target != nil || pickerOpen {
            if now.timeIntervalSince(lastDevices) >= 1.5 { await refreshDevices() }
            if let target, now.timeIntervalSince(lastWake) >= 20 {
                lastWake = now
                await wake(target)
            }
        }
    }

    // MARK: This phone, as the others see it

    private func publish() async {
        guard let uid else { return }
        lastPublish = Date()
        let p = Player.shared
        let state = RemoteDevice(
            id: device, name: UIDevice.current.model, kind: "phone",
            at: Date().timeIntervalSince1970 * 1000,
            track: p.current, queue: Array(p.upNext.prefix(30)),
            playing: p.isPlaying, position: p.currentTime.isFinite ? p.currentTime : 0,
            positionAt: Date().timeIntervalSince1970 * 1000,
            duration: p.duration.isFinite ? p.duration : 0, volume: Double(p.appVolume), shuffle: p.shuffle,
            repeatMode: p.repeatMode == .one ? "one" : p.repeatMode == .all ? "all" : "off",
            source: p.playingFrom)
        guard let data = try? JSONEncoder().encode(state) else { return }
        let field = "d_\(device)"
        try? await Firestore.patch("users/\(uid)/library/devices",
                                   fields: [field: FV.s(String(decoding: data, as: UTF8.self))], mask: [field])
    }

    // MARK: Being controlled

    private func pollCommands() async {
        guard let uid, let doc = try? await Firestore.get("users/\(uid)/library/remote-\(device)"),
              let f = doc["fields"] as? [String: Any] else {
            if lastCommand == nil { lastCommand = 0 }
            return
        }
        awakeUntil = Double(FV.int(f, "awakeUntil") ?? 0)
        let list = FV.string(f, "cmds").flatMap { try? JSONDecoder().decode([RemoteCommand].self, from: Data($0.utf8)) } ?? []
        // First look: what was sent before Drift opened doesn't count.
        guard let last = lastCommand else {
            lastCommand = list.map(\.id).max() ?? 0
            return
        }
        let fresh = list.filter { $0.id > last }.sorted { $0.id < $1.id }
        guard !fresh.isEmpty else { return }
        lastCommand = fresh.last!.id
        let now = Date().timeIntervalSince1970 * 1000
        for c in fresh where now - c.id / 1000 < 60_000 { run(c) }
        awakeUntil = max(awakeUntil, now + 90_000)
        localChanged()
    }

    /// Does what another device asked.
    private func run(_ c: RemoteCommand) {
        let p = Player.shared
        // Asked to play here: this phone stops controlling another device.
        if c.type == "transfer" || c.type == "play" { stopControlling(silently: true) }
        let saved = p.redirect
        p.redirect = nil
        defer { p.redirect = saved }
        switch c.type {
        case "transfer":
            if let t = c.track {
                p.transferIn(t, upcoming: c.queue ?? [], at: c.position ?? 0, playing: c.playing ?? true, source: c.source ?? "")
            }
        case "play":
            if let tracks = c.tracks, !tracks.isEmpty {
                p.play(tracks, startAt: min(max(c.start ?? 0, 0), tracks.count - 1), from: c.source ?? "Another device")
            }
        case "toggle": p.togglePlay()
        case "resume": p.resume()
        case "pause": p.pause()
        case "next": p.next()
        case "previous": p.previous()
        case "seek": if let pos = c.position { p.seek(to: pos) }
        case "volume": if let v = c.value { p.appVolume = Float(v) }
        case "shuffle": if let on = c.on, on != p.shuffle { p.toggleShuffle() }
        case "repeat":
            switch c.mode {
            case "all": p.repeatMode = .all
            case "one": p.repeatMode = .one
            default: p.repeatMode = .off
            }
        case "playNext": if let t = c.track { p.playNext(t) }
        case "addToQueue": if let t = c.track { p.addToQueue(t) }
        default: break
        }
    }

    // MARK: Controlling another device

    func refreshDevices() async {
        guard let uid else { return }
        lastDevices = Date()
        guard let doc = try? await Firestore.get("users/\(uid)/library/devices"),
              let f = doc["fields"] as? [String: Any] else { return }
        var list: [RemoteDevice] = []
        for key in f.keys where key.hasPrefix("d_") && key != "d_\(device)" {
            guard let s = FV.string(f, key), let d = try? JSONDecoder().decode(RemoteDevice.self, from: Data(s.utf8)) else { continue }
            list.append(d)
        }
        devices = list.sorted { $0.at > $1.at }
    }

    /// Sends a command to the device being controlled (or `to`).
    @discardableResult
    func send(_ command: RemoteCommand, to id: String? = nil) -> Bool {
        guard let uid, let id = id ?? target else { return false }
        var c = command
        c.from = device
        c.id = (Date().timeIntervalSince1970 * 1000).rounded() * 1000 + Double(Int.random(in: 0..<1000))
        Task {
            let path = "users/\(uid)/library/remote-\(id)"
            var list: [RemoteCommand] = []
            if let doc = try? await Firestore.get(path), let f = doc["fields"] as? [String: Any],
               let s = FV.string(f, "cmds"), let old = try? JSONDecoder().decode([RemoteCommand].self, from: Data(s.utf8)) {
                list = old
            }
            list.append(c)
            list = Array(list.suffix(20))
            guard let data = try? JSONEncoder().encode(list) else { return }
            do {
                try await Firestore.patch(path, fields: [
                    "cmds": FV.s(String(decoding: data, as: UTF8.self)),
                    "awakeUntil": FV.i(Int(Date().timeIntervalSince1970 * 1000) + 90_000),
                ], mask: ["cmds", "awakeUntil"])
                lastError = nil
            } catch {
                lastError = "Couldn't reach your other device. Check your connection."
            }
            try? await Task.sleep(for: .milliseconds(700))
            await refreshDevices()
        }
        // Show the change right away (the device confirms it a moment later).
        if let i = devices.firstIndex(where: { $0.id == id }) { applyLocally(c, to: &devices[i]) }
        return true
    }

    private func applyLocally(_ c: RemoteCommand, to d: inout RemoteDevice) {
        let now = Date().timeIntervalSince1970 * 1000
        switch c.type {
        case "toggle", "resume", "pause":
            let playing = c.type == "toggle" ? !d.playing : c.type == "resume"
            d.position = d.positionNow()
            d.positionAt = now
            d.playing = playing
        case "seek":
            d.position = c.position ?? d.position
            d.positionAt = now
        case "volume": d.volume = c.value ?? d.volume
        case "shuffle": d.shuffle = c.on ?? d.shuffle
        case "repeat": d.repeatMode = c.mode ?? d.repeatMode
        default: break
        }
    }

    private func wake(_ id: String) async {
        guard let uid else { return }
        try? await Firestore.patch("users/\(uid)/library/remote-\(id)",
                                   fields: ["awakeUntil": FV.i(Int(Date().timeIntervalSince1970 * 1000) + 90_000)],
                                   mask: ["awakeUntil"])
    }

    /// Plays on another device: what's playing here moves there (and stops here).
    func connect(_ id: String) {
        guard id != target else { return }
        let p = Player.shared
        stopControlling(silently: true)
        if let t = p.current {
            var c = RemoteCommand(type: "transfer")
            c.track = t
            c.queue = Array(p.upNext.prefix(50))
            c.position = p.currentTime
            c.playing = p.isPlaying
            c.source = p.playingFrom
            send(c, to: id)
            p.pause()
        } else {
            Task { await wake(id) }
        }
        target = id
        lastWake = Date()
        p.redirect = { [weak self] c in self?.send(c) ?? false }
        UIState.shared.showPlayer = false
        Task { await refreshDevices() }
    }

    /// Back to playing on this phone: picks up where the other device is, and pauses it.
    func playHere() {
        guard let d = targetDevice else {
            stopControlling(silently: true)
            return
        }
        let wasPlaying = d.playing
        if wasPlaying { send(RemoteCommand(type: "pause")) }
        stopControlling(silently: true)
        if let t = d.track {
            Player.shared.transferIn(t, upcoming: d.queue ?? [], at: d.positionNow(), playing: wasPlaying, source: d.source ?? "")
        }
    }

    /// Stops controlling the other device (it keeps playing).
    func stopControlling(silently: Bool = false) {
        target = nil
        Player.shared.redirect = nil
        if !silently { lastError = nil }
    }
}
