import Foundation
import Observation

/// Downloads songs for offline playback, one at a time.
@Observable @MainActor
final class DownloadManager {
    static let shared = DownloadManager()

    /// Active and queued downloads, 0...1.
    private(set) var progress: [String: Double] = [:]
    private(set) var failed: Set<String> = []

    @ObservationIgnored private var queue: [Track] = []
    @ObservationIgnored private var running = false

    private init() {}

    func isActive(_ id: String) -> Bool { progress[id] != nil }

    func download(_ t: Track) {
        guard !Library.shared.isDownloaded(t.id), progress[t.id] == nil else { return }
        failed.remove(t.id)
        progress[t.id] = 0
        queue.append(t)
        pump()
    }

    func download(_ tracks: [Track]) {
        tracks.forEach { download($0) }
    }

    func cancelAll() {
        for t in queue { progress[t.id] = nil }
        queue.removeAll()
    }

    private func pump() {
        guard !running, !queue.isEmpty else { return }
        running = true
        let t = queue.removeFirst()
        Task {
            do {
                do {
                    try await fetch(t)
                } catch {
                    // Link may have stopped working: get a fresh one and try once more.
                    let playID = await AudioVersion.shared.preferred(t)
                    await StreamResolver.shared.invalidate(playID)
                    try await fetch(t)
                }
                Library.shared.markDownloaded(t)
            } catch {
                failed.insert(t.id)
            }
            progress[t.id] = nil
            running = false
            pump()
        }
    }

    private func fetch(_ t: Track) async throws {
        // Downloads always use the best stream.
        let playID = await AudioVersion.shared.preferred(t)
        let stream = try await StreamResolver.shared.resolve(playID, dataSaver: false)

        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = AppSettings.shared.downloadOverCellular
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let tmp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".m4a")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        var closed = false
        defer {
            if !closed { try? handle.close() }
            try? FileManager.default.removeItem(at: tmp)
        }

        // YouTube throttles big single requests, so fetch in ranged chunks.
        let chunk = 3_000_000
        var offset = 0
        var total: Int?
        while true {
            try Task.checkCancellation()
            var req = URLRequest(url: stream.url)
            req.setValue("bytes=\(offset)-\(offset + chunk - 1)", forHTTPHeaderField: "Range")
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            if total == nil, let range = http.value(forHTTPHeaderField: "Content-Range"),
               let slash = range.lastIndex(of: "/") {
                total = Int(range[range.index(after: slash)...])
            }
            try handle.write(contentsOf: data)
            offset += data.count
            if let total, total > 0 { progress[t.id] = min(Double(offset) / Double(total), 1) }

            let done = http.statusCode == 200 || data.isEmpty || data.count < chunk
                || (total.map { offset >= $0 } ?? false)
            if done { break }
        }
        try handle.close()
        closed = true
        guard offset > 10_000 else { throw URLError(.zeroByteResource) }

        let dest = Library.shared.fileURL(for: t.id)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
}
