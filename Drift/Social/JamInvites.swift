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

    /// The invite being asked about (shown as a popup).
    var incoming: JamInvite?
    /// Why joining didn't work (shown once).
    var failure: String?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var asked = Set<String>()
    @ObservationIgnored private var checking = false

    /// Invites older than this are cleared without asking.
    private static let maxAge: TimeInterval = 15 * 60

    private init() {}

    /// Looks for invites every 20 s while Drift is open.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated { Task { await JamInvites.shared.check() } }
        }
        Task { await check() }
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
        for f in friends {
            let fields: [String: Any] = [
                "from": FV.s(me.id), "fromName": FV.s(me.username), "code": FV.s(code),
                "title": FV.s(track.title), "artist": FV.s(track.artist),
                "at": FV.i(Int(Date().timeIntervalSince1970 * 1000)),
            ]
            do {
                try await Firestore.patch("users/\(f.id)/invites/\(me.id)", fields: fields)
            } catch {
                failed.append(f.username)
            }
        }
        if !failed.isEmpty { throw InviteError.notSent(failed) }
    }

    enum InviteError: LocalizedError {
        case notSent([String])
        var errorDescription: String? {
            switch self {
            case .notSent(let names):
                "Couldn't invite \(names.joined(separator: ", ")). They may have turned invites off or stopped following you."
            }
        }
    }

    // MARK: Getting

    func check() async {
        guard !checking, incoming == nil, UIApplication.shared.applicationState == .active,
              let me = SocialStore.shared.me, me.acceptsInvites,
              let docs = try? await Firestore.list("users/\(me.id)/invites") else { return }
        checking = true
        defer { checking = false }
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
            if incoming == nil {
                asked.insert(invite.id)
                incoming = invite
            }
        }
    }

    func accept(_ invite: JamInvite) async {
        incoming = nil
        if let me = SocialStore.shared.me?.id { remove(invite, me: me) }
        do {
            try await JamSession.shared.join(invite.code)
        } catch {
            failure = error.localizedDescription
        }
    }

    func decline(_ invite: JamInvite) {
        incoming = nil
        if let me = SocialStore.shared.me?.id { remove(invite, me: me) }
    }

    private func remove(_ invite: JamInvite, me: String) {
        Task { try? await Firestore.delete("users/\(me)/invites/\(invite.from)") }
    }
}
