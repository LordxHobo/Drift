import Foundation

/// Community-marked non-music parts of music videos (intros, outros, talking).
enum SponsorBlock {
    static func segments(for videoID: String) async -> [ClosedRange<Double>] {
        guard let url = URL(string: "https://sponsor.ajay.app/api/skipSegments?videoID=\(videoID)&category=music_offtopic"),
              let result = try? await URLSession.shared.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return [] }

        struct Segment: Decodable { let segment: [Double] }
        let segments = (try? JSONDecoder().decode([Segment].self, from: result.0)) ?? []
        return segments.compactMap { s in
            guard s.segment.count == 2, s.segment[1] - s.segment[0] >= 1 else { return nil }
            return s.segment[0]...s.segment[1]
        }
    }
}
