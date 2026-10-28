import Foundation

/// Music videos often have intros, outros and edits. When a song is a music video and YouTube Music
/// has the album version of it, Drift plays that instead (same song, studio audio, real length).
/// And when the version about to play is clean (censored), Drift plays the explicit one instead.
actor AudioVersion {
    static let shared = AudioVersion()

    /// One remembered list per combination of the two settings.
    private var mode = ""
    private var defaultsKey: String { "audioVersion.map.v3.\(mode)" }
    /// Video ID → video ID to play ("" = play it as it is).
    private var map: [String: String] = [:]
    private var pending: [String: Task<String?, Never>] = [:]
    /// What the last lookup found, per song (shown in the player's stream info).
    private var notes: [String: String] = [:]

    func note(_ id: String) -> String { notes[id] ?? "Not looked up" }

    private init() {}

    private func use(mode new: String) {
        guard new != mode else { return }
        mode = new
        map = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        notes.removeAll()
    }

    /// The ID to actually play for a song (the album and/or explicit version when there is one).
    func preferred(_ track: Track) async -> String {
        let id = track.id
        if track.chosen == true {
            notes[id] = "Picked with “Replace with another version”"
            return id
        }
        if track.upload == true {
            notes[id] = "YouTube upload (not on YouTube Music)"
            return id
        }
        let official = AppSettings.shared.preferOfficialAudio
        let explicit = AppSettings.shared.preferExplicit
        guard official || explicit, !track.isEpisode else {
            notes[id] = "Off (official audio and explicit versions are off)"
            return id
        }
        use(mode: (official ? "album" : "") + (explicit ? "explicit" : ""))
        if let known = map[id] {
            if notes[id] == nil { notes[id] = known.isEmpty ? "Remembered: keep this one" : "Remembered: other version" }
            return known.isEmpty ? id : known
        }
        if let task = pending[id] { return await task.value ?? id }
        let task = Task<String?, Never> {
            let answer: (String, String)?? = try? await withTimeout(7) {
                try await Self.choose(track, official: official, explicit: explicit)
            }
            guard let pair = answer ?? nil else { return nil }
            await self.setNote(id, pair.1)
            return pair.0
        }
        pending[id] = task
        let result = await task.value
        pending[id] = nil
        // Only remember real answers; a failed or slow lookup is tried again next time.
        guard let result else {
            notes[id] = "Lookup failed or timed out"
            return id
        }
        map[id] = result == id ? "" : result
        if map.count > 5000 { map.removeAll() }
        UserDefaults.standard.set(map, forKey: defaultsKey)
        return result
    }

    private func setNote(_ id: String, _ text: String) { notes[id] = text }

    private static let atv = "MUSIC_VIDEO_TYPE_ATV"
    private static let songsParams = "EgWKAQIIAWoMEA4QChADEAQQCRAF"

    /// Which video IDs are explicit, as learned along the way.
    private final class Known: @unchecked Sendable {
        var explicit: [String: Bool] = [:]
    }

    /// The album version (if wanted), then its explicit version (if wanted and it's clean).
    private static func choose(_ track: Track, official: Bool, explicit: Bool) async throws -> (String, String)? {
        let known = Known()
        var play = track.id
        var note = "Album versions off"
        if official {
            guard let found = try await lookup(track, known) else { return nil }
            (play, note) = found
        }
        if explicit {
            if let other = try? await explicitVersion(track, playing: play, known, onlySongs: !official) {
                play = other
                note += "; explicit version found (this one was clean)"
            } else if known.explicit[play] == true || track.explicit == true {
                note += "; explicit"
            }
        }
        return (play, note)
    }

    /// The explicit version of a song when the one about to play is clean.
    /// `onlySongs`: leave music videos alone (official audio is off).
    private static func explicitVersion(_ track: Track, playing playID: String, _ known: Known, onlySongs: Bool) async throws -> String? {
        if known.explicit[playID] == true || track.explicit == true { return nil }
        let title = YTMusic.withoutCleanTag(track.title)
        guard !title.isEmpty else { return nil }
        let json = try await YTMusic.post("search", ["query": "\(title) \(LyricsService.mainArtist(track.artist))",
                                                     "params": songsParams])
        var rows: [(t: Track, song: Bool)] = []
        YTMusic.collect(json) { r in
            guard let t = YTMusic.parse(r, requireDuration: false) else { return }
            known.explicit[t.id] = t.explicit == true
            rows.append((t, firstValue(r, "musicVideoType") as? String == atv))
        }
        if known.explicit[playID] == true { return nil }
        if onlySongs, !rows.contains(where: { $0.t.id == track.id && $0.song }) { return nil }
        // Compare lengths with what was going to play (the album version can be shorter than a music video).
        var ref = track
        ref.title = title
        ref.duration = rows.first(where: { $0.t.id == playID })?.t.duration ?? (playID == track.id ? track.duration : nil)
        var best: (id: String, diff: Double)?
        for (t, song) in rows where song && t.explicit == true && t.id != playID && YTMusic.sameSong(ref, t) {
            let diff = (ref.duration != nil && t.duration != nil) ? abs(ref.duration! - t.duration!) : 5
            if best == nil || diff < best!.diff { best = (t.id, diff) }
        }
        return best?.id
    }

    /// 1. YouTube Music's own link between a music video and its album version.
    /// 2. Otherwise, a "songs" search for the same title and artist, keeping only album audio.
    private static func lookup(_ track: Track, _ known: Known) async throws -> (String, String)? {
        let id = track.id
        var ownType: String?
        var linkNote = "YouTube Music link: no answer"
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
            for c in candidates { if let v = c["videoId"] as? String { known.explicit[v] = YTMusic.isExplicit(c) } }
            let types = candidates.map { ($0["videoId"] as? String, videoType($0)) }
            ownType = types.first(where: { $0.0 == id })?.1
            let short = (ownType ?? "unknown").replacingOccurrences(of: "MUSIC_VIDEO_TYPE_", with: "")
            if ownType == atv { return (id, "Already album audio (ATV)") }
            if let other = types.first(where: { $0.1 == atv && $0.0 != nil && $0.0 != id })?.0 {
                return (other, "Album version via YouTube Music link (this video: \(short))")
            }
            linkNote = "YouTube Music link: none (this video: \(short), \(types.count) entries)"
        }

        // Search for the album version.
        let artist = LyricsService.mainArtist(track.artist)
        guard !track.title.isEmpty else { return ownType == nil ? nil : (id, linkNote) }
        let json = try await YTMusic.post("search", ["query": "\(track.title) \(artist)",
                                                     "params": "EgWKAQIIAWoMEA4QChADEAQQCRAF"])
        let wantTitle = SongMatcher.normalize(track.title)
        let wantArtist = SongMatcher.normalize(artist)
        var best: (id: String, diff: Double)?
        YTMusic.collect(json) { r in
            if let t = YTMusic.parse(r, requireDuration: false) { known.explicit[t.id] = t.explicit == true }
            guard let t = YTMusic.parse(r, requireDuration: false), firstValue(r, "musicVideoType") as? String == atv,
                  SongMatcher.normalize(t.title) == wantTitle,
                  wantArtist.isEmpty || SongMatcher.normalize(t.artist).contains(wantArtist) else { return }
            if t.id == id { best = (id, -1); return }
            let diff = (track.duration != nil && t.duration != nil) ? abs(track.duration! - t.duration!) : 5
            guard diff <= 6 else { return }
            if best == nil || diff < best!.diff { best = (t.id, diff) }
        }
        if let b = best {
            return b.id == id ? (id, "\(linkNote); search: this is the album version")
                              : (b.id, "\(linkNote); album version found by search")
        }
        return (id, "\(linkNote); search: no album version matched")
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
