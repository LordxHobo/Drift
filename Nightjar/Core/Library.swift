import Foundation
import Observation

/// Playlists, liked songs, recently played and downloads, saved as JSON on the phone.
@Observable @MainActor
final class Library {
    static let shared = Library()

    private(set) var playlists: [Playlist] = []
    private(set) var liked: [Track] = []
    private(set) var recent: [Track] = []
    private(set) var downloaded: [Track] = []

    private struct Stored: Codable {
        var playlists: [Playlist]
        var liked: [Track]
        var recent: [Track]
        var downloaded: [Track]
    }

    @ObservationIgnored private let storeURL = URL.documentsDirectory.appending(path: "library.json")
    @ObservationIgnored let downloadsDirectory = URL.documentsDirectory.appending(path: "Downloads", directoryHint: .isDirectory)

    private init() {
        load()
        try? FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        // Drop download entries whose file is gone.
        downloaded.removeAll { !FileManager.default.fileExists(atPath: fileURL(for: $0.id).path) }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let s = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        playlists = s.playlists
        liked = s.liked
        recent = s.recent
        downloaded = s.downloaded
    }

    private func save() {
        let s = Stored(playlists: playlists, liked: liked, recent: recent, downloaded: downloaded)
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: Liked

    func isLiked(_ id: String) -> Bool { liked.contains { $0.id == id } }

    func toggleLike(_ t: Track) {
        if let i = liked.firstIndex(where: { $0.id == t.id }) {
            liked.remove(at: i)
        } else {
            liked.insert(t, at: 0)
        }
        save()
    }

    func removeLiked(at offsets: IndexSet) {
        liked.remove(atOffsets: offsets)
        save()
    }

    func moveLiked(from: IndexSet, to: Int) {
        liked.move(fromOffsets: from, toOffset: to)
        save()
    }

    // MARK: Playlists

    func playlist(_ id: UUID) -> Playlist? { playlists.first { $0.id == id } }

    @discardableResult
    func createPlaylist(_ name: String) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = Playlist(name: trimmed.isEmpty ? "My playlist #\(playlists.count + 1)" : trimmed,
                         colorIndex: playlists.count)
        playlists.append(p)
        save()
        return p
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = trimmed
        save()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        save()
    }

    func add(_ t: Track, to id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }),
              !playlists[i].tracks.contains(where: { $0.id == t.id }) else { return }
        playlists[i].tracks.append(t)
        save()
    }

    func removeTracks(at offsets: IndexSet, from id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].tracks.remove(atOffsets: offsets)
        save()
    }

    func moveTracks(from: IndexSet, to: Int, in id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].tracks.move(fromOffsets: from, toOffset: to)
        save()
    }

    // MARK: Recently played

    func addRecent(_ t: Track) {
        recent.removeAll { $0.id == t.id }
        recent.insert(t, at: 0)
        if recent.count > 30 { recent.removeLast(recent.count - 30) }
        save()
    }

    // MARK: Downloads

    func fileURL(for id: String) -> URL {
        downloadsDirectory.appending(path: "\(id).m4a")
    }

    func isDownloaded(_ id: String) -> Bool {
        downloaded.contains { $0.id == id }
    }

    func markDownloaded(_ t: Track) {
        guard !isDownloaded(t.id) else { return }
        downloaded.insert(t, at: 0)
        save()
    }

    func removeDownload(_ id: String) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
        downloaded.removeAll { $0.id == id }
        save()
    }

    func removeAllDownloads() {
        for t in downloaded { try? FileManager.default.removeItem(at: fileURL(for: t.id)) }
        downloaded.removeAll()
        save()
    }

    var downloadsSize: Int64 {
        downloaded.reduce(0) { sum, t in
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL(for: t.id).path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            return sum + size
        }
    }
}
