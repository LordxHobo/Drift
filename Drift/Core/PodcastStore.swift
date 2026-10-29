import Foundation
import Observation

/// Followed shows (YouTube channels, or shows with their own feed), their latest episodes and where each episode was left off.
/// Saved separately from the music library in podcasts.json.
@Observable @MainActor
final class PodcastStore {
    static let shared = PodcastStore()

    private(set) var subscriptions: [PodcastChannel] = []
    private(set) var progress: [String: EpisodeProgress] = [:]
    private(set) var feeds: [String: [Track]] = [:]
    private(set) var refreshing = false
    private(set) var loadingChannels: Set<String> = []

    @ObservationIgnored private var feedsUpdated: Date?
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private let fileURL = URL.documentsDirectory.appending(path: "podcasts.json")

    private struct Stored: Codable {
        var subscriptions: [PodcastChannel]?
        var progress: [String: EpisodeProgress]?
        var feeds: [String: [Track]]?
        var feedsUpdated: Date?
    }

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let s = try? JSONDecoder().decode(Stored.self, from: data) {
            subscriptions = s.subscriptions ?? []
            progress = s.progress ?? [:]
            feeds = s.feeds ?? [:]
            feedsUpdated = s.feedsUpdated
        }
    }

    private func save() {
        let s = Stored(subscriptions: subscriptions, progress: progress, feeds: feeds, feedsUpdated: feedsUpdated)
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: fileURL, options: .atomic)
        lastSave = Date()
        dirty = false
    }

    /// Writes pending progress now (when the app goes to the background).
    func flush() {
        if dirty { save() }
    }

    // MARK: Following

    func isFollowing(_ channelID: String?) -> Bool {
        guard let channelID else { return false }
        return subscriptions.contains { $0.id == channelID }
    }

    func follow(_ c: PodcastChannel) {
        guard !isFollowing(c.id) else { return }
        subscriptions.append(c)
        save()
        Task { await loadChannel(c) }
    }

    /// Follow the channel an episode is from.
    func follow(from t: Track) {
        guard let c = channel(for: t) else { return }
        follow(c)
    }

    func unfollow(_ channelID: String) {
        subscriptions.removeAll { $0.id == channelID }
        save()
    }

    func toggleFollow(_ c: PodcastChannel) {
        if isFollowing(c.id) { unfollow(c.id) } else { follow(c) }
    }

    func channel(for t: Track) -> PodcastChannel? {
        guard let id = t.channelID else { return nil }
        if let c = subscriptions.first(where: { $0.id == id }) { return c }
        // A feed episode whose feed isn't known: nothing to open or follow.
        if t.isFeedEpisode && t.feedURL == nil { return nil }
        return PodcastChannel(id: id, name: t.artist, avatarURL: t.channelAvatar, feedURL: t.feedURL)
    }

    /// A show's episodes: from its feed, or the YouTube channel's uploads.
    nonisolated static func fetchEpisodes(_ c: PodcastChannel) async throws -> [Track] {
        if c.isFeed { return try await PodcastFeeds.episodes(c) }
        return try await YouTubeSearch.channelEpisodes(c)
    }

    /// A show opened from a pasted feed link: its episodes are already here.
    func showLoaded(_ c: PodcastChannel, episodes: [Track]) {
        guard !episodes.isEmpty else { return }
        feeds[c.id] = episodes
    }

    // MARK: Episodes

    /// Newest episodes from every followed channel.
    var newEpisodes: [Track] {
        let all = subscriptions.flatMap { feeds[$0.id] ?? [] }
        return Array(all.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }.prefix(60))
    }

    var continueListening: [EpisodeProgress] {
        Array(progress.values
            .filter { !$0.finished && $0.position >= 30 }
            .sorted { $0.updated > $1.updated }
            .prefix(10))
    }

    func refresh(force: Bool) async {
        guard !refreshing, !subscriptions.isEmpty else { return }
        if !force, let u = feedsUpdated, Date().timeIntervalSince(u) < 30 * 60 { return }
        refreshing = true
        defer { refreshing = false }
        let subs = subscriptions
        let results = await withTaskGroup(of: (String, [Track]?).self) { group in
            for c in subs {
                group.addTask { (c.id, try? await PodcastStore.fetchEpisodes(c)) }
            }
            var out: [(String, [Track]?)] = []
            for await r in group { out.append(r) }
            return out
        }
        for (id, eps) in results {
            if let eps, !eps.isEmpty { feeds[id] = eps }
        }
        feedsUpdated = Date()
        save()
    }

    /// Loads one channel's episodes (channel page, or right after following).
    func loadChannel(_ c: PodcastChannel) async {
        guard !loadingChannels.contains(c.id) else { return }
        loadingChannels.insert(c.id)
        defer { loadingChannels.remove(c.id) }
        if let eps = try? await Self.fetchEpisodes(c), !eps.isEmpty {
            feeds[c.id] = eps
            if isFollowing(c.id) { save() }
        }
    }

    // MARK: Progress

    func fraction(_ id: String) -> Double? {
        guard let p = progress[id], !p.finished, p.duration > 0, p.position >= 30 else { return nil }
        return min(p.position / p.duration, 1)
    }

    func isFinished(_ id: String) -> Bool { progress[id]?.finished == true }

    func remaining(_ id: String) -> Double? {
        guard let p = progress[id], !p.finished, p.duration > 0, p.position >= 30 else { return nil }
        return max(p.duration - p.position, 0)
    }

    /// Where to start an episode: a few seconds before where it was left.
    func resumePosition(_ id: String) -> Double {
        guard let p = progress[id], !p.finished, p.position >= 30 else { return 0 }
        return max(p.position - 3, 0)
    }

    func update(_ t: Track, position: Double, duration: Double, force: Bool = false) {
        guard position.isFinite, duration.isFinite, duration > 0 else { return }
        let finished = duration - position < 30
        progress[t.id] = EpisodeProgress(track: t, position: position, duration: duration,
                                         updated: Date(), finished: finished)
        dirty = true
        if force || Date().timeIntervalSince(lastSave) > 15 { save() }
    }

    func markFinished(_ t: Track) {
        let d = progress[t.id]?.duration ?? t.duration ?? 0
        progress[t.id] = EpisodeProgress(track: t, position: d, duration: d, updated: Date(), finished: true)
        save()
    }

    func markUnplayed(_ id: String) {
        progress[id] = nil
        save()
    }
}
