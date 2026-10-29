import Foundation
import Observation

/// Listen Together: everyone hears the same songs at the same time, each on their own device.
/// One shared document per session (jams/{code}) holds what plays, where and whether; this keeps the
/// player in step with it (the computer does the same in jam.ts). Anyone in it can pick songs, play,
/// pause, skip and change what's next. When a song ends by itself, only the host says what's next.
@Observable @MainActor
final class JamSession {
    static let shared = JamSession()

    struct State: Equatable {
        var code: String
        var host: String
        var members: [String]
        var names: [String: String]
        var track: Track?
        var queue: [Track]
        var playing: Bool
        var position: Double
        /// When `position` was true (milliseconds, the server's clock).
        var at: Int
        var version: Int
        var updatedBy: String
    }

    /// The session you're in (nil when none).
    private(set) var state: State?
    /// The session ended without you leaving (the host ended it): shown once.
    var endedNotice = false
    var isHost: Bool { state != nil && state?.host == me }

    private var me: String? { SocialStore.shared.me?.id }
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var ticker: Timer?
    /// This device's clock minus the server's (ms), from the quickest round trip so far.
    @ObservationIgnored private var offset: Double = 0
    @ObservationIgnored private var bestTrip = Double.infinity
    // The controller (same rules as the computer's).
    @ObservationIgnored private var lastSignature = ""
    @ObservationIgnored private var lastSeenAt = 0
    @ObservationIgnored private var lastPublishLocal: Double = 0
    @ObservationIgnored private var lastSeeks = 0
    @ObservationIgnored private var applyingUntil = Date.distantPast
    @ObservationIgnored private var lastCorrection = Date.distantPast

    private init() {}

    private var player: Player { .shared }
    private static func path(_ code: String) -> String { "jams/\(code)" }
    private static func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }
    private var serverNow: Double { Self.nowMs() - offset }

    enum JamError: LocalizedError {
        case noProfile, noSession, failed
        var errorDescription: String? {
            switch self {
            case .noProfile: "Set up your Drift profile first, so friends can find you."
            case .noSession: "No session with that code. It may have ended."
            case .failed: "That didn't work. Try again."
            }
        }
    }

    // MARK: Server

    /// Learns how far this clock is from the server's, from a write's own time stamp.
    @discardableResult
    private func timed(_ write: () async throws -> String?) async throws -> String? {
        let sent = Self.nowMs()
        let updateTime = try await write()
        let back = Self.nowMs()
        if let updateTime, let server = Self.parseTime(updateTime), back - sent < bestTrip {
            bestTrip = back - sent
            offset = (sent + back) / 2 - server
        }
        return updateTime
    }

    private static func parseTime(_ s: String) -> Double? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Firestore gives microseconds; the formatter takes milliseconds.
        let trimmed = s.replacingOccurrences(of: "(\\.\\d{3})\\d+", with: "$1", options: .regularExpression)
        return f.date(from: trimmed).map { $0.timeIntervalSince1970 * 1000 }
    }

    private func parse(_ code: String, _ doc: [String: Any]?) -> State? {
        guard let f = doc?["fields"] as? [String: Any], let host = FV.string(f, "host") else { return nil }
        var names: [String: String] = [:]
        for (k, v) in FV.mapFields(f, "names") ?? [:] {
            if let s = (v as? [String: Any])?["stringValue"] as? String { names[k] = s }
        }
        func decode<T: Decodable>(_ key: String, _ type: T.Type) -> T? {
            guard let s = FV.string(f, key) else { return nil }
            return try? JSONDecoder().decode(T.self, from: Data(s.utf8))
        }
        let position = ((f["position"] as? [String: Any])?["doubleValue"] as? Double)
            ?? Double(FV.int(f, "position") ?? 0)
        return State(code: code, host: host, members: FV.stringArray(f, "members"), names: names,
                     track: decode("track", Track.self), queue: decode("queue", [Track].self) ?? [],
                     playing: FV.bool(f, "playing") ?? false, position: position,
                     at: FV.int(f, "at") ?? 0, version: FV.int(f, "version") ?? 0,
                     updatedBy: FV.string(f, "updatedBy") ?? host)
    }

    private static func namesField(_ names: [String: String]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in names { out[k] = FV.s(v) }
        return FV.map(out)
    }

    /// Shows the code on your profile, so friends can join from their Friends list.
    private func showOnProfile(_ code: String?) async {
        guard let me else { return }
        _ = try? await Firestore.patch("users/\(me)", fields: ["jam": code.map { FV.s($0) } ?? FV.null], mask: ["jam"])
    }

    func start() async throws {
        guard let me, let name = SocialStore.shared.me?.username else { throw JamError.noProfile }
        if state != nil { await leave() }
        let letters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        for _ in 0..<5 {
            let code = String((0..<6).map { _ in letters.randomElement()! })
            let fields: [String: Any] = [
                "host": FV.s(me), "members": FV.strings([me]), "names": Self.namesField([me: name]),
                "track": FV.s("null"), "queue": FV.s("[]"), "playing": FV.b(false), "position": ["doubleValue": 0.0],
                "at": FV.i(Int(serverNow)), "version": FV.i(1), "updatedBy": FV.s(me), "createdAt": FV.i(Int(Self.nowMs())),
            ]
            do {
                try await timed { try await Firestore.patch(Self.path(code), fields: fields, mustNotExist: true) }
            } catch SocialError.usernameTaken {
                continue   // code taken (create-only write refused)
            }
            try await begin(code)
            lastSeenAt = state?.at ?? 0
            if player.current != nil { publish() }
            return
        }
        throw JamError.failed
    }

    func join(_ raw: String) async throws {
        guard let me, let name = SocialStore.shared.me?.username else { throw JamError.noProfile }
        let code = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        if state?.code == code { return }
        if state != nil { await leave() }
        for _ in 0..<3 {
            guard let doc = try await Firestore.get(Self.path(code)), let s = parse(code, doc) else { throw JamError.noSession }
            if !s.members.contains(me) {
                var names = s.names
                names[me] = name
                do {
                    try await timed {
                        try await Firestore.patch(Self.path(code),
                                                  fields: ["members": FV.strings(s.members + [me]), "names": Self.namesField(names)],
                                                  mask: ["members", "names"], updateTime: doc["updateTime"] as? String)
                    }
                } catch SocialError.server(let status, _) where status == 400 || status == 409 {
                    continue   // someone else joined at the same moment
                }
            }
            try await begin(code)
            if let s = state { apply(s) }
            return
        }
        throw JamError.failed
    }

    private func begin(_ code: String) async throws {
        guard let s = parse(code, try await Firestore.get(Self.path(code))) else { throw JamError.noSession }
        state = s
        await showOnProfile(code)
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.poll()
            }
        }
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { JamSession.shared.tick() }
        }
    }

    private func poll() async {
        guard let code = state?.code, let me else { return }
        let doc: [String: Any]?
        do {
            doc = try await Firestore.get(Self.path(code))
        } catch {
            return   // no connection: try again in a moment
        }
        guard state?.code == code else { return }
        // Gone (the host ended it), or you were taken out of it.
        guard let s = parse(code, doc), s.members.contains(me) else {
            endedNotice = true
            end()
            return
        }
        received(s)
    }

    /// Leaving: the host ends it for everyone; anyone else just leaves.
    func leave() async {
        endedNotice = false
        guard let s = state, let me else { end(); return }
        if s.host == me {
            try? await Firestore.delete(Self.path(s.code))
        } else {
            for _ in 0..<3 {
                guard let doc = try? await Firestore.get(Self.path(s.code)), let cur = parse(s.code, doc) else { break }
                if (try? await Firestore.patch(Self.path(s.code), fields: ["members": FV.strings(cur.members.filter { $0 != me })],
                                               mask: ["members"], updateTime: doc["updateTime"] as? String)) != nil { break }
            }
        }
        end()
    }

    private func end() {
        poller?.cancel()
        poller = nil
        ticker?.invalidate()
        ticker = nil
        if state != nil {
            state = nil
            Task { await showOnProfile(nil) }
        }
    }

    // MARK: Keeping the player in step

    private func signature(_ track: Track?, _ playing: Bool, _ queue: [Track]) -> String {
        "\(track?.id ?? "")|\(playing)|" + queue.prefix(30).map(\.id).joined(separator: ",")
    }

    /// Playing, or about to (still loading a song that will play).
    private var localPlaying: Bool { player.isPlaying || player.isBuffering }

    private var localQueue: [Track] { Array(player.queue.dropFirst(player.index + 1).prefix(30)) }

    /// Where the session is now (seconds).
    private func expected(_ s: State) -> Double {
        guard s.playing else { return s.position }
        return s.position + max(0, serverNow - Double(s.at)) / 1000
    }

    private func received(_ s: State) {
        state = s
        guard s.at != lastSeenAt else { return }
        // Someone else's change, made after this device's last one (older answers are ignored).
        if s.updatedBy != me, Double(s.at) + offset > lastPublishLocal - 300 {
            apply(s)
        } else {
            lastSeenAt = s.at
        }
    }

    private func apply(_ s: State) {
        lastSeenAt = s.at
        guard let track = s.track else { return }
        // A moment for the player to settle, so it isn't mistaken for a change here.
        applyingUntil = Date().addingTimeInterval(0.7)
        player.jamPlay(track, upcoming: s.queue, at: expected(s), playing: s.playing)
        lastSignature = signature(track, s.playing, s.queue)
        lastSeeks = player.jamSeeks
    }

    private func publish() {
        guard let s = state, let me else { return }
        let track = player.current
        let queue = localQueue
        let playing = localPlaying
        let position = player.audioClock.time
        lastSignature = signature(track, playing, queue)
        lastSeeks = player.jamSeeks
        lastPublishLocal = Self.nowMs()
        let at = Int(serverNow)
        let version = s.version + 1
        state?.track = track
        state?.queue = queue
        state?.playing = playing
        state?.position = position
        state?.at = at
        state?.version = version
        state?.updatedBy = me
        let trackJSON = (try? JSONEncoder().encode(track)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
        let queueJSON = (try? JSONEncoder().encode(queue)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let fields: [String: Any] = [
            "track": FV.s(trackJSON), "queue": FV.s(queueJSON), "playing": FV.b(playing),
            "position": ["doubleValue": position], "at": FV.i(at), "version": FV.i(version), "updatedBy": FV.s(me),
        ]
        let code = s.code
        Task {
            _ = try? await timed { try await Firestore.patch(Self.path(code), fields: fields, mask: Array(fields.keys)) }
        }
    }

    /// Runs twice a second while in a session.
    private func tick() {
        guard let s = state, Date() >= applyingUntil else { return }
        let sig = signature(player.current, localPlaying, localQueue)
        if sig != lastSignature {
            // A song ended by itself and the next one started: the host announces it, everyone else waits.
            let natural = player.lastNaturalEnd.map { Date().timeIntervalSince($0) < 4 } ?? false
            if natural && !isHost {
                lastSignature = sig
                return
            }
            publish()
            return
        }
        if player.jamSeeks != lastSeeks {
            publish()   // jumped in the song here
            return
        }
        // Drifted apart (a slow connection, a pause to load): catch up quietly, at most every 5 s.
        if s.playing, player.isPlaying, !player.isBuffering, s.track?.id == player.current?.id,
           Date().timeIntervalSince(lastCorrection) > 5,
           abs(player.audioClock.time - expected(s)) > 1.2 {
            lastCorrection = Date()
            apply(s)
        }
    }
}
