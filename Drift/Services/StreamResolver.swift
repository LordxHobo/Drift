import Foundation
import YouTubeKit

struct ResolvedStream {
    let url: URL
    let label: String   // e.g. "AAC · 128 kbps"
}

struct TimeoutError: Error {}

enum StreamError: LocalizedError {
    case noAudio
    var errorDescription: String? { "No playable audio stream for this song." }
}

/// Turns a video ID into a direct audio URL, extracted on the phone with YouTubeKit.
actor StreamResolver {
    static let shared = StreamResolver()

    private var cache: [String: (ResolvedStream, Date)] = [:]
    /// Videos whose quick link didn't work: always use the full extraction for these.
    private var quickFailed: Set<String> = []
    private var visitorData: String?
    private var warmUpTask: Task<Void, Never>?

    /// Called at launch: get a YouTube visitor ID so even the first song gets a proper link.
    func warmUp() {
        guard visitorData == nil, warmUpTask == nil else { return }
        warmUpTask = Task {
            // Any public video works; YouTube's very first upload.
            if let r = try? await withTimeout(5, { try await Self.quickResolve("jNQXAC9IVRw", dataSaver: true, visitorData: nil) }) {
                self.setVisitor(r.visitorData)
            }
        }
    }

    private func setVisitor(_ v: String?) {
        if let v { visitorData = v }
    }

    func resolve(_ videoID: String, dataSaver: Bool) async throws -> ResolvedStream {
        let key = videoID + (dataSaver ? "#low" : "#best")
        if let entry = cache[key], entry.1 > Date() { return entry.0 }
        if visitorData == nil {
            warmUp()
            await warmUpTask?.value
        }

        // Quick path: one request, no web page or decoding (about 0.3 s instead of 1.5–2 s).
        if !quickFailed.contains(videoID),
           let quick = try? await withTimeout(4, { [visitorData] in
               try await Self.quickResolve(videoID, dataSaver: dataSaver, visitorData: visitorData)
           }) {
            if let v = quick.visitorData { visitorData = v }
            cache[key] = (quick.stream, Date().addingTimeInterval(3 * 3600))
            return quick.stream
        }

        // Full extraction; YouTubeKit's remote fallback if YouTube changed something.
        let streams = try await YouTube(videoID: videoID, methods: [.local, .remote]).streams

        // AVPlayer can't play WebM/Opus, so stick to M4A (AAC) audio-only streams.
        let audio = streams.filterAudioOnly().filter { $0.fileExtension == .m4a && $0.isNativelyPlayable }
        let picked: YouTubeKit.Stream?
        if dataSaver {
            picked = audio.min { ($0.bitrate ?? .max) < ($1.bitrate ?? .max) }
        } else {
            picked = audio.highestAudioBitrateStream()
                ?? audio.max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
        }
        // Last resort: a combined audio+video stream (plays fine, audio only is used).
        guard let stream = picked
                ?? streams.filter({ $0.includesAudioTrack && $0.isNativelyPlayable }).highestAudioBitrateStream()
        else { throw StreamError.noAudio }

        let kbps = (stream.averageBitrate ?? stream.bitrate ?? 0) / 1000
        let label = kbps > 0 ? "AAC · \(kbps) kbps" : "AAC"
        let resolved = ResolvedStream(url: stream.url, label: label)
        // Stream URLs expire after ~6 hours; refresh well before that.
        cache[key] = (resolved, Date().addingTimeInterval(3 * 3600))
        return resolved
    }

    /// Plain-language reason for a failed load.
    nonisolated static func describe(_ error: Error, episode: Bool) -> String {
        switch error as? YouTubeKitError {
        case .videoUnavailable?: return "This video isn't available. It may be a premiere that hasn't started yet."
        case .liveStreamError?: return "Live streams can't be played."
        case .videoAgeRestricted?: return "Age-restricted videos can't be played."
        case .videoPrivate?: return "This video is private."
        case .membersOnly?: return "This video is for channel members only."
        case .videoRegionBlocked?: return "This video isn't available in your country."
        default: break
        }
        if error is StreamError { return "YouTube didn't offer audio the iPhone can play." }
        if let e = error as? URLError, e.code == .notConnectedToInternet { return "No internet connection." }
        if error is TimeoutError { return "The audio didn't start in time." }
        return episode ? "Couldn't load this episode." : "Couldn't load this song."
    }

    // MARK: Quick path

    private struct QuickResult: Sendable {
        let stream: ResolvedStream
        let visitorData: String?
    }

    /// YouTube's visionOS client hands out direct audio links without the web page or signature
    /// decoding (yt-dlp uses it the same way).
    private static func quickResolve(_ videoID: String, dataSaver: Bool, visitorData: String?) async throws -> QuickResult {
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        var req = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 4
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("101", forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue("1.02", forHTTPHeaderField: "X-YouTube-Client-Version")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        if let visitorData { req.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        var client: [String: Any] = [
            "clientName": "VISIONOS", "clientVersion": "1.02",
            "deviceMake": "Apple", "deviceModel": "RealityDevice17,1",
            "osName": "visionOS", "osVersion": "26.5.23O471",
            "userAgent": ua, "hl": "en", "gl": "US",
        ]
        if let visitorData { client["visitorData"] = visitorData }
        let body: [String: Any] = ["context": ["client": client], "videoId": videoID,
                                   "contentCheckOk": true, "racyCheckOk": true]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        let status = (json["playabilityStatus"] as? [String: Any])?["status"] as? String
        guard status == "OK",
              let details = json["videoDetails"] as? [String: Any],
              (details["videoId"] as? String) == videoID,
              let formats = (json["streamingData"] as? [String: Any])?["adaptiveFormats"] as? [[String: Any]]
        else { throw StreamError.noAudio }

        // Direct-link AAC audio in the original language (no dubbed tracks).
        let audio = formats.filter { f in
            guard let mime = f["mimeType"] as? String, mime.hasPrefix("audio/mp4"),
                  f["url"] is String else { return false }
            if let track = f["audioTrack"] as? [String: Any], (track["audioIsDefault"] as? Bool) == false { return false }
            return true
        }
        func rate(_ f: [String: Any]) -> Int {
            (f["averageBitrate"] as? Int) ?? (f["bitrate"] as? Int) ?? 0
        }
        guard let pick = dataSaver ? audio.min(by: { rate($0) < rate($1) }) : audio.max(by: { rate($0) < rate($1) }),
              let s = pick["url"] as? String, let url = URL(string: s) else { throw StreamError.noAudio }
        let kbps = rate(pick) / 1000
        let visitor = (json["responseContext"] as? [String: Any])?["visitorData"] as? String
        return QuickResult(stream: ResolvedStream(url: url, label: kbps > 0 ? "AAC · \(kbps) kbps" : "AAC"),
                           visitorData: visitor)
    }

    func invalidate(_ videoID: String) {
        // A link that failed to play: next time use the full extraction for this video.
        quickFailed.insert(videoID)
        cache[videoID + "#low"] = nil
        cache[videoID + "#best"] = nil
    }
}
