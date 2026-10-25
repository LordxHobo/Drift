import Foundation

/// Music videos often have intros, outros and edits. When a song is a music video and YouTube Music
/// has the album version of it, Drift plays that instead (same song, studio audio, real length).
actor AudioVersion {
    static let shared = AudioVersion()

    private let defaultsKey = "audioVersion.map.v2"
    /// Video ID → album-audio video ID ("" = it already is the album audio, or there is none).
    private var map: [String: String]
    private var pending: [String: Task<String?, Never>] = [:]

    private init() {
        map = (UserDefaults.standard.dictionary(forKey: "audioVersion.map.v2") as? [String: String]) ?? [:]
    }

    /// The ID to actually play for a song (the album version when there is one).
    func preferred(_ track: Track) async -> String {
        let id = track.id
        guard AppSettings.shared.preferOfficialAudio, !track.isEpisode else { return id }
        if let known = map[id] { return known.isEmpty ? id : known }
        if let task = pending[id] { return await task.value ?? id }
        let task = Task<String?, Never> {
            let answer: String?? = try? await withTimeout(4) { try await Self.lookup(track) }
            return answer ?? nil
        }
        pending[id] = task
        let result = await task.value
        pending[id] = nil
        // Only remember real answers; a failed or slow lookup is tried again next time.
        guard let result else { return id }
        map[id] = result == id ? "" : result
        if map.count > 5000 { map.removeAll() }
        UserDefaults.standard.set(map, forKey: defaultsKey)
        return result
    }

    private static let atv = "MUSIC_VIDEO_TYPE_ATV"

    /// 1. YouTube Music's own link between a music video and its album version.
    /// 2. Otherwise, a "songs" search for the same title and artist, keeping only album audio.
    private static func lookup(_ track: Track) async throws -> String? {
        let id = track.id
        var ownType: String?
        if let json = try? await YTMusic.post("next", [
            "videoId": id,
            "playlistId": "RDAMVM\(id)",
            "isAudioOnly": true,
            "enablePersistentPlaylistPanel": true,
            "watchEndpointMusicSupportedConfigs": ["watchEndpointMusicConfig": [
                "hasPersistentPlaylistPanel": true, "musicVideoType": atv,
            ]],
        ]), let first = firstQueueItem(json) {
            var candidates: [[String: Any]] = []
            collect(first, into: &candidates)
            let types = candidates.map { ($0["videoId"] as? String, videoType($0)) }
            ownType = types.first(where: { $0.0 == id })?.1
            if ownType == atv { return id }
            if let other = types.first(where: { $0.1 == atv && $0.0 != nil && $0.0 != id })?.0 { return other }
        }

        // Search for the album version.
        let artist = LyricsService.mainArtist(track.artist)
        guard !track.title.isEmpty else { return ownType == nil ? nil : id }
        let json = try await YTMusic.post("search", ["query": "\(track.title) \(artist)",
                                                     "params": "EgWKAQIIAWoMEA4QChADEAQQCRAF"])
        let wantTitle = SongMatcher.normalize(track.title)
        let wantArtist = SongMatcher.normalize(artist)
        var best: (id: String, diff: Double)?
        YTMusic.collect(json) { r in
            guard let t = YTMusic.parse(r, requireDuration: false), firstValue(r, "musicVideoType") as? String == atv,
                  SongMatcher.normalize(t.title) == wantTitle,
                  wantArtist.isEmpty || SongMatcher.normalize(t.artist).contains(wantArtist) else { return }
            if t.id == id { best = (id, -1); return }
            let diff = (track.duration != nil && t.duration != nil) ? abs(track.duration! - t.duration!) : 5
            guard diff <= 6 else { return }
            if best == nil || diff < best!.diff { best = (t.id, diff) }
        }
        return best?.id ?? id
    }

    private static func firstValue(_ node: Any, _ key: String) -> Any? {
        if let d = node as? [String: Any] {
            if let v = d[key] { return v }
            for k in d.keys.sorted() { if let v = firstValue(d[k]!, key) { return v } }
        } else if let a = node as? [Any] {
            for v in a { if let found = firstValue(v, key) { return found } }
        }
        return nil
    }

    private static func firstQueueItem(_ json: Any) -> Any? {
        var found: Any?
        walk(json) { d in
            guard found == nil, let panel = d["playlistPanelRenderer"] as? [String: Any],
                  let contents = panel["contents"] as? [Any] else { return }
            found = contents.first
        }
        return found
    }

    private static func walk(_ node: Any, _ visit: ([String: Any]) -> Void) {
        if let d = node as? [String: Any] {
            visit(d)
            for k in d.keys.sorted() { walk(d[k]!, visit) }
        } else if let a = node as? [Any] {
            for v in a { walk(v, visit) }
        }
    }

    private static func collect(_ node: Any, into out: inout [[String: Any]]) {
        if let d = node as? [String: Any] {
            if let r = d["playlistPanelVideoRenderer"] as? [String: Any] { out.append(r) }
            for k in d.keys.sorted() where k != "playlistPanelVideoRenderer" { collect(d[k]!, into: &out) }
        } else if let a = node as? [Any] {
            for v in a { collect(v, into: &out) }
        }
    }

    private static func videoType(_ r: [String: Any]) -> String? {
        let config = ((((r["navigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?[
            "watchEndpointMusicSupportedConfigs"] as? [String: Any])?["watchEndpointMusicConfig"] as? [String: Any])
        return config?["musicVideoType"] as? String
    }
}
