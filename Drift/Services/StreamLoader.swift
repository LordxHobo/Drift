import AVFoundation
import Foundation

/// Feeds YouTube audio to AVPlayer in small pieces (ranged requests of 2 MB).
/// YouTube throttles or refuses single large requests, which made long podcast episodes hang at 0:00.
/// It also serves the opening bytes from `StreamCache`, so prefetched songs start instantly.
final class StreamLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "driftstream"
    private static let chunk: Int64 = 2_000_000

    let realURL: URL
    let asset: AVURLAsset
    private let queue = DispatchQueue(label: "drift.stream-loader")
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]   // only touched on `queue`

    init(url: URL) {
        realURL = url
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        c.scheme = Self.scheme
        asset = AVURLAsset(url: c.url!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    deinit {
        for t in tasks.values { t.cancel() }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        let key = ObjectIdentifier(request)
        tasks[key] = Task { [weak self] in
            await self?.handle(request)
            self?.queue.async { self?.tasks[key] = nil }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(request))?.cancel()
    }

    private func handle(_ request: AVAssetResourceLoadingRequest) async {
        do {
            let total = try await StreamCache.shared.length(of: realURL)
            if let info = request.contentInformationRequest {
                queue.sync {
                    let mime = URLComponents(url: self.realURL, resolvingAgainstBaseURL: false)?
                        .queryItems?.first { $0.name == "mime" }?.value ?? "audio/mp4"
                    info.contentType = mime.hasPrefix("video") ? AVFileType.mp4.rawValue : AVFileType.m4a.rawValue
                    info.contentLength = total
                    info.isByteRangeAccessSupported = true
                }
            }
            if let data = request.dataRequest {
                var offset = data.currentOffset > 0 ? data.currentOffset : data.requestedOffset
                let end = data.requestsAllDataToEndOfResource
                    ? total
                    : min(total, data.requestedOffset + Int64(data.requestedLength))

                // Opening bytes fetched ahead of time.
                if let head = await StreamCache.shared.head(of: realURL), offset < Int64(head.count) {
                    let upto = min(end, Int64(head.count))
                    let slice = head.subdata(in: Int(offset)..<Int(upto))
                    queue.sync { data.respond(with: slice) }
                    offset = upto
                }

                // Small first piece so playback (and jumps) start fast, then bigger ones.
                var size: Int64 = 256_000
                while offset < end {
                    try Task.checkCancellation()
                    let last = min(offset + size, end) - 1
                    size = min(size * 2, Self.chunk)
                    let bytes = try await StreamCache.fetch(realURL, from: offset, to: last)
                    guard !bytes.isEmpty else { break }
                    try Task.checkCancellation()
                    queue.sync { data.respond(with: bytes) }
                    offset += Int64(bytes.count)
                }
            }
            queue.sync { if !request.isCancelled { request.finishLoading() } }
        } catch is CancellationError {
        } catch {
            queue.sync { if !request.isCancelled { request.finishLoading(with: error) } }
        }
    }
}

/// File sizes and the first ~600 KB of upcoming streams.
actor StreamCache {
    static let shared = StreamCache()
    private static let headSize: Int64 = 600_000

    private var lengths: [URL: Int64] = [:]
    private var heads: [URL: Data] = [:]
    private var order: [URL] = []
    private var warming: [URL: Task<Void, Never>] = [:]

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c)
    }()

    static func fetch(_ url: URL, from: Int64, to: Int64) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode == 200, from > 0 {
            // Server ignored the range: cut out the part that was asked for.
            let lo = Int(from), hi = min(Int(to) + 1, data.count)
            return lo < hi ? data.subdata(in: lo..<hi) : Data()
        }
        return data
    }

    func length(of url: URL) async throws -> Int64 {
        if let l = lengths[url] { return l }
        // YouTube stream links carry the size as "clen".
        if let clen = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "clen" })?.value, let l = Int64(clen), l > 0 {
            lengths[url] = l
            return l
        }
        var req = URLRequest(url: url)
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await Self.session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var total: Int64?
        if let range = http.value(forHTTPHeaderField: "Content-Range"), let slash = range.lastIndex(of: "/") {
            total = Int64(range[range.index(after: slash)...])
        } else if http.statusCode == 200 {
            total = http.expectedContentLength > 0 ? http.expectedContentLength : nil
        }
        guard let total, total > 0 else { throw URLError(.badServerResponse) }
        lengths[url] = total
        return total
    }

    /// Only what's already downloaded: playback never waits on a pre-load still in progress.
    func head(of url: URL) async -> Data? {
        heads[url]
    }

    /// Fetch the opening bytes so playback can start the moment it's asked to.
    func warm(_ url: URL) {
        guard heads[url] == nil, warming[url] == nil else { return }
        warming[url] = Task {
            do {
                let total = try await self.length(of: url)
                let data = try await withTimeout(8) {
                    try await Self.fetch(url, from: 0, to: min(Self.headSize, total) - 1)
                }
                self.store(url, data)
            } catch {}
            self.doneWarming(url)
        }
    }

    private func store(_ url: URL, _ data: Data) {
        heads[url] = data
        order.removeAll { $0 == url }
        order.append(url)
        while order.count > 12 {
            let old = order.removeFirst()
            heads[old] = nil
            lengths[old] = nil
        }
    }

    private func doneWarming(_ url: URL) {
        warming[url] = nil
    }
}
