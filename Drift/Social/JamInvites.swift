import Foundation
import Observation
import UIKit

/// An invite to listen together, from a friend.
struct JamInvite: Identifiable, Equatable {
    var id: String { "\(from)|\(code)|\(Int(at.timeIntervalSince1970))" }
    let from: String
    let fromName: String
    let code: String
    let title: String
    let artist: String
    let at: Date
}

/// Listen Together invites: sending them (from a song's menu) and getting them (a popup to join or not).
/// Each invite is a small document at users/{them}/invites/{you}; the server only accepts it when you
/// follow each other and they allow invites. The computer does the same.
@Observable @MainActor
final class JamInvites {
    static let shared = JamInvites()

    /// The invite being asked about (shown as a popup above everything, see InviteOverlay).
    @ObservationIgnored private(set) var incoming: JamInvite? {
        didSet {
            if let incoming { InviteOverlay.shared.ask(incoming) } else if oldValue != nil { InviteOverlay.shared.hide() }
        }
    }

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var asked = Set<String>()
    @ObservationIgnored private var checking = false
    /// Invites found while Drift was in the background (told with a notification), by id.
    @ObservationIgnored private var waiting: [String: JamInvite] = [:]

    /// Invites older than this are cleared without asking.
    private static let maxAge: TimeInterval = 15 * 60

    private init() {}

    /// Looks for invites every 10 s while Drift is on screen, and every 20 s while it plays in the
    /// background (iOS keeps Drift running then; the invite arrives as a notification).
    func start() {
        guard loop == nil else { return }
        LocalNotifications.shared.setUp()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                let active = UIApplication.shared.applicationState == .active
                try? await Task.sleep(for: .seconds(active ? 10 : 20))
            }
        }
    }

    /// Friends you can invite: people you follow who follow you back and accept invites.
    var invitable: [UserProfile] {
        guard let me = SocialStore.shared.me?.id else { return [] }
        return SocialStore.shared.following.filter { $0.following.contains(me) && $0.acceptsInvites }
    }

    // MARK: Sending

    /// Plays the song and invites these friends to listen to it together (starting a session if needed).
    func invite(_ friends: [UserProfile], to track: Track) async throws {
        guard let me = SocialStore.shared.me else { throw JamSession.JamError.noProfile }
        Player.shared.play([track], from: "Listening together")
        if JamSession.shared.state == nil { try await JamSession.shared.start() }
        guard let code = JamSession.shared.state?.code else { throw JamSession.JamError.failed }
        var failed: [String] = []
        var refused = false
        for f in friends {
            let fields: [String: Any] = [
                "from": FV.s(me.id), "fromName": FV.s(me.name), "code": FV.s(code),
                "title": FV.s(track.title), "artist": FV.s(track.artist),
                "at": FV.i(Int(Date().timeIntervalSince1970 * 1000)),
            ]
            do {
                try await Firestore.patch("users/\(f.id)/invites/\(me.id)", fields: fields)
            } catch SocialError.server(403, _) {
                failed.append(f.name)
                refused = true
            } catch {
                failed.append(f.name)
            }
        }
        if !failed.isEmpty { throw InviteError.notSent(failed, refused: refused) }
    }

    enum InviteError: LocalizedError {
        case notSent([String], refused: Bool)
        var errorDescription: String? {
            switch self {
            case .notSent(let names, let refused):
                refused
                    ? "Drift's server refused the invite to \(names.joined(separator: ", ")). They may have turned invites off or stopped following you, or the security rules need updating."
                    : "Couldn't invite \(names.joined(separator: ", ")). Check your connection and try again."
            }
        }
    }

    // MARK: Getting

    func check() async {
        guard !checking, incoming == nil, let me = SocialStore.shared.me, me.acceptsInvites else { return }
        checking = true
        defer { checking = false }
        guard let docs = try? await Firestore.list("users/\(me.id)/invites") else { return }
        let inBackground = UIApplication.shared.applicationState != .active
        for d in docs {
            guard let f = d["fields"] as? [String: Any], let from = FV.string(f, "from"),
                  let code = FV.string(f, "code") else { continue }
            let at = Date(timeIntervalSince1970: Double(FV.int(f, "at") ?? 0) / 1000)
            let invite = JamInvite(from: from, fromName: FV.string(f, "fromName") ?? "A friend", code: code,
                                   title: FV.string(f, "title") ?? "", artist: FV.string(f, "artist") ?? "", at: at)
            // Old, already in that session, or already asked about: cleared quietly.
            if Date().timeIntervalSince(at) > Self.maxAge || JamSession.shared.state?.code == code || asked.contains(invite.id) {
                remove(invite, me: me.id)
                continue
            }
            asked.insert(invite.id)
            if inBackground {
                // Drift isn't on screen: a notification (Join / Decline right on it).
                waiting[invite.id] = invite
                LocalNotifications.shared.invite(invite)
            } else if incoming == nil {
                incoming = invite
            }
        }
    }

    /// Drift came back on screen: ask about an invite that arrived meanwhile (if it's still fresh).
    func appBecameActive() {
        if incoming == nil, let invite = waiting.values.sorted(by: { $0.at > $1.at }).first,
           Date().timeIntervalSince(invite.at) < Self.maxAge {
            waiting[invite.id] = nil
            LocalNotifications.shared.clear(invite)
            incoming = invite
        }
        Task { await check() }
    }

    /// The invite a notification is about (answered from the notification).
    func waitingInvite(_ id: String) -> JamInvite? { waiting[id] }

    func accept(_ invite: JamInvite) async {
        incoming = nil
        waiting[invite.id] = nil
        LocalNotifications.shared.clear(invite)
        if let me = SocialStore.shared.me?.id { remove(invite, me: me) }
        do {
            try await JamSession.shared.join(invite.code)
        } catch {
            InviteOverlay.shared.tell("Couldn't join", error.localizedDescription)
        }
    }

    func decline(_ invite: JamInvite) {
        incoming = nil
        waiting[invite.id] = nil
        LocalNotifications.shared.clear(invite)
        if let me = SocialStore.shared.me?.id { remove(invite, me: me) }
    }

    private func remove(_ invite: JamInvite, me: String) {
        Task { try? await Firestore.delete("users/\(me)/invites/\(invite.from)") }
    }
}
