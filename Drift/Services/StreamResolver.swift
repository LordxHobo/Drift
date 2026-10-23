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

    func resolve(_ videoID: String, dataSaver: Bool) async throws -> ResolvedStream {
        let key = videoID + (dataSaver ? "#low" : "#best")
        if let entry = cache[key], entry.1 > Date() { return entry.0 }

        // Local extraction first; YouTubeKit's remote fallback if YouTube changed something.
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

    func invalidate(_ videoID: String) {
        cache[videoID + "#low"] = nil
        cache[videoID + "#best"] = nil
    }
}
