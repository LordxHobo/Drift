import Foundation
import Observation

/// An artist you follow, with the releases already seen (anything else that shows up later is new).
struct FollowedArtist: Codable, Hashable, Identifiable {
    var artist: ArtistRef
    var followedAt: Date
    var known: Set<String>
    var newReleases: [NewRelease] = []

    var id: String { artist.id }
}

struct NewRelease: Codable, Hashable, Identifiable {
    var album: AlbumRef
    var artistName: String
    var foundAt: Date

    var id: String { album.id }
}

/// Followed artists, saved on the phone. New singles and albums are looked for when Drift opens.
@Observable @MainActor
final class ArtistStore {
    static let shared = ArtistStore()

    private(set) var followed: [FollowedArtist] = []

    /// How long a release counts as new.
    static let newFor: TimeInterval = 30 * 86400

    @ObservationIgnored private let url = URL.documentsDirectory.appending(path: "artists.json")
    @ObservationIgnored private let lastCheckKey = "artists.lastCheck"
    @ObservationIgnored private var checking = false

    private init() {
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([FollowedArtist].self, from: data) {
            followed = list
        }
        prune()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(followed) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.newFor)
        for i in followed.indices {
            followed[i].newReleases.removeAll { $0.foundAt < cutoff }
        }
    }

    // MARK: Following

    func isFollowing(_ id: String) -> Bool { followed.contains { $0.id == id } }

    func follow(_ artist: ArtistRef, page: ArtistPage?) {
        guard !isFollowing(artist.id) else { return }
        let ids = Set(((page?.albums ?? []) + (page?.singles ?? [])).map(\.id))
        let ref = ArtistRef(id: artist.id, name: page?.name ?? artist.name, thumbnail: page?.thumbnail ?? artist.thumbnail)
        followed.insert(FollowedArtist(artist: ref, followedAt: Date(), known: ids), at: 0)
        save()
    }

    func unfollow(_ id: String) {
        followed.removeAll { $0.id == id }
        save()
    }

    func newReleases(of id: String) -> [NewRelease] {
        followed.first { $0.id == id }?.newReleases ?? []
    }

    /// Every new release from artists you follow, newest first.
    var allNewReleases: [NewRelease] {
        followed.flatMap(\.newReleases).sorted { $0.foundAt > $1.foundAt }
    }

    // MARK: Looking for new releases

    /// Compares a freshly loaded artist page with what was seen before.
    @discardableResult
    func update(_ artistID: String, with page: ArtistPage, notify: Bool = true) -> [NewRelease] {
        guard let i = followed.firstIndex(where: { $0.id == artistID }) else { return [] }
        var found: [NewRelease] = []
        let releases = page.albums + page.singles
        if followed[i].known.isEmpty {
            // First look (followed before the page had loaded): nothing counts as new yet.
            followed[i].known = Set(releases.map(\.id))
        } else {
            for r in releases where !followed[i].known.contains(r.id) {
                followed[i].known.insert(r.id)
                let n = NewRelease(album: r, artistName: page.name, foundAt: Date())
                followed[i].newReleases.insert(n, at: 0)
                found.append(n)
            }
        }
        if let thumb = page.thumbnail {
            followed[i].artist = ArtistRef(id: artistID, name: page.name, thumbnail: thumb)
        }
        save()
        if notify { Self.notify(found) }
        return found
    }

    /// One notification for everything found in one go.
    private static func notify(_ found: [NewRelease]) {
        guard let first = found.first else { return }
        var artists: [String] = []
        for n in found where !artists.contains(n.artistName) { artists.append(n.artistName) }
        let title = found.count == 1
            ? "New from \(first.artistName)"
            : "\(found.count) new releases"
        let detail = found.count == 1
            ? first.album.title
            : artists.prefix(3).joined(separator: ", ") + (artists.count > 3 ? " and more" : "")
        NotificationStore.shared.post(AppNotification(kind: .newReleases, title: title, detail: detail, releases: found))
    }

    /// Checks every followed artist, at most every few hours unless forced.
    func check(force: Bool = false) async {
        guard !checking, !followed.isEmpty else { return }
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(last) > 3 * 3600 else { return }
        checking = true
        defer { checking = false }
        prune()

        var found: [NewRelease] = []
        let artists = followed.map(\.artist)
        // A few at a time so it stays light.
        for start in stride(from: 0, to: artists.count, by: 4) {
            let batch = Array(artists[start..<min(start + 4, artists.count)])
            let pages = await withTaskGroup(of: (String, ArtistPage?).self) { group in
                for a in batch {
                    group.addTask { (a.id, try? await Artists.page(a)) }
                }
                var out: [(String, ArtistPage?)] = []
                for await r in group { out.append(r) }
                return out
            }
            for (id, page) in pages {
                if let page { found += update(id, with: page, notify: false) }
            }
        }
        Self.notify(found)
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        save()
    }
}
