import Foundation
import UIKit
import Observation

/// Playlists, liked songs, recently played and downloads, saved as JSON on the phone.
@Observable @MainActor
final class Library {
    static let shared = Library()

    private(set) var playlists: [Playlist] = []
    private(set) var liked: [Track] = []
    private(set) var recent: [Track] = []
    private(set) var downloaded: [Track] = []
    private(set) var folders: [PlaylistFolder] = []

    private struct Stored: Codable {
        var playlists: [Playlist]
        var liked: [Track]
        var recent: [Track]
        var downloaded: [Track]
        /// Optional so libraries saved by older builds still load.
        var folders: [PlaylistFolder]?
    }

    @ObservationIgnored private let storeURL = AppFiles.data.appending(path: "library.json")
    @ObservationIgnored let downloadsDirectory = AppFiles.downloads
    /// Downloaded songs are named "Artist - Title.m4a" (they show in the Files app): song id → file name.
    @ObservationIgnored private let namesURL = AppFiles.data.appending(path: "download-names.json")
    @ObservationIgnored private var fileNames: [String: String] = [:]

    private init() {
        load()
        try? FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: namesURL), let names = try? JSONDecoder().decode([String: String].self, from: data) {
            fileNames = names
        }
        nameOldDownloads()
        // Drop download entries whose file is gone (deleted or renamed in the Files app, say).
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
        folders = s.folders ?? []
    }

    private func save() {
        let s = Stored(playlists: playlists, liked: liked, recent: recent, downloaded: downloaded, folders: folders)
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: storeURL, options: .atomic)
        PlaylistSharing.shared.libraryChanged()
        LibrarySync.shared.localChanged()
        CollabSync.shared.libraryChanged()
    }

    // MARK: Collaborative playlists (CollabSync)

    /// A collaborative playlist as the server has it now (added at the top of the list when new).
    func setCollabPlaylist(_ p: Playlist) {
        if let i = playlists.firstIndex(where: { $0.id == p.id }) {
            playlists[i].name = p.name
            playlists[i].tracks = p.tracks
            playlists[i].collab = p.collab
        } else {
            playlists.insert(p, at: 0)
        }
        save()
    }

    /// A collaborative playlist's cover as someone else set it (colour, symbol or photo).
    func setCollabCover(_ id: UUID, style: Playlist.CoverStyle, symbol: String?, colorIndex: Int, photo: Data?) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].colorIndex = colorIndex
        playlists[i].coverSymbol = symbol
        if style == .photo, let photo {
            try? FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
            let file = "\(id.uuidString)-collab-\(Int(Date().timeIntervalSince1970)).jpg"
            if (try? photo.write(to: coversDirectory.appending(path: file), options: .atomic)) != nil {
                if let old = playlists[i].coverFile, old != file {
                    try? FileManager.default.removeItem(at: coversDirectory.appending(path: old))
                    coverCache[old] = nil
                }
                playlists[i].coverFile = file
            }
        }
        playlists[i].coverStyle = style == .photo && playlists[i].coverFile == nil ? .auto : style
        save()
    }

    /// Marks a playlist as collaborative (or not, with nil).
    func setCollabInfo(_ id: UUID, _ info: CollabInfo?) {
        guard let i = playlists.firstIndex(where: { $0.id == id }), playlists[i].collab != info else { return }
        playlists[i].collab = info
        save()
    }

    // MARK: Changes from your other devices (library sync)

    func replaceLiked(_ tracks: [Track]) {
        liked = tracks
        save()
    }

    /// Adds or updates a playlist that came from another device, in the given position.
    func applyRemotePlaylist(_ p: Playlist, cover: Data?, position: Int) {
        var p = p
        if p.style == .photo, let cover {
            try? FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
            let file = "\(p.id.uuidString)-sync-\(cover.count).jpg"
            if (try? cover.write(to: coversDirectory.appending(path: file), options: .atomic)) != nil {
                if let old = playlist(p.id)?.coverFile, old != file {
                    try? FileManager.default.removeItem(at: coversDirectory.appending(path: old))
                    coverCache[old] = nil
                }
                p.coverFile = file
            }
        } else if p.style == .photo {
            p.coverFile = playlist(p.id)?.coverFile
            if p.coverFile == nil { p.coverStyle = .auto }
        } else {
            p.coverFile = nil
        }
        if let i = playlists.firstIndex(where: { $0.id == p.id }) {
            playlists[i] = p
        } else {
            playlists.insert(p, at: min(max(position, 0), playlists.count))
        }
        save()
    }

    /// The photo cover of a playlist as JPEG (sent to your other devices).
    func coverData(_ p: Playlist) -> Data? {
        guard p.style == .photo, let file = p.coverFile else { return nil }
        return try? Data(contentsOf: coversDirectory.appending(path: file))
    }

    // MARK: Liked

    func isLiked(_ id: String) -> Bool { liked.contains { $0.id == id } }

    func toggleLike(_ t: Track) {
        if let i = liked.firstIndex(where: { $0.id == t.id }) {
            liked.remove(at: i)
        } else {
            liked.insert(Self.dated(t), at: 0)
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

    /// New playlist with songs already in it (used by the Spotify import).
    @discardableResult
    func createPlaylist(_ name: String, tracks: [Track]) -> Playlist {
        var p = createPlaylist(name)
        guard let i = playlists.firstIndex(where: { $0.id == p.id }) else { return p }
        playlists[i].tracks = tracks.map { Self.dated($0, keep: true) }
        p = playlists[i]
        save()
        return p
    }

    /// An album saved to the library (kept as a playlist, listed under Albums).
    @discardableResult
    func saveAlbum(_ title: String, artist: String, tracks: [Track]) -> Playlist {
        var p = createPlaylist(title, tracks: tracks)
        if let i = playlists.firstIndex(where: { $0.id == p.id }) {
            playlists[i].isAlbum = true
            playlists[i].albumArtist = artist
            p = playlists[i]
            save()
        }
        return p
    }

    /// Every song in your playlists and liked songs, once each, A–Z.
    var allSongs: [Track] {
        var seen = Set<String>()
        return (liked + playlists.flatMap(\.tracks))
            .filter { !$0.isEpisode && seen.insert($0.id).inserted }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Adds songs to the end of a playlist, skipping ones already in it (big imports save as they go).
    /// A song as it goes into a list, dated now (`keep`: imports keep a date they already carry).
    static func dated(_ t: Track, keep: Bool = false) -> Track {
        var t = t
        if !keep || t.added == nil { t.added = Date() }
        return t
    }

    func appendTracks(_ tracks: [Track], to id: UUID) {
        guard !tracks.isEmpty, let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        var seen = Set(playlists[i].tracks.map(\.id))
        playlists[i].tracks += tracks.filter { seen.insert($0.id).inserted }.map { Self.dated($0, keep: true) }
        save()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = trimmed
        save()
    }

    func deletePlaylist(_ id: UUID) {
        if let file = playlist(id)?.coverFile { try? FileManager.default.removeItem(at: coversDirectory.appending(path: file)) }
        playlists.removeAll { $0.id == id }
        save()
    }

    // MARK: Folders

    func folder(_ id: UUID) -> PlaylistFolder? { folders.first { $0.id == id } }

    /// Playlists in a folder (nil: the ones not in any folder).
    func playlists(in folder: UUID?) -> [Playlist] {
        let known = Set(folders.map(\.id))
        return playlists.filter { p in
            guard let f = p.folder, known.contains(f) else { return folder == nil }
            return f == folder
        }
    }

    @discardableResult
    func createFolder(_ name: String) -> PlaylistFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = PlaylistFolder(name: trimmed.isEmpty ? "New folder" : trimmed)
        folders.append(f)
        save()
        return f
    }

    func renameFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].name = trimmed
        save()
    }

    /// Deletes a folder. Its playlists stay in Your Library, outside any folder.
    func deleteFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        for i in playlists.indices where playlists[i].folder == id { playlists[i].folder = nil }
        save()
    }

    /// Puts a playlist in a folder (nil: takes it out).
    func move(_ playlist: UUID, toFolder folder: UUID?) {
        guard let i = playlists.firstIndex(where: { $0.id == playlist }), playlists[i].folder != folder else { return }
        playlists[i].folder = folder
        save()
    }

    /// Folders from your other devices (library sync).
    func replaceFolders(_ list: [PlaylistFolder]) {
        folders = list
        save()
    }

    // MARK: Playlist covers

    @ObservationIgnored let coversDirectory = AppFiles.data.appending(path: "Covers", directoryHint: .isDirectory)
    @ObservationIgnored private var coverCache: [String: UIImage] = [:]

    /// The custom photo for a playlist, if it uses one.
    func coverImage(_ p: Playlist) -> UIImage? {
        guard p.style == .photo, let file = p.coverFile else { return nil }
        if let cached = coverCache[file] { return cached }
        guard let image = UIImage(contentsOfFile: coversDirectory.appending(path: file).path) else { return nil }
        coverCache[file] = image
        return image
    }

    /// Saves name and cover in one go. `photo` replaces the custom photo when given.
    func updatePlaylist(_ id: UUID, name: String, style: Playlist.CoverStyle, colorIndex: Int,
                        symbol: String, photo: UIImage?, isPublic: Bool) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].isPublic = isPublic
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { playlists[i].name = trimmed }
        playlists[i].colorIndex = colorIndex
        playlists[i].coverSymbol = symbol

        if let photo, let data = Self.squareJPEG(photo) {
            try? FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
            // New file name every time so every screen picks up the new photo.
            let file = "\(id.uuidString)-\(Int(Date().timeIntervalSince1970)).jpg"
            if (try? data.write(to: coversDirectory.appending(path: file), options: .atomic)) != nil {
                if let old = playlists[i].coverFile {
                    try? FileManager.default.removeItem(at: coversDirectory.appending(path: old))
                    coverCache[old] = nil
                }
                playlists[i].coverFile = file
            }
        }
        if style == .photo && playlists[i].coverFile == nil {
            playlists[i].coverStyle = .auto
        } else {
            playlists[i].coverStyle = style
        }
        // Drop a photo that's no longer used.
        if playlists[i].coverStyle != .photo, let old = playlists[i].coverFile {
            try? FileManager.default.removeItem(at: coversDirectory.appending(path: old))
            coverCache[old] = nil
            playlists[i].coverFile = nil
        }
        save()
    }

    /// Center-cropped 600×600 JPEG.
    private static func squareJPEG(_ image: UIImage) -> Data? {
        let side = min(image.size.width, image.size.height)
        guard side > 0 else { return nil }
        let target = CGSize(width: 600, height: 600)
        let scale = target.width / side
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let out = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(x: (target.width - drawSize.width) / 2, y: (target.height - drawSize.height) / 2,
                                  width: drawSize.width, height: drawSize.height))
        }
        return out.jpegData(compressionQuality: 0.85)
    }

    func add(_ t: Track, to id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }),
              !playlists[i].tracks.contains(where: { $0.id == t.id }) else { return }
        playlists[i].tracks.append(Self.dated(t))
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

    /// Swaps a song for another version, in the same spot. A song that was downloaded gets
    /// the new version downloaded too.
    func replace(_ old: Track, with new: Track, in place: SongPlace) {
        switch place {
        case .liked:
            guard let i = liked.firstIndex(where: { $0.id == old.id }) else { return }
            var new = new
            new.added = liked[i].added
            if liked.contains(where: { $0.id == new.id }) { liked.remove(at: i) } else { liked[i] = new }
        case .playlist(let id):
            guard let p = playlists.firstIndex(where: { $0.id == id }),
                  let i = playlists[p].tracks.firstIndex(where: { $0.id == old.id }) else { return }
            if playlists[p].tracks.contains(where: { $0.id == new.id }) {
                playlists[p].tracks.remove(at: i)
            } else {
                var new = new
                new.added = playlists[p].tracks[i].added
                playlists[p].tracks[i] = new
            }
        }
        save()
        if isDownloaded(old.id) { DownloadManager.shared.download(new) }
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
        if let name = fileNames[id] { return downloadsDirectory.appending(path: name) }
        return legacyFileURL(for: id)
    }

    /// How older builds named downloads (by song id).
    private func legacyFileURL(for id: String) -> URL {
        // Feed episodes keep their file's own type (usually MP3).
        if id.hasPrefix("rss-") {
            let m4a = downloadsDirectory.appending(path: "\(id).m4a")
            return FileManager.default.fileExists(atPath: m4a.path) ? m4a : downloadsDirectory.appending(path: "\(id).mp3")
        }
        return downloadsDirectory.appending(path: "\(id).m4a")
    }

    /// Where a download goes: "Artist - Title.m4a" (feed episodes keep their file's type, usually MP3).
    func downloadDestination(for t: Track, source: URL) -> URL {
        let ext = t.id.hasPrefix("rss-") && !["m4a", "mp4", "aac", "m4b"].contains(source.pathExtension.lowercased()) ? "mp3" : "m4a"
        let name = uniqueFileName(for: t, ext: ext)
        fileNames[t.id] = name
        saveNames()
        return downloadsDirectory.appending(path: name)
    }

    private func uniqueFileName(for t: Track, ext: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        func clean(_ s: String) -> String {
            s.components(separatedBy: bad).joined(separator: " ")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        }
        let artist = clean(t.artist), title = clean(t.title)
        var base = artist.isEmpty ? title : "\(artist) - \(title)"
        if base.isEmpty { base = t.id }
        base = String(base.prefix(120))
        let taken = Set(fileNames.filter { $0.key != t.id }.values.map { $0.lowercased() })
        var name = "\(base).\(ext)"
        if taken.contains(name.lowercased()) { name = "\(base) [\(t.id)].\(ext)" }
        return name
    }

    private func saveNames() {
        if let data = try? JSONEncoder().encode(fileNames) { try? data.write(to: namesURL, options: .atomic) }
    }

    /// Downloads from older builds (named by song id) get their song's name.
    private func nameOldDownloads() {
        let fm = FileManager.default
        for t in downloaded where fileNames[t.id] == nil {
            let old = legacyFileURL(for: t.id)
            guard fm.fileExists(atPath: old.path) else { continue }
            let name = uniqueFileName(for: t, ext: old.pathExtension.isEmpty ? "m4a" : old.pathExtension)
            if (try? fm.moveItem(at: old, to: downloadsDirectory.appending(path: name))) != nil {
                fileNames[t.id] = name
            }
        }
        saveNames()
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
        fileNames[id] = nil
        saveNames()
        save()
    }

    func removeAllDownloads() {
        for t in downloaded { try? FileManager.default.removeItem(at: fileURL(for: t.id)) }
        downloaded.removeAll()
        fileNames = [:]
        saveNames()
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
