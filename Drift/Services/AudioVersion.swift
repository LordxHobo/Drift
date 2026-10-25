import Foundation

/// Music videos often have intros, outros and edits. When a song is a music video and YouTube Music
/// has the album version of it, Drift plays that instead (same song, studio audio, real length).
actor AudioVersion {
    static let shared = AudioVersion()

    private let defaultsKey = "audioVersion.map"
    /// Video ID → album-audio video ID ("" = it already is the album audio, or there is none).
    private var map: [String: String]
    private var pending: [String: Task<String?, Never>] = [:]

    private init() {
        map = (UserDefaults.standard.dictionary(forKey: "audioVersion.map") as? [String: String]) ?? [:]
    }

    /// The ID to actually play for a song (the album version when there is one).
    func preferred(_ id: String) async -> String {
        guard AppSettings.shared.preferOfficialAudio else { return id }
        if let known = map[id] { return known.isEmpty ? id : known }
        if let task = pending[id] { return await task.value ?? id }
        let task = Task<String?, Never> {
            let answer: String?? = try? await withTimeout(2.5) { try await Self.lookup(id) }
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

    /// Asks YouTube Music for the audio-only version of the video.
    private static func lookup(_ id: String) async throws -> String? {
        let json = try await YTMusic.post("next", ["videoId": id, "isAudioOnly": true])
        // The first queue entry is this song; with a music video it lists the album version beside it.
        guard let first = firstQueueItem(json) else { return nil }
        var candidates: [[String: Any]] = []
        collect(first, into: &candidates)
        let types = candidates.map { ($0["videoId"] as? String, videoType($0)) }
        // Already the album audio (or YouTube has no album version): keep it.
        if let own = types.first(where: { $0.0 == id }), own.1 == "MUSIC_VIDEO_TYPE_ATV" { return id }
        return types.first(where: { $0.1 == "MUSIC_VIDEO_TYPE_ATV" && $0.0 != nil })?.0 ?? id
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
