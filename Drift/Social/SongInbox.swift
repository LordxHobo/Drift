import Foundation
import Observation
import UIKit

/// A song a friend sent you.
struct InboxItem: Identifiable, Equatable {
    /// The document's name: who sent it and when ("<their id>_<ms>").
    let id: String
    let from: String
    let fromName: String
    let track: Track
    /// What they wrote with it ("" for none).
    let note: String
    let at: Date
    /// Opened on one of your devices.
    var seen: Bool
}

/// Sending songs to friends (from a song's menu) and the inbox of songs friends sent you. Each song is a
/// document at users/{them}/inbox/{you}_{ms}; the server only accepts it when you follow each other and
/// they allow it. The computer and Android do the same.
@Observable @MainActor
final class SongInbox {
    static let shared = SongInbox()

    /// Songs friends sent you, newest first.
    private(set) var items: [InboxItem] = []
    var unseenCount: Int { items.filter { !$0.seen }.count }

    /// A note is at most this long (the server checks it too).
    static let maxNote = 280
    /// Songs stay in the inbox this long.
    private static let keepFor: TimeInterval = 30 * 86_400

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var checking = false
    @ObservationIgnored private var notified = Set<String>()
    @ObservationIgnored private var firstCheck = true

    private init() {}

    /// Looks for new songs every 20 s while Drift is on screen, and every 30 s while it plays in the
    /// background (iOS keeps Drift running then; a new song arrives as a notification).
    func start() {
        guard loop == nil else { return }
        LocalNotifications.shared.setUp()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                let active = UIApplication.shared.applicationState == .active
                try? await Task.sleep(for: .seconds(active ? 20 : 30))
            }
        }
    }

    /// Friends you can send songs to: people you follow who follow you back and accept songs.
    var sendable: [UserProfile] {
        guard let me = SocialStore.shared.me?.id else { return [] }
        return SocialStore.shared.following.filter { $0.following.contains(me) && $0.acceptsSongs }
    }

    // MARK: Sending

    /// What travels with a sent song: what's needed to play it, nothing from your library.
    private func songOnly(_ t: Track) -> Track {
        var s = t
        s.added = nil
        s.addedBy = nil
        return s
    }

    /// Sends a song to these friends, with an optional note.
    func send(_ track: Track, to friends: [UserProfile], note: String) async throws {
        guard let me = SocialStore.shared.me else { throw JamSession.JamError.noProfile }
        let json = String(data: try JSONEncoder().encode(songOnly(track)), encoding: .utf8) ?? "{}"
        let text = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxNote))
        var failed: [String] = []
        var refused = false
        for f in friends {
            let ms = Int(Date().timeIntervalSince1970 * 1000)
            var fields: [String: Any] = [
                "from": FV.s(me.id), "fromName": FV.s(me.name), "track": FV.s(json), "at": FV.i(ms),
            ]
            if !text.isEmpty { fields["note"] = FV.s(text) }
            do {
                try await Firestore.patch("users/\(f.id)/inbox/\(me.id)_\(ms)", fields: fields, mustNotExist: true)
            } catch SocialError.server(403, _) {
                failed.append(f.name)
                refused = true
            } catch {
                failed.append(f.name)
            }
        }
        if !failed.isEmpty { throw SendError.notSent(failed, refused: refused) }
    }

    enum SendError: LocalizedError {
        case notSent([String], refused: Bool)
        var errorDescription: String? {
            switch self {
            case .notSent(let names, let refused):
                refused
                    ? "Couldn't send it to \(names.joined(separator: ", ")). They may have turned this off or stopped following you, or the security rules need updating."
                    : "Couldn't send it to \(names.joined(separator: ", ")). Check your connection and try again."
            }
        }
    }

    // MARK: Getting

    private func parse(_ d: [String: Any]) -> InboxItem? {
        guard let name = d["name"] as? String, let f = d["fields"] as? [String: Any],
              let from = FV.string(f, "from"), let raw = FV.string(f, "track"),
              let track = try? JSONDecoder().decode(Track.self, from: Data(raw.utf8)),
              !track.id.isEmpty, !track.title.isEmpty else { return nil }
        return InboxItem(
            id: String(name.split(separator: "/").last ?? ""),
            from: from,
            fromName: FV.string(f, "fromName") ?? "A friend",
            track: track,
            note: FV.string(f, "note") ?? "",
            at: Date(timeIntervalSince1970: Double(FV.int(f, "at") ?? 0) / 1000),
            seen: FV.bool(f, "seen") ?? false
        )
    }

    func check() async {
        guard !checking else { return }
        guard let me = SocialStore.shared.me else {
            if !items.isEmpty { items = [] }
            return
        }
        checking = true
        defer { checking = false }
        guard let docs = try? await Firestore.list("users/\(me.id)/inbox") else { return }
        var next: [InboxItem] = []
        for d in docs {
            guard let i = parse(d) else { continue }
            // Old ones are cleared.
            if Date().timeIntervalSince(i.at) > Self.keepFor {
                Task { try? await Firestore.delete("users/\(me.id)/inbox/\(i.id)") }
                continue
            }
            next.append(i)
        }
        next.sort { $0.at > $1.at }
        // A notification for each new one while Drift plays in the background (not for what was there before).
        let inBackground = UIApplication.shared.applicationState != .active
        for i in next where !notified.contains(i.id) {
            notified.insert(i.id)
            if !firstCheck && !i.seen && inBackground { LocalNotifications.shared.song(i) }
        }
        firstCheck = false
        if next != items { items = next }
    }

    /// Marks these as seen (on every device).
    func markSeen(_ ids: [String]) {
        guard let me = SocialStore.shared.me?.id else { return }
        let todo = items.filter { ids.contains($0.id) && !$0.seen }
        guard !todo.isEmpty else { return }
        items = items.map { var i = $0; if ids.contains(i.id) { i.seen = true }; return i }
        for i in todo {
            LocalNotifications.shared.clearSong(i.id)
            Task { try? await Firestore.patch("users/\(me)/inbox/\(i.id)", fields: ["seen": FV.b(true)], mask: ["seen"]) }
        }
    }

    /// Clears one from the inbox (on every device).
    func clear(_ item: InboxItem) {
        guard let me = SocialStore.shared.me?.id else { return }
        items.removeAll { $0.id == item.id }
        LocalNotifications.shared.clearSong(item.id)
        Task { try? await Firestore.delete("users/\(me)/inbox/\(item.id)") }
    }
}
