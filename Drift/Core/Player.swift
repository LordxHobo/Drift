import AVFoundation
import MediaPlayer
import Observation
import UIKit

enum RepeatMode {
    case off, all, one
}

/// Playback queue, background audio, lock screen / CarPlay controls and segment skipping.
@Observable @MainActor
final class Player {
    static let shared = Player()

    private(set) var queue: [Track] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var shuffle = false
    var repeatMode: RepeatMode = .off
    private(set) var playingFrom = ""
    private(set) var qualityLabel = ""
    /// Details about what's actually playing (tap the quality badge in the player).
    private(set) var streamInfo: [(String, String)] = []
    private(set) var skipMessage: String?
    private(set) var errorMessage: String?
    private(set) var routeName = "This iPhone"
    private(set) var isCarRoute = false

    /// Podcast playback speed (songs always play at 1×).
    private(set) var speed: Double = AppSettings.shared.podcastSpeed
    static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    /// Neighbours in the queue, shown beside the artwork while swiping.
    var nextInQueue: Track? {
        if index + 1 < queue.count { return queue[index + 1] }
        return repeatMode == .all && queue.count > 1 ? queue.first : nil
    }
    var previousInQueue: Track? { index > 0 ? queue[index - 1] : nil }
    var isEpisode: Bool { current?.isEpisode == true }

    /// Chapters of the current episode (empty when it has none).
    private(set) var chapters: [Chapter] = []
    var chapterIndex: Int? { Self.chapterIndex(in: chapters, at: currentTime) }
    var currentChapter: Chapter? { chapterIndex.map { chapters[$0] } }

    static func chapterIndex(in chapters: [Chapter], at t: Double) -> Int? {
        guard !chapters.isEmpty else { return nil }
        return chapters.lastIndex { $0.start <= t + 0.5 } ?? 0
    }
    var progress: Double { duration > 0 ? min(max(currentTime / duration, 0), 1) : 0 }

    @ObservationIgnored private let av = AVPlayer()
    @ObservationIgnored private var originalQueue: [Track] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var itemObservers: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemNotifications: [NSObjectProtocol] = []
    @ObservationIgnored private var playerObservers: [NSKeyValueObservation] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var segments: [SkipSegment] = []
    @ObservationIgnored private var lastProgressReport: Double = -10
    @ObservationIgnored private var lastChapterIndex: Int?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    /// Keeps the current stream loader alive (AVFoundation only holds it weakly).
    @ObservationIgnored private var loader: StreamLoader?
    @ObservationIgnored private var meter: LevelMeter?
    /// Real length from YouTube. Wins over what iOS reads from the file, which is often minutes too long.
    @ObservationIgnored private var knownDuration: Double?
    @ObservationIgnored private var silentSince: Double?
    @ObservationIgnored private var retried = false
    @ObservationIgnored private var artwork: (id: String, art: MPMediaItemArtwork)?
    /// Where to start when the restored song (from last time) is played.
    /// The video actually playing (the album version of a music video, or the song itself).
    @ObservationIgnored private var playID: String?
    /// Length came from the stream itself (exact), not from search results (rounded, sometimes off).
    @ObservationIgnored private var durationIsExact = false
    @ObservationIgnored private var pendingResume: (id: String, time: Double)?
    @ObservationIgnored private var lastPositionSave: Double = -10
    /// Quiet at the very end of a song (after its listed length), used to end it cleanly.
    @ObservationIgnored private var tailSilentSince: Double?

    private init() {
        av.automaticallyWaitsToMinimizeStalling = true
        timeObserver = av.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        playerObservers.append(av.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = status != .paused
                self.isBuffering = status == .waitingToPlayAtSpecifiedRate
                if status == .playing { self.watchdog?.cancel() }
                self.updateNowPlaying()
                LyricsActivity.shared.playingChanged(self.isPlaying)
                SocialStore.shared.playerChanged()
                if status == .paused { self.savePosition() }
                if status == .paused, let t = self.current, t.isEpisode, self.currentTime > 0 {
                    PodcastStore.shared.update(t, position: self.currentTime, duration: self.duration, force: true)
                }
            }
        })
        setupRemoteCommands()
        observeSession()
        updateRoute()
        restoreSession()
    }

    func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: Queue

    func play(_ tracks: [Track], startAt i: Int = 0, from source: String) {
        guard tracks.indices.contains(i) else { return }
        originalQueue = tracks
        playingFrom = source
        if shuffle {
            var rest = tracks
            let first = rest.remove(at: i)
            queue = [first] + rest.shuffled()
            index = 0
        } else {
            queue = tracks
            index = i
        }
        load()
    }

    /// Shuffle-play a whole list.
    func shufflePlay(_ tracks: [Track], from source: String) {
        guard !tracks.isEmpty else { return }
        shuffle = true
        play(tracks, startAt: Int.random(in: 0..<tracks.count), from: source)
    }

    func playNext(_ t: Track) {
        guard current != nil else { play([t], from: "Queue"); return }
        queue.insert(t, at: index + 1)
        originalQueue.append(t)
    }

    func toggleShuffle() {
        shuffle.toggle()
        guard let cur = current else { return }
        if shuffle {
            var rest = queue
            rest.remove(at: index)
            queue = [cur] + rest.shuffled()
            index = 0
        } else {
            queue = originalQueue
            index = queue.firstIndex(where: { $0.id == cur.id }) ?? 0
        }
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // MARK: Transport

    func togglePlay() {
        if isPlaying { pause() } else { resume() }
    }

    func resume() {
        guard current != nil else { return }
        if av.currentItem == nil { load(); return }
        configureAudioSession()
        av.play()
    }

    func pause() {
        av.pause()
    }

    func next() {
        if isEpisode, !chapters.isEmpty { nextChapter(); return }
        advance(auto: false)
    }

    /// Always the previous song (swiping back), unlike the ⏮ button which restarts a song first.
    func skipToPrevious() {
        guard index > 0 else { seek(to: 0); return }
        index -= 1
        load()
    }

    func seekToChapter(_ i: Int) {
        guard chapters.indices.contains(i) else { return }
        seek(to: chapters[i].start)
        if !isPlaying { resume() }
    }

    func nextChapter() {
        guard let i = chapterIndex, i + 1 < chapters.count else { return }
        seekToChapter(i + 1)
    }

    /// Back to the start of this chapter, or the previous one if it just started.
    func previousChapter() {
        guard let i = chapterIndex else { return }
        if currentTime - chapters[i].start > 3 || i == 0 {
            seekToChapter(i)
        } else {
            seekToChapter(i - 1)
        }
    }

    func skip(by delta: Double) {
        seek(to: currentTime + delta)
    }

    func setSpeed(_ s: Double) {
        speed = s
        AppSettings.shared.podcastSpeed = s
        applyRate()
        updateNowPlaying()
    }

    private var effectiveRate: Float { isEpisode ? Float(speed) : 1 }

    private func applyRate() {
        av.defaultRate = effectiveRate
        if av.timeControlStatus != .paused { av.rate = effectiveRate }
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if isEpisode, !chapters.isEmpty { previousChapter(); return }
        if currentTime > 3 || index == 0 {
            seek(to: 0)
        } else {
            index -= 1
            load()
        }
    }

    /// `precise: false` lets AVPlayer land up to half a second later, which starts noticeably sooner.
    func seek(to t: Double, precise: Bool = true) {
        let target = max(0, duration > 0 ? min(t, duration - 0.5) : t)
        currentTime = target
        // Restored song that isn't loaded yet: remember where to start.
        if av.currentItem == nil, let p = pendingResume {
            pendingResume = (p.id, target)
            updateNowPlaying()
            return
        }
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.5, preferredTimescale: 600)
        av.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: tolerance)
        updateNowPlaying()
    }

    private func advance(auto: Bool) {
        guard !queue.isEmpty else { return }
        if auto, let t = current, t.isEpisode { PodcastStore.shared.markFinished(t) }
        if auto && repeatMode == .one {
            seek(to: 0)
            av.play()
            return
        }
        if index + 1 < queue.count {
            index += 1
            load()
        } else if repeatMode == .all || !auto {
            index = 0
            load()
        } else {
            // End of the queue: stop on the first song, like most players.
            index = 0
            load(autoplay: false)
        }
    }

    // MARK: Loading

    private func load(autoplay: Bool = true) {
        guard let track = current else { return }
        loadTask?.cancel()
        detachItem()
        errorMessage = nil
        currentTime = 0
        duration = track.duration ?? 0
        // Search results give whole seconds: allow a moment so the last note isn't cut.
        knownDuration = track.duration.map { $0 + 1 }
        durationIsExact = false
        playID = nil
        streamInfo = [("Song", track.id)]
        segments = []
        retried = false
        isBuffering = true
        updateNowPlaying()
        loadArtwork(for: track)
        LyricsActivity.shared.trackChanged(track)
        SocialStore.shared.playerChanged()
        chapters = []
        lastChapterIndex = nil
        updateCommands()
        lastProgressReport = -10
        if autoplay && !track.isEpisode { Library.shared.addRecent(track) }
        var resumeAt = track.isEpisode ? PodcastStore.shared.resumePosition(track.id) : 0
        if let p = pendingResume, p.id == track.id { resumeAt = p.time }
        pendingResume = nil
        currentTime = resumeAt
        tailSilentSince = nil
        saveSession()

        loadTask = Task { [weak self] in
            guard let self else { return }
            // Music video → its album version when YouTube Music has one (no intro/outro, real length).
            let downloaded = Library.shared.isDownloaded(track.id)
            var chosen = track.id
            if !downloaded && !track.isEpisode { chosen = await AudioVersion.shared.preferred(track) }
            let playID = chosen
            guard !Task.isCancelled, self.current?.id == track.id else { return }
            self.playID = playID
            // Skip segments are looked up while the audio link is being found.
            let segsTask = Task {
                await SponsorBlock.segments(
                    for: playID,
                    categories: track.isEpisode ? SponsorBlock.podcastCategories : SponsorBlock.musicCategories)
            }
            do {
                let url: URL
                if downloaded {
                    url = Library.shared.fileURL(for: track.id)
                    self.qualityLabel = "Downloaded"
                } else {
                    let s = try await withTimeout(20) { [low = AppSettings.shared.dataSaver] in
                        try await StreamResolver.shared.resolve(playID, dataSaver: low)
                    }
                    self.qualityLabel = s.label
                    if let d = s.duration, d > 0 {
                        self.knownDuration = d
                        self.durationIsExact = true
                        self.duration = d
                    }
                    url = s.url
                    let note = await AudioVersion.shared.note(track.id)
                    self.streamInfo = [
                        ("Song", track.id),
                        ("Playing", playID == track.id ? "\(playID) (same)" : playID),
                        ("Album version", note),
                        ("Listed length", track.duration.map { formatTime($0) } ?? "–"),
                        ("Stream length", s.duration.map { String(format: "%.1f s", $0) } ?? "unknown"),
                        ("Extraction", s.source.isEmpty ? "–" : s.source),
                    ]
                }
                guard !Task.isCancelled, self.current?.id == track.id else { return }

                // Episode opening with an ad: start right after it instead of playing it and jumping.
                var startAt = resumeAt
                var skippedEarly: SkipSegment?
                if track.isEpisode, AppSettings.shared.skipSponsors,
                   let early = try? await withTimeout(1.5, { await segsTask.value }),
                   let seg = early.first(where: { $0.range.lowerBound <= startAt + 2 && $0.range.upperBound > startAt + 1 }) {
                    startAt = seg.range.upperBound
                    skippedEarly = seg
                }
                guard !Task.isCancelled, self.current?.id == track.id else { return }
                self.currentTime = startAt
                self.start(url, autoplay: autoplay, at: startAt)
                if let seg = skippedEarly {
                    self.showSkip("Skipped \(seg.label(atStart: true, atEnd: false)) · \(formatTime(seg.range.upperBound - seg.range.lowerBound))")
                }
                self.prefetchNext()

                if track.isEpisode {
                    let ch = await YouTubeSearch.chapters(for: track.id, duration: self.duration)
                    if self.current?.id == track.id, !ch.isEmpty {
                        self.chapters = ch
                        self.lastChapterIndex = nil
                        self.updateCommands()
                        self.chapterTick()
                    }
                }
                let segs = await segsTask.value
                if self.current?.id == track.id {
                    self.segments = segs.filter { $0 != skippedEarly && $0.range.upperBound > startAt + 0.5 }
                }
            } catch {
                guard !Task.isCancelled, self.current?.id == track.id else { return }
                self.fail(track, error)
            }
        }
    }

    /// Fully unloads the previous song: it can't play another note, and its events
    /// (finished, failed, time updates) can no longer affect the song that's loading.
    private func detachItem() {
        watchdog?.cancel()
        itemObservers.removeAll()
        itemNotifications.forEach { NotificationCenter.default.removeObserver($0) }
        itemNotifications.removeAll()
        av.pause()
        av.replaceCurrentItem(with: nil)
        loader = nil
        meter = nil
        silentSince = nil
    }

    private func start(_ url: URL, autoplay: Bool, at time: Double = 0) {
        itemObservers.removeAll()
        itemNotifications.forEach { NotificationCenter.default.removeObserver($0) }
        itemNotifications.removeAll()

        let item: AVPlayerItem
        if url.isFileURL || url.absoluteString.contains(".m3u8") || url.path.contains("/hls") {
            // Downloaded file, or an HLS stream (AVPlayer streams those itself).
            loader = nil
            item = AVPlayerItem(url: url)
        } else {
            let l = StreamLoader(url: url)
            loader = l
            item = AVPlayerItem(asset: l.asset)
        }
        item.preferredForwardBufferDuration = 30
        item.audioTimePitchAlgorithm = .spectral
        itemObservers.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor in self?.itemStatusChanged(item, status: status) }
        })
        let center = NotificationCenter.default
        itemNotifications.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item, item === self.av.currentItem else { return }
                self.advance(auto: true)
            }
        })
        itemNotifications.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item, item === self.av.currentItem else { return }
                self.recover()
            }
        })

        av.replaceCurrentItem(with: item)
        av.defaultRate = effectiveRate

        // Songs: listen for dead air at the end (hidden tracks, long silences).
        meter = nil
        silentSince = nil
        if let t = current, !t.isEpisode {
            Task { [weak self] in
                guard let audio = try? await item.asset.loadTracks(withMediaType: .audio).first,
                      let self, item === self.av.currentItem else { return }
                let m = LevelMeter()
                if let mix = SilenceDetector.audioMix(for: audio, meter: m) {
                    item.audioMix = mix
                    self.meter = m
                }
            }
        }
        if time > 0 {
            av.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if autoplay {
            configureAudioSession()
            // Start as soon as there's audio instead of waiting for a big buffer.
            av.playImmediately(atRate: effectiveRate)
        } else {
            isBuffering = false
        }

        // Audio not playing 6 s after asking: switch to a fresh link (full extraction).
        // The second link gets 15 s before Drift gives up with a message.
        watchdog?.cancel()
        guard autoplay else { return }
        let id = current?.id
        let wait: Double = retried ? 15 : 6
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, self.current?.id == id, item === self.av.currentItem,
                  self.av.timeControlStatus != .playing, self.av.rate != 0 || item.status != .readyToPlay
            else { return }
            if self.retried, let t = self.current {
                self.fail(t, TimeoutError())
            } else {
                self.recover()
            }
        }
    }

    private func itemStatusChanged(_ item: AVPlayerItem, status: AVPlayerItem.Status) {
        guard item === av.currentItem else { return }
        switch status {
        case .readyToPlay:
            let d = item.duration.seconds
            if knownDuration == nil, d.isFinite, d > 0 { duration = d }
            // Length only known from search results: trust the file when it's close (a music video
            // can run longer than the album song). Files claiming minutes more are ignored.
            streamInfo.append(("File length", d.isFinite ? String(format: "%.1f s", d) : "unknown"))
            if !durationIsExact, d.isFinite, d > 0, let k = knownDuration, d > k - 3, d < k + 60 {
                duration = d
                knownDuration = d
            }
            updateNowPlaying()
        case .failed:
            recover()
        default:
            break
        }
    }

    /// Stream URL expired or broke: fetch a fresh one once and continue where we were.
    private func recover() {
        guard let track = current else { return }
        if retried || Library.shared.isDownloaded(track.id) {
            fail(track)
            return
        }
        retried = true
        let resumeAt = currentTime
        let wasPlaying = isPlaying || isBuffering
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let playID = self.playID ?? track.id
            await StreamResolver.shared.invalidate(playID)
            do {
                let s = try await withTimeout(20) { [low = AppSettings.shared.dataSaver] in
                        try await StreamResolver.shared.resolve(playID, dataSaver: low)
                    }
                guard !Task.isCancelled, self.current?.id == track.id else { return }
                self.qualityLabel = s.label
                    if let d = s.duration, d > 0 {
                        self.knownDuration = d
                        self.durationIsExact = true
                        self.duration = d
                    }
                self.start(s.url, autoplay: wasPlaying, at: resumeAt)
            } catch {
                guard !Task.isCancelled, self.current?.id == track.id else { return }
                self.fail(track, error)
            }
        }
    }

    /// Shows why it failed (stays until the next song or Try again); songs move on to the next one.
    private func fail(_ track: Track, _ error: Error? = nil) {
        isBuffering = false
        watchdog?.cancel()
        av.pause()
        errorMessage = error.map { StreamResolver.describe($0, episode: track.isEpisode) }
            ?? (track.isEpisode ? "Couldn't load this episode." : "Couldn't load this song.")
        guard !track.isEpisode else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.current?.id == track.id else { return }
            if self.index + 1 < self.queue.count {
                self.index += 1
                self.load()
            }
        }
    }

    /// Load the current song/episode again with a fresh stream link.
    func retry() {
        guard let t = current else { return }
        Task {
            await StreamResolver.shared.invalidate(playID ?? t.id)
            load()
        }
    }

    /// Resolve stream links ahead of time so tapping play starts right away.
    func prefetch(_ tracks: [Track]) {
        let low = AppSettings.shared.dataSaver
        let todo = tracks.filter { !Library.shared.isDownloaded($0.id) && $0.id != current?.id }
        guard !todo.isEmpty else { return }
        // In parallel: each one is ready to start instantly (link found, opening seconds downloaded).
        for track in todo {
            Task.detached(priority: .utility) {
                let playID = await AudioVersion.shared.preferred(track)
                if let s = try? await StreamResolver.shared.resolve(playID, dataSaver: low) {
                    await StreamCache.shared.warm(s.url)
                }
            }
        }
    }

    /// Gets the next two songs ready while this one plays.
    private func prefetchNext() {
        let upcoming = queue.dropFirst(index + 1).prefix(2)
        prefetch(Array(upcoming))
    }

    // MARK: Remembering what was playing

    private static let sessionURL = URL.documentsDirectory.appending(path: "playback.json")
    private static let positionKey = "player.position"

    private struct Session: Codable {
        var queue: [Track]
        var index: Int
        var playingFrom: String
        var shuffle: Bool
    }

    /// Saves the queue (on every song change). The position is saved separately every few seconds.
    private func saveSession() {
        guard current != nil else { return }
        // Very long queues: keep the part around the current song.
        let lower = max(0, index - 100), upper = min(queue.count, index + 400)
        let session = Session(queue: Array(queue[lower..<upper]), index: index - lower,
                              playingFrom: playingFrom, shuffle: shuffle)
        UserDefaults.standard.set(currentTime, forKey: Self.positionKey)
        let url = Self.sessionURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(session) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Saves the exact position (when pausing and when Drift goes to the background).
    func savePosition() {
        guard current != nil else { return }
        UserDefaults.standard.set(currentTime, forKey: Self.positionKey)
    }

    /// Brings back the song from last time, paused where it was. It loads when you press play.
    private func restoreSession() {
        guard let data = try? Data(contentsOf: Self.sessionURL),
              let s = try? JSONDecoder().decode(Session.self, from: data),
              s.queue.indices.contains(s.index) else { return }
        queue = s.queue
        originalQueue = s.queue
        index = s.index
        playingFrom = s.playingFrom
        shuffle = s.shuffle
        let track = s.queue[s.index]
        let position = UserDefaults.standard.double(forKey: Self.positionKey)
        duration = track.duration ?? 0
        currentTime = position
        pendingResume = (track.id, position)
        isPlaying = false
        isBuffering = false
        loadArtwork(for: track)
        updateNowPlaying()
        updateCommands()
    }

    // MARK: Time & skipping

    private func tick(_ t: Double) {
        guard t.isFinite, av.currentItem != nil else { return }
        currentTime = t
        LyricsActivity.shared.tick(t)
        if knownDuration == nil, let d = av.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - duration) > 0.5 {
            duration = d
            updateNowPlaying()
        }
        // Never show a position past the end (e.g. "2:38 / 2:38" while it keeps playing).
        if isPlaying, duration > 0, t > duration + 0.5 {
            duration = t
            updateNowPlaying()
        }
        if abs(t - lastPositionSave) >= 3 {
            lastPositionSave = t
            UserDefaults.standard.set(t, forKey: Self.positionKey)
        }
        // Song is over at its real length, even if iOS thinks the file runs longer (it can add minutes of
        // silence). The listed length is a little short for some songs, so the last notes get up to 4 s
        // more: it ends once the audio has gone quiet, or at the latest 4 s past the listed length.
        if let k = knownDuration, isPlaying, t >= k - 0.15 {
            let quiet = (meter?.peak ?? 1) < 0.003
            if quiet {
                if tailSilentSince == nil { tailSilentSince = t }
            } else {
                tailSilentSince = nil
            }
            let quietLongEnough = tailSilentSince.map { t - $0 >= (durationIsExact ? 0.5 : 1) } ?? false
            // A length from search results is only a hint: never cut a song short because of it.
            let forced = durationIsExact && (t >= k + 4 || (meter == nil && t >= k + 1))
            if forced || quietLongEnough {
                knownDuration = nil
                tailSilentSince = nil
                advance(auto: true)
                return
            }
        }
        chapterTick()
        if checkSilence(at: t) { return }
        if let cur = current, cur.isEpisode, duration > 0, abs(t - lastProgressReport) >= 5 {
            lastProgressReport = t
            PodcastStore.shared.update(cur, position: t, duration: duration)
        }
        let skipOn = isEpisode ? AppSettings.shared.skipSponsors : AppSettings.shared.skipNonMusic
        guard skipOn, isPlaying,
              let seg = segments.first(where: { $0.range.contains(t) && $0.range.upperBound - t > 0.75 }) else { return }
        segments.removeAll { $0 == seg }
        let length = formatTime(seg.range.upperBound - seg.range.lowerBound)
        let atEnd = duration > 0 && seg.range.upperBound >= duration - 1.5
        showSkip("Skipped \(seg.label(atStart: seg.range.lowerBound < 2, atEnd: atEnd)) · \(length)")
        if atEnd {
            advance(auto: true)
        } else {
            seek(to: seg.range.upperBound, precise: false)
        }
    }

    /// 6 s of near-total silence in the second half of a song (with more left): move on.
    private func checkSilence(at t: Double) -> Bool {
        guard let m = meter, !isEpisode, AppSettings.shared.skipSilence, isPlaying, !isBuffering,
              duration > 60, t > duration * 0.5, duration - t > 8 else {
            silentSince = nil
            return false
        }
        guard m.peak < 0.002 else {
            silentSince = nil
            return false
        }
        guard let since = silentSince else {
            silentSince = t
            return false
        }
        guard t - since >= 6 else { return false }
        silentSince = nil
        meter = nil
        showSkip("Skipped \(formatTime(duration - since)) of silence")
        advance(auto: true)
        return true
    }

    /// Chapter changed: refresh lock screen / CarPlay info and the Live Activity.
    private func chapterTick() {
        guard !chapters.isEmpty else { return }
        let i = chapterIndex
        guard i != lastChapterIndex else { return }
        lastChapterIndex = i
        updateNowPlaying()
        if let i {
            LyricsActivity.shared.chapterChanged(current: chapters[i].title,
                                                 next: i + 1 < chapters.count ? chapters[i + 1].title : "")
        }
    }

    private func showSkip(_ message: String) {
        skipMessage = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.skipMessage == message { self?.skipMessage = nil }
        }
    }

    // MARK: Lock screen, Control Center, CarPlay

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: 30) }
            return .success
        }
        c.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: -15) }
            return .success
        }
        c.changePlaybackRateCommand.supportedPlaybackRates = Self.speeds.map { NSNumber(value: $0) }
        c.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let rate = Double(e.playbackRate)
            Task { @MainActor in self?.setSpeed(rate) }
            return .success
        }
        updateCommands()
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in self?.seek(to: t) }
            return .success
        }
    }

    /// Episodes get ±15/30 s buttons (lock screen, CarPlay, steering wheel); songs get previous/next.
    private func updateCommands() {
        let c = MPRemoteCommandCenter.shared()
        let ep = isEpisode
        c.skipForwardCommand.isEnabled = ep
        c.skipBackwardCommand.isEnabled = ep
        c.changePlaybackRateCommand.isEnabled = ep
        // With chapters, next/previous (steering wheel, CarPlay) jump between chapters.
        c.nextTrackCommand.isEnabled = !ep || !chapters.isEmpty
        c.previousTrackCommand.isEnabled = !ep || !chapters.isEmpty
    }

    private func updateNowPlaying() {
        guard let t = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying && !isBuffering ? Double(effectiveRate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(effectiveRate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = t.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let i = chapterIndex, t.isEpisode {
            info[MPMediaItemPropertyAlbumTitle] = chapters[i].title
            info[MPNowPlayingInfoPropertyChapterNumber] = i
            info[MPNowPlayingInfoPropertyChapterCount] = chapters.count
        }
        if let artwork, artwork.id == t.id { info[MPMediaItemPropertyArtwork] = artwork.art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for t: Track) {
        guard artwork?.id != t.id, let url = t.artwork(size: 600) else { return }
        Task { [weak self] in
            guard let result = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: result.0) else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            guard let self, self.current?.id == t.id else { return }
            self.artwork = (t.id, art)
            self.updateNowPlaying()
        }
    }

    // MARK: Audio session

    private func observeSession() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let info = n.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended,
                  let opts = info[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: opts).contains(.shouldResume) else { return }
            MainActor.assumeIsolated { self?.resume() }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated {
                // Headphones unplugged / car disconnected: pause instead of blasting the phone speaker.
                if reason == .oldDeviceUnavailable { self?.pause() }
                self?.updateRoute()
            }
        }
    }

    private func updateRoute() {
        guard let out = AVAudioSession.sharedInstance().currentRoute.outputs.first else {
            routeName = "This iPhone"
            isCarRoute = false
            return
        }
        isCarRoute = out.portType == .carAudio
        switch out.portType {
        case .builtInSpeaker, .builtInReceiver: routeName = "This iPhone"
        case .carAudio: routeName = "CarPlay"
        default: routeName = out.portName
        }
    }
}

/// Runs `op`, throwing TimeoutError if it takes longer than `seconds`.
func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
