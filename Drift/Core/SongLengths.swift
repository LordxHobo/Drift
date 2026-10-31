import Foundation

/// The exact length of songs, as YouTube gave it when they were streamed or downloaded. Songs played from
/// a download or the song cache use it to end on time: iOS often reads these files as minutes longer
/// than they are, and plays silence for the difference.
@MainActor
enum SongLengths {
    private static let url = AppFiles.data.appending(path: "song-lengths.json")
    private static var lengths: [String: Double] = {
        guard let data = try? Data(contentsOf: url),
              let d = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return d
    }()
    private static var saveTask: Task<Void, Never>?

    static func exact(_ id: String) -> Double? { lengths[id] }

    static func remember(_ id: String, _ seconds: Double?) {
        guard let seconds, seconds.isFinite, seconds > 1, lengths[id] != seconds else { return }
        lengths[id] = seconds
        guard saveTask == nil else { return }
        saveTask = Task {
            try? await Task.sleep(for: .seconds(5))
            saveTask = nil
            let snapshot = lengths
            let target = url
            Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: target, options: .atomic) }
            }
        }
    }
}
