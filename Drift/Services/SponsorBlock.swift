import Foundation

/// A part of a video the community marked as skippable.
struct SkipSegment: Equatable {
    let range: ClosedRange<Double>
    let category: String

    func label(atStart: Bool, atEnd: Bool) -> String {
        switch category {
        case "sponsor": return "sponsor"
        case "selfpromo": return "self-promotion"
        case "interaction": return "subscribe reminder"
        default: return atStart ? "non-music intro" : (atEnd ? "non-music outro" : "non-music part")
        }
    }
}

/// SponsorBlock: music_offtopic for songs (intros, outros, talking), sponsor reads etc. for podcasts.
enum SponsorBlock {
    static let musicCategories = ["music_offtopic"]
    static let podcastCategories = ["sponsor", "selfpromo", "interaction"]

    static func segments(for videoID: String, categories: [String]) async -> [SkipSegment] {
        var c = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments")!
        c.queryItems = [URLQueryItem(name: "videoID", value: videoID)]
            + categories.map { URLQueryItem(name: "category", value: $0) }
        guard let url = c.url,
              let result = try? await URLSession.shared.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return [] }

        struct Segment: Decodable {
            let segment: [Double]
            let category: String?
        }
        let segments = (try? JSONDecoder().decode([Segment].self, from: result.0)) ?? []
        return segments.compactMap { s in
            guard s.segment.count == 2, s.segment[1] - s.segment[0] >= 1 else { return nil }
            return SkipSegment(range: s.segment[0]...s.segment[1], category: s.category ?? categories.first ?? "")
        }
        .sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}
