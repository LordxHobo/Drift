import BackgroundTasks
import Foundation
import Observation
import UIKit

/// Downloads songs for offline playback.
///
/// Each song's audio link is looked up while Drift is open (a few at a time), then the file itself is
/// handed to iOS as background downloads, so it keeps downloading while you use other apps or the
/// phone is locked. (Swiping Drift away in the app switcher makes iOS cancel them; they resume the
/// next time Drift opens.)
@Observable @MainActor
final class DownloadManager {
    static let shared = DownloadManager()
    nonisolated static let sessionID = "com.lordxhobo.drift.downloads"

    /// Active and queued downloads, 0...1.
    private(set) var progress: [String: Double] = [:]
    private(set) var failed: Set<String> = []

    /// Songs in the current run of downloads (for the time estimate).
    private(set) var batchTotal = 0
    private(set) var batchDone = 0
    @ObservationIgnored private var batchStart: Date?
    /// Name shown in the background progress ("Big Spotify playlist"); nil when songs come from several places.
    @ObservationIgnored private var batchName: String?
    @ObservationIgnored private var batchNames: Set<String> = []
    /// iOS 26 background task that keeps Drift running until the downloads are done.
    @ObservationIgnored private var continued: AnyObject?
    @ObservationIgnored private var continuedRequested = false
    nonisolated static let continuedTaskID = "com.lordxhobo.drift.downloads.run"

    /// Songs waiting for their audio link.
    @ObservationIgnored private var queue: [Track] = []
    @ObservationIgnored private var resolving = 0
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// A song whose file is being downloaded in parts.
    struct Pending: Codable {
        var track: Track
        var url: URL
        var total: Int
        var parts: Int
        var done: Set<Int> = []
        var attempts = 0
    }
    @ObservationIgnored private var pending: [String: Pending] = [:]
    /// Bytes received per song and part, for the progress rings.
    @ObservationIgnored private var received: [String: [Int: Int64]] = [:]

    @ObservationIgnored private let pendingURL = URL.documentsDirectory.appending(path: "downloads-pending.json")
    @ObservationIgnored let partsDirectory = URL.documentsDirectory.appending(path: "DownloadParts", directoryHint: .isDirectory)
    @ObservationIgnored private let delegate: DownloadSessionDelegate
    @ObservationIgnored let session: URLSession

    /// YouTube slows down very large single requests, so files come in parts of this size.
    private static let partSize = 3_000_000

    private init() {
        let delegate = DownloadSessionDelegate()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 4
        self.delegate = delegate
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        try? FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: pendingURL),
           let saved = try? JSONDecoder().decode([String: Pending].self, from: data) {
            pending = saved
            for (id, p) in saved { progress[id] = Double(p.done.count) / Double(max(p.parts, 1)) }
        }
        // Reconnect to downloads iOS carried on with while Drift was closed.
        Task { await self.reconcile() }
    }

    func isActive(_ id: String) -> Bool { progress[id] != nil }

    // MARK: Starting

    func download(_ t: Track) {
        guard !Library.shared.isDownloaded(t.id), progress[t.id] == nil else { return }
        if progress.isEmpty {
            batchTotal = 0
            batchDone = 0
            batchStart = Date()
        }
        batchTotal += 1
        failed.remove(t.id)
        progress[t.id] = 0
        queue.append(t)
        pump()
        startContinuedTask()
        updateContinued()
    }

    /// `name`: the playlist or album, shown in the progress on the lock screen.
    func download(_ tracks: [Track], name: String? = nil) {
        if progress.isEmpty { batchNames = [] }
        if let name { batchNames.insert(name) }
        batchName = batchNames.count == 1 ? batchNames.first : nil
        tracks.forEach { download($0) }
    }

    func cancelAll() {
        for t in queue { progress[t.id] = nil }
        queue.removeAll()
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        for id in pending.keys { progress[id] = nil; removeParts(id) }
        pending.removeAll()
        savePending()
        endBackgroundTimeIfDone()
    }

    /// Looks up audio links, three at a time.
    private func pump() {
        while resolving < 3, !queue.isEmpty {
            let t = queue.removeFirst()
            resolving += 1
            keepRunningInBackground()
            Task {
                await self.start(t)
                self.resolving -= 1
                self.pump()
                self.endBackgroundTimeIfDone()
            }
        }
    }

    private func start(_ t: Track, freshLink: Bool = false) async {
        do {
            let playID = await AudioVersion.shared.preferred(t)
            if freshLink { await StreamResolver.shared.invalidate(playID) }
            let stream = try await StreamResolver.shared.resolve(playID, dataSaver: false)
            // A stream-only video (no audio file to save) can play but not be downloaded.
            guard stream.source != "ios-hls" else { throw StreamError.noAudio }
            let total = try await Self.size(of: stream.url)
            let parts = max(1, Int((Double(total) / Double(Self.partSize)).rounded(.up)))
            var p = Pending(track: t, url: stream.url, total: total, parts: parts)
            if let old = pending[t.id] { p.attempts = old.attempts }
            pending[t.id] = p
            received[t.id] = [:]
            savePending()
            for i in 0..<parts { enqueue(t.id, part: i, p) }
        } catch {
            fail(t.id)
        }
    }

    private func enqueue(_ id: String, part i: Int, _ p: Pending) {
        var req = URLRequest(url: p.url)
        let from = i * Self.partSize
        let to = min(from + Self.partSize, p.total) - 1
        req.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        req.allowsCellularAccess = AppSettings.shared.downloadOverCellular
        let task = session.downloadTask(with: req)
        task.taskDescription = "\(id)|\(i)"
        task.countOfBytesClientExpectsToReceive = Int64(to - from + 1)
        task.resume()
    }

    /// File size from the link ("clen=") or, failing that, a 1-byte request.
    private static func size(of url: URL) async throws -> Int {
        if let clen = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "clen" })?.value.flatMap(Int.init), clen > 0 {
            return clen
        }
        var req = URLRequest(url: url)
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"),
              let slash = range.lastIndex(of: "/"), let total = Int(range[range.index(after: slash)...]), total > 0
        else { throw URLError(.badServerResponse) }
        return total
    }

    // MARK: Background downloads reporting back

    func partProgress(_ id: String, part: Int, bytes: Int64) {
        guard let p = pending[id] else { return }
        received[id, default: [:]][part] = bytes
        let got = received[id]?.values.reduce(0, +) ?? 0
        progress[id] = min(Double(got) / Double(max(p.total, 1)), 0.99)
    }

    /// A part arrived (already moved into DownloadParts by the session delegate).
    func partFinished(_ id: String, part: Int) {
        guard var p = pending[id] else { return }
        p.done.insert(part)
        pending[id] = p
        savePending()
        if p.done.count == p.parts { assemble(id) }
    }

    func partFailed(_ id: String, part: Int) {
        guard var p = pending[id] else { return }
        // Link may have stopped working: get a fresh one and try the whole song once more.
        guard p.attempts < 1 else { fail(id); return }
        p.attempts += 1
        pending[id] = p
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription?.hasPrefix(id + "|") == true }.forEach { $0.cancel() }
        }
        removeParts(id)
        let track = p.track
        keepRunningInBackground()
        Task {
            await self.start(track, freshLink: true)
            self.endBackgroundTimeIfDone()
        }
    }

    /// All parts are here: join them into the song file.
    private func assemble(_ id: String) {
        guard let p = pending[id] else { return }
        let dest = Library.shared.fileURL(for: id)
        do {
            try? FileManager.default.removeItem(at: dest)
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            let out = try FileHandle(forWritingTo: dest)
            for i in 0..<p.parts {
                let data = try Data(contentsOf: partURL(id, i))
                try out.write(contentsOf: data)
            }
            try out.close()
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size > 10_000 else { throw URLError(.zeroByteResource) }
            Library.shared.markDownloaded(p.track)
            finish(id)
            batchDone += 1
            updateContinued()
        } catch {
            try? FileManager.default.removeItem(at: dest)
            fail(id)
        }
    }

    private func fail(_ id: String) {
        failed.insert(id)
        finish(id)
        batchDone += 1
        updateContinued()
    }

    private func finish(_ id: String) {
        progress[id] = nil
        received[id] = nil
        pending[id] = nil
        removeParts(id)
        savePending()
        endBackgroundTimeIfDone()
    }

    nonisolated func partURL(_ id: String, _ i: Int) -> URL {
        URL.documentsDirectory.appending(path: "DownloadParts/\(id).\(i).part")
    }

    private func removeParts(_ id: String) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: partsDirectory.path)) ?? []
        for f in files where f.hasPrefix(id + ".") {
            try? FileManager.default.removeItem(at: partsDirectory.appending(path: f))
        }
    }

    private func savePending() {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: pendingURL, options: .atomic)
    }

    /// After a relaunch: restart parts iOS no longer has (e.g. Drift was swiped away), finish complete songs.
    private func reconcile() async {
        guard !pending.isEmpty else { return }
        let tasks = await session.allTasks
        let running = Set(tasks.compactMap(\.taskDescription))
        for (id, p) in pending {
            if p.done.count == p.parts { assemble(id); continue }
            for i in 0..<p.parts where !p.done.contains(i) && !running.contains("\(id)|\(i)") {
                if FileManager.default.fileExists(atPath: partURL(id, i).path) {
                    partFinished(id, part: i)
                } else {
                    // The old link may have expired: look it up again for the whole song.
                    if batchStart == nil { batchStart = Date() }
                    batchTotal += 1
                    removeParts(id)
                    pending[id] = nil
                    progress[id] = 0
                    queue.append(p.track)
                    break
                }
            }
        }
        savePending()
        pump()
    }

    // MARK: Background time for link lookups

    /// iOS gives an app some extra time after you leave it: use it to look up the remaining links,
    /// so as many songs as possible are already with iOS's background downloader.
    private func keepRunningInBackground() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Drift downloads") { [weak self] in
            Task { @MainActor in self?.endBackgroundTime() }
        }
    }

    private func endBackgroundTimeIfDone() {
        if queue.isEmpty && resolving == 0 { endBackgroundTime() }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Running until done (iOS 26)

    /// Called once at launch: what to do when iOS starts the background task.
    nonisolated static func registerBackgroundTask() {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: continuedTaskID, using: nil) { task in
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                Task { @MainActor in DownloadManager.shared.attach(task) }
            }
        }
        #endif
    }

    /// Asks iOS to keep Drift running in the background until the downloads are done
    /// (shown as progress on the lock screen and in the Dynamic Island). Only possible while Drift is open.
    private func startContinuedTask() {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            guard continued == nil, !continuedRequested,
                  UIApplication.shared.applicationState == .active else { return }
            let request = BGContinuedProcessingTaskRequest(identifier: Self.continuedTaskID,
                                                           title: continuedTitle, subtitle: continuedSubtitle)
            request.strategy = .fail
            do {
                try BGTaskScheduler.shared.submit(request)
                continuedRequested = true
            } catch {
                continuedRequested = false
            }
        }
        #endif
    }

    private var continuedTitle: String {
        if let batchName { return "Downloading “\(batchName)”" }
        return "Downloading songs"
    }

    private var continuedSubtitle: String {
        "\(batchDone) of \(batchTotal) \(batchTotal == 1 ? "song" : "songs")"
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private func attach(_ task: BGContinuedProcessingTask) {
        continuedRequested = false
        guard !progress.isEmpty else {
            task.setTaskCompleted(success: true)
            return
        }
        continued = task
        task.expirationHandler = { [weak self] in
            // Cancelled with ✕, or iOS needed to stop it: what's left continues the next time Drift is open.
            Task { @MainActor in
                guard let self, let t = self.continued as? BGContinuedProcessingTask, t === task else { return }
                self.continued = nil
                task.setTaskCompleted(success: false)
            }
        }
        updateContinued()
    }
    #endif

    /// Keeps the progress on the lock screen up to date, and ends the task when everything is done.
    private func updateContinued() {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.progress.totalUnitCount = Int64(max(batchTotal, 1))
            task.progress.completedUnitCount = Int64(min(batchDone, batchTotal))
            task.updateTitle(continuedTitle, subtitle: continuedSubtitle)
            if progress.isEmpty {
                continued = nil
                task.setTaskCompleted(success: true)
            }
        }
        #endif
    }

    // MARK: Time estimate

    /// Rough time left for `remaining` songs, from how fast this run has been going.
    func estimate(remaining: Int) -> String? {
        guard remaining > 0, let start = batchStart else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        // The progress of songs underway counts too, so the estimate appears quickly.
        let partial = progress.values.reduce(0, +)
        let done = Double(batchDone) + partial
        guard elapsed > 8, done > 0.5 else { return "Estimating time left…" }
        let perSong = elapsed / done
        return timeLeftText(perSong * Double(remaining))
    }
}

/// "About 4 min left" style text.
func timeLeftText(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "Estimating time left…" }
    if seconds < 60 { return "Less than a minute left" }
    let minutes = Int((seconds / 60).rounded())
    if minutes < 60 { return "About \(minutes) min left" }
    return "About \(minutes / 60) h \(minutes % 60) min left"
}

/// Receives iOS's background download events (on a background thread) and passes them on.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (() -> Void)?
    private var eventsFinished = false

    /// Runs `done` once iOS has delivered all events of a background wake-up (right away if it already has).
    func whenEventsFinished(_ done: @escaping () -> Void) {
        lock.lock()
        if eventsFinished {
            eventsFinished = false
            lock.unlock()
            done()
        } else {
            completion = done
            lock.unlock()
        }
    }

    private static func parse(_ task: URLSessionTask) -> (String, Int)? {
        guard let d = task.taskDescription, let bar = d.lastIndex(of: "|"),
              let i = Int(d[d.index(after: bar)...]) else { return nil }
        return (String(d[..<bar]), i)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let parsed = Self.parse(downloadTask) else { return }
        let (id, i) = parsed
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else { return }   // reported as a failure below
        // The file must be moved before returning; iOS deletes it afterwards.
        let dest = URL.documentsDirectory.appending(path: "DownloadParts/\(id).\(i).part")
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            Task { @MainActor in DownloadManager.shared.partFinished(id, part: i) }
        } catch {
            Task { @MainActor in DownloadManager.shared.partFailed(id, part: i) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let parsed = Self.parse(downloadTask) else { return }
        let (id, i) = parsed
        Task { @MainActor in DownloadManager.shared.partProgress(id, part: i, bytes: totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let parsed = Self.parse(task) else { return }
        let (id, i) = parsed
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if let error = error as? URLError, error.code == .cancelled { return }
        if error != nil || !(200...299).contains(status) {
            Task { @MainActor in DownloadManager.shared.partFailed(id, part: i) }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let done = completion
        completion = nil
        if done == nil { eventsFinished = true }
        lock.unlock()
        done?()
    }
}

extension DownloadManager {
    /// Drift was woken up in the background because downloads finished: handle them, then let iOS know.
    func handleBackgroundEvents() async {
        let d = delegate
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            d.whenEventsFinished { c.resume() }
        }
        // Give the finished parts a moment to be joined into songs.
        try? await Task.sleep(for: .seconds(1))
    }
}
