import Foundation

/// Songs kept after you've listened to them, so playing them again starts instantly and uses no data.
/// While a song streams, the audio that arrives is also written to a file; once the whole song is in
/// (it played through, or the gaps were filled in after it ended), the file is kept. The least recently
/// played songs go first when the cache is over its size limit (Settings › Storage). iOS may also empty
/// it when the phone runs short of space; downloads are never touched.
actor PlayCache {
    static let shared = PlayCache()

    /// The size limit in MB (0 = off). Stored here so it can be read from any thread.
    static let limitKey = "songCacheMB"
    static let defaultLimitMB = 1024

    private struct Entry: Codable {
        var file: String
        var size: Int64
        var used: Date
    }

    /// A song that's being written while it plays.
    private final class Partial {
        let url: URL
        let total: Int64
        let handle: FileHandle
        let path: URL
        var ranges: [Range<Int64>] = []
        init(url: URL, total: Int64, handle: FileHandle, path: URL) {
            self.url = url
            self.total = total
            self.handle = handle
            self.path = path
        }
    }

    private let dir = URL.cachesDirectory.appending(path: "PlayCache", directoryHint: .isDirectory)
    private var index: [String: Entry] = [:]
    private var partial: [String: Partial] = [:]
    private var indexLoaded = false

    private var indexURL: URL { dir.appending(path: "index.json") }

    private var limitBytes: Int64 {
        let mb = UserDefaults.standard.object(forKey: Self.limitKey) as? Int ?? Self.defaultLimitMB
        return Int64(max(0, mb)) * 1_000_000
    }

    private func loadIndex() {
        guard !indexLoaded else { return }
        indexLoaded = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL), let i = try? JSONDecoder().decode([String: Entry].self, from: data) {
            // Files iOS removed to free space are forgotten.
            index = i.filter { FileManager.default.fileExists(atPath: dir.appending(path: $0.value.file).path) }
        }
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(index) { try? data.write(to: indexURL, options: .atomic) }
    }

    // MARK: Playing from the cache

    /// The cached file for a song, if it's here.
    func file(for key: String) -> URL? {
        loadIndex()
        guard limitBytes > 0, var e = index[key] else { return nil }
        let url = dir.appending(path: e.file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            index[key] = nil
            return nil
        }
        e.used = Date()
        index[key] = e
        saveIndex()
        return url
    }

    // MARK: Filling it while songs stream

    /// Audio that just arrived for a streaming song (`offset` bytes into a file of `total` bytes).
    func write(key: String, url: URL, total: Int64, offset: Int64, data: Data) {
        loadIndex()
        guard limitBytes > 0, total > 0, total < limitBytes, index[key] == nil, !data.isEmpty,
              offset >= 0, offset + Int64(data.count) <= total else { return }
        var p = partial[key]
        if let old = p, old.url != url || old.total != total {
            // A different stream for the same song (a fresh link, another quality): start over.
            discard(key)
            p = nil
        }
        if p == nil {
            let path = dir.appending(path: "\(Self.fileStem(key)).part")
            try? FileManager.default.removeItem(at: path)
            guard FileManager.default.createFile(atPath: path.path, contents: nil),
                  let h = try? FileHandle(forWritingTo: path) else { return }
            p = Partial(url: url, total: total, handle: h, path: path)
            partial[key] = p
        }
        guard let p else { return }
        do {
            try p.handle.seek(toOffset: UInt64(offset))
            try p.handle.write(contentsOf: data)
        } catch {
            discard(key)
            return
        }
        p.ranges = Self.merge(p.ranges, offset..<(offset + Int64(data.count)))
        if p.ranges.count == 1, p.ranges[0] == 0..<total { finish(key, p) }
    }

    /// After a song ended: fetch what didn't stream (jumped over), so it's kept whole.
    func fillGaps(key: String) async {
        guard let p = partial[key] else { return }
        var missing: [Range<Int64>] = []
        var at: Int64 = 0
        for r in p.ranges {
            if r.lowerBound > at { missing.append(at..<r.lowerBound) }
            at = max(at, r.upperBound)
        }
        if at < p.total { missing.append(at..<p.total) }
        // Only worth it when most of the song is already here.
        let have = p.ranges.reduce(Int64(0)) { $0 + Int64($1.count) }
        guard have * 2 >= p.total else { return }
        for gap in missing {
            var from = gap.lowerBound
            while from < gap.upperBound {
                let to = min(from + 2_000_000, gap.upperBound) - 1
                guard let bytes = try? await StreamCache.fetch(p.url, from: from, to: to), !bytes.isEmpty else { return }
                write(key: key, url: p.url, total: p.total, offset: from, data: bytes)
                from += Int64(bytes.count)
            }
        }
    }

    private func finish(_ key: String, _ p: Partial) {
        try? p.handle.close()
        partial[key] = nil
        let file = "\(Self.fileStem(key)).m4a"
        let dest = dir.appending(path: file)
        try? FileManager.default.removeItem(at: dest)
        guard (try? FileManager.default.moveItem(at: p.path, to: dest)) != nil else { return }
        index[key] = Entry(file: file, size: p.total, used: Date())
        trim()
        saveIndex()
    }

    private func discard(_ key: String) {
        guard let p = partial[key] else { return }
        try? p.handle.close()
        try? FileManager.default.removeItem(at: p.path)
        partial[key] = nil
    }

    /// The least recently played songs go until the cache fits its limit.
    private func trim() {
        var total = index.values.reduce(Int64(0)) { $0 + $1.size }
        let limit = limitBytes
        for (key, e) in index.sorted(by: { $0.value.used < $1.value.used }) where total > limit {
            try? FileManager.default.removeItem(at: dir.appending(path: e.file))
            index[key] = nil
            total -= e.size
        }
    }

    // MARK: Settings

    /// Songs and bytes in the cache.
    func usage() -> (songs: Int, bytes: Int64) {
        loadIndex()
        return (index.count, index.values.reduce(Int64(0)) { $0 + $1.size })
    }

    /// The limit changed (or the cache was turned off).
    func limitChanged() {
        loadIndex()
        if limitBytes == 0 { clear() } else { trim(); saveIndex() }
    }

    func clear() {
        for key in Array(partial.keys) { discard(key) }
        for e in index.values { try? FileManager.default.removeItem(at: dir.appending(path: e.file)) }
        index = [:]
        saveIndex()
    }

    // MARK: Helpers

    private static func fileStem(_ key: String) -> String {
        key.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
    }

    private static func merge(_ list: [Range<Int64>], _ new: Range<Int64>) -> [Range<Int64>] {
        var all = (list + [new]).sorted { $0.lowerBound < $1.lowerBound }
        var out: [Range<Int64>] = []
        for r in all where !r.isEmpty {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        all = out
        return all
    }
}
