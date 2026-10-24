import Foundation
import Observation
import UIKit

/// A Drift profile as others see it.
struct UserProfile: Codable, Hashable, Identifiable {
    var id: String              // Firebase user ID
    var username: String        // lowercase, unique
    var avatar: Data?           // small JPEG
    var following: [String]
    var shareActivity: Bool
    var nowPlaying: Track?
    var playing: Bool
    var updatedAt: Date?

    init(id: String, username: String, avatar: Data?, following: [String] = [], shareActivity: Bool = true,
         nowPlaying: Track? = nil, playing: Bool = false, updatedAt: Date? = nil) {
        self.id = id
        self.username = username
        self.avatar = avatar
        self.following = following
        self.shareActivity = shareActivity
        self.nowPlaying = nowPlaying
        self.playing = playing
        self.updatedAt = updatedAt
    }

    init?(document d: [String: Any]) {
        guard let name = d["name"] as? String, let f = d["fields"] as? [String: Any],
              let username = FV.string(f, "username") else { return nil }
        id = String(name.split(separator: "/").last ?? "")
        self.username = username
        avatar = FV.data(f, "avatar")
        following = FV.stringArray(f, "following")
        shareActivity = FV.bool(f, "shareActivity") ?? true
        playing = FV.bool(f, "playing") ?? false
        updatedAt = FV.int(f, "updatedAt").map { Date(timeIntervalSince1970: TimeInterval($0)) }
        if let np = FV.mapFields(f, "nowPlaying"), let tid = FV.string(np, "id"), let title = FV.string(np, "title") {
            nowPlaying = Track(id: tid, title: title, artist: FV.string(np, "artist") ?? "", album: nil,
                               duration: FV.int(np, "duration").map(Double.init),
                               artworkURL: FV.string(np, "artwork").flatMap(URL.init(string:)),
                               podcast: FV.bool(np, "podcast"))
        } else {
            nowPlaying = nil
        }
    }

    /// Playing right now (recent update while playing), not just the last thing they played.
    var isListeningNow: Bool {
        guard playing, nowPlaying != nil, let updatedAt else { return false }
        let allowance = (nowPlaying?.duration ?? 0) + 15 * 60
        return Date().timeIntervalSince(updatedAt) < allowance
    }

    var activityText: String? {
        guard nowPlaying != nil else { return nil }
        if isListeningNow { return "Listening now" }
        guard let updatedAt else { return nil }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: updatedAt, relativeTo: Date())
    }
}

/// Profiles, following and sharing what you listen to, stored in Firebase.
@Observable @MainActor
final class SocialStore {
    static let shared = SocialStore()

    enum Status: Equatable {
        case loading, noProfile, ready
    }

    private(set) var status: Status = .loading
    private(set) var me: UserProfile?
    private(set) var following: [UserProfile] = []
    private(set) var followers: [UserProfile] = []
    private(set) var loadingFriends = false
    var showOnboarding = false
    /// Hide activity just for now (resets when Drift restarts).
    var privateSession = false {
        didSet { playerChanged() }
    }

    @ObservationIgnored private let cacheKey = "social.me"
    @ObservationIgnored private let skippedKey = "social.skippedOnboarding"
    @ObservationIgnored private var publishTask: Task<Void, Never>?
    @ObservationIgnored private var lastPublished: String?

    static let usernameRule = "3–20 characters: letters, numbers, . and _"

    private init() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode(UserProfile.self, from: data) {
            me = cached
            status = .ready
        }
        Task { await bootstrap() }
    }

    private func cache() {
        if let me, let data = try? JSONEncoder().encode(me) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        } else {
            UserDefaults.standard.removeObject(forKey: cacheKey)
        }
    }

    private var skippedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: skippedKey) }
        set { UserDefaults.standard.set(newValue, forKey: skippedKey) }
    }

    /// First launch: no account → offer to create a profile. Reinstall: restore the profile.
    private func bootstrap() async {
        guard let uid = await FirebaseAuth.shared.currentUID() else {
            status = .noProfile
            showOnboarding = !skippedOnboarding
            return
        }
        do {
            if let doc = try await Firestore.get("users/\(uid)"), let profile = UserProfile(document: doc) {
                me = profile
                status = .ready
                cache()
                PlaylistSharing.shared.profileReady()
            } else {
                me = nil
                status = .noProfile
                cache()
                showOnboarding = !skippedOnboarding
            }
        } catch SocialError.sessionLost {
            await FirebaseAuth.shared.forget()
            me = nil
            status = .noProfile
            cache()
            showOnboarding = !skippedOnboarding
        } catch {
            // Offline: keep the cached profile; try again later.
            if me == nil { status = .noProfile }
        }
    }

    func skipOnboarding() {
        skippedOnboarding = true
        showOnboarding = false
    }

    // MARK: Usernames

    static func cleaned(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_.")
        return String(s.lowercased().filter { allowed.contains($0) })
    }

    static func validate(_ name: String) -> String? {
        if name.count < 3 { return "At least 3 characters" }
        if name.count > 20 { return "At most 20 characters" }
        if name.hasPrefix(".") || name.hasSuffix(".") { return "Can't start or end with a dot" }
        return nil
    }

    /// nil = couldn't check (offline / server).
    func isAvailable(_ name: String) async -> Bool? {
        do {
            guard let doc = try await Firestore.get("usernames/\(name)") else { return true }
            let owner = FV.string(doc["fields"] as? [String: Any], "uid")
            let me = await FirebaseAuth.shared.currentUID()
            return owner != nil && owner == me
        } catch {
            return nil
        }
    }

    // MARK: Profile

    func createProfile(username: String, photo: UIImage?) async throws {
        let uid = try await FirebaseAuth.shared.signedInUID()
        try await Firestore.patch("usernames/\(username)", fields: ["uid": FV.s(uid)], mustNotExist: true)
        let avatar = photo.flatMap(Self.avatarData)
        let profile = UserProfile(id: uid, username: username, avatar: avatar)
        try await Firestore.patch("users/\(uid)", fields: Self.fields(profile))
        me = profile
        status = .ready
        showOnboarding = false
        cache()
        playerChanged()
        PlaylistSharing.shared.profileReady()
    }

    func changeUsername(_ newName: String) async throws {
        guard var profile = me, newName != profile.username else { return }
        try await Firestore.patch("usernames/\(newName)", fields: ["uid": FV.s(profile.id)], mustNotExist: true)
        try await Firestore.patch("users/\(profile.id)",
                                  fields: ["username": FV.s(newName), "usernameLower": FV.s(newName)],
                                  mask: ["username", "usernameLower"])
        try? await Firestore.delete("usernames/\(profile.username)")
        profile.username = newName
        me = profile
        cache()
    }

    func setPhoto(_ image: UIImage?) async throws {
        guard var profile = me else { return }
        let data = image.flatMap(Self.avatarData)
        try await Firestore.patch("users/\(profile.id)", fields: ["avatar": data.map(FV.bytes) ?? FV.null],
                                  mask: ["avatar"])
        profile.avatar = data
        me = profile
        cache()
    }

    func setShareActivity(_ on: Bool) async {
        guard var profile = me else { return }
        profile.shareActivity = on
        me = profile
        cache()
        try? await Firestore.patch("users/\(profile.id)", fields: ["shareActivity": FV.b(on)], mask: ["shareActivity"])
        lastPublished = nil
        playerChanged()
    }

    func deleteProfile() async throws {
        guard let profile = me else { return }
        await PlaylistSharing.shared.removeAll(uid: profile.id)
        try await Firestore.delete("users/\(profile.id)")
        try? await Firestore.delete("usernames/\(profile.username)")
        await FirebaseAuth.shared.forget()
        me = nil
        following = []
        followers = []
        status = .noProfile
        skippedOnboarding = true
        cache()
    }

    private static func avatarData(_ image: UIImage) -> Data? {
        let side = min(image.size.width, image.size.height)
        guard side > 0 else { return nil }
        let target = CGSize(width: 160, height: 160)
        let scale = target.width / side
        let draw = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let out = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(x: (target.width - draw.width) / 2, y: (target.height - draw.height) / 2,
                                  width: draw.width, height: draw.height))
        }
        return out.jpegData(compressionQuality: 0.7)
    }

    private static func fields(_ p: UserProfile) -> [String: Any] {
        [
            "username": FV.s(p.username),
            "usernameLower": FV.s(p.username),
            "avatar": p.avatar.map(FV.bytes) ?? FV.null,
            "following": FV.strings(p.following),
            "shareActivity": FV.b(p.shareActivity),
            "nowPlaying": FV.null,
            "playing": FV.b(false),
            "updatedAt": FV.i(Int(Date().timeIntervalSince1970)),
        ]
    }

    // MARK: Following

    func isFollowing(_ id: String) -> Bool { me?.following.contains(id) ?? false }

    func follow(_ user: UserProfile) async {
        guard var profile = me, user.id != profile.id, !profile.following.contains(user.id) else { return }
        profile.following.append(user.id)
        await saveFollowing(profile)
        if !following.contains(where: { $0.id == user.id }) { following.insert(user, at: 0) }
    }

    func unfollow(_ id: String) async {
        guard var profile = me else { return }
        profile.following.removeAll { $0 == id }
        await saveFollowing(profile)
        following.removeAll { $0.id == id }
    }

    private func saveFollowing(_ profile: UserProfile) async {
        let previous = me
        me = profile
        cache()
        do {
            try await Firestore.patch("users/\(profile.id)", fields: ["following": FV.strings(profile.following)],
                                      mask: ["following"])
        } catch {
            me = previous
            cache()
        }
    }

    /// Everyone you follow, with what they're playing.
    func refreshFollowing() async {
        guard let profile = me else { return }
        loadingFriends = true
        defer { loadingFriends = false }
        guard let docs = try? await Firestore.batchGet(profile.following.map { "users/\($0)" }) else { return }
        let users = docs.compactMap(UserProfile.init(document:))
        // Listening now first, then most recent.
        following = users.sorted {
            if $0.isListeningNow != $1.isListeningNow { return $0.isListeningNow }
            return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
    }

    func loadFollowers() async {
        guard let profile = me else { return }
        followers = await Self.followers(of: profile.id)
    }

    static func followers(of id: String) async -> [UserProfile] {
        let q: [String: Any] = [
            "from": [["collectionId": "users"]],
            "where": ["fieldFilter": [
                "field": ["fieldPath": "following"], "op": "ARRAY_CONTAINS", "value": FV.s(id),
            ]],
            "limit": 200,
        ]
        let docs = (try? await Firestore.query(q)) ?? []
        return docs.compactMap(UserProfile.init(document:))
    }

    func user(_ id: String) async -> UserProfile? {
        guard let doc = try? await Firestore.get("users/\(id)") else { return nil }
        return UserProfile(document: doc)
    }

    func users(_ ids: [String]) async -> [UserProfile] {
        let docs = (try? await Firestore.batchGet(ids.map { "users/\($0)" })) ?? []
        return docs.compactMap(UserProfile.init(document:))
    }

    /// Usernames starting with what was typed.
    func search(_ text: String) async -> [UserProfile] {
        let q = Self.cleaned(text)
        guard !q.isEmpty else { return [] }
        let query: [String: Any] = [
            "from": [["collectionId": "users"]],
            "where": ["compositeFilter": ["op": "AND", "filters": [
                ["fieldFilter": ["field": ["fieldPath": "usernameLower"], "op": "GREATER_THAN_OR_EQUAL",
                                 "value": FV.s(q)]],
                ["fieldFilter": ["field": ["fieldPath": "usernameLower"], "op": "LESS_THAN",
                                 "value": FV.s(q + "\u{f8ff}")]],
            ]]],
            "orderBy": [["field": ["fieldPath": "usernameLower"]]],
            "limit": 20,
        ]
        let docs = (try? await Firestore.query(query)) ?? []
        return docs.compactMap(UserProfile.init(document:)).filter { $0.id != me?.id }
    }

    // MARK: Sharing what's playing

    /// Called by the player on every song change and play/pause; sends it (a moment later, once) to friends.
    func playerChanged() {
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.publish()
        }
    }

    private func publish() async {
        guard var profile = me else { return }
        let player = Player.shared
        let hidden = !profile.shareActivity || privateSession
        let track = hidden ? nil : player.current
        let playing = !hidden && player.isPlaying
        let signature = "\(track?.id ?? "-")|\(playing)"
        guard signature != lastPublished else { return }

        var fields: [String: Any] = ["playing": FV.b(playing), "updatedAt": FV.i(Int(Date().timeIntervalSince1970))]
        var mask = ["playing", "updatedAt"]
        if hidden {
            fields["nowPlaying"] = FV.null
            mask.append("nowPlaying")
        } else if let t = track {
            var np: [String: Any] = ["id": FV.s(t.id), "title": FV.s(t.title), "artist": FV.s(t.artist),
                                     "podcast": FV.b(t.isEpisode)]
            if let a = t.artworkURL?.absoluteString ?? t.artwork(size: 300)?.absoluteString { np["artwork"] = FV.s(a) }
            if let d = t.duration { np["duration"] = FV.i(Int(d)) }
            fields["nowPlaying"] = FV.map(np)
            mask.append("nowPlaying")
        }
        do {
            try await Firestore.patch("users/\(profile.id)", fields: fields, mask: mask)
            lastPublished = signature
            profile.nowPlaying = hidden ? nil : (track ?? profile.nowPlaying)
            profile.playing = playing
            profile.updatedAt = Date()
            me = profile
        } catch {}
    }
}
