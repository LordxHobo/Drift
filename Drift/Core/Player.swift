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
    private(set) var skipMessage: String?
    private(set) var errorMessage: String?
    private(set) var routeName = "This iPhone"
    private(set) var isCarRoute = false

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var progress: Double { duration > 0 ? min(max(currentTime / duration, 0), 1) : 0 }

    @ObservationIgnored private let av = AVPlayer()
    @ObservationIgnored private var originalQueue: [Track] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var itemObservers: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemNotifications: [NSObjectProtocol] = []
    @ObservationIgnored private var playerObservers: [NSKeyValueObservation] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var segments: [ClosedRange<Double>] = []
    @ObservationIgnored private var retried = false
    @ObservationIgnored private var artwork: (id: String, art: MPMediaItemArtwork)?

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
                self.updateNowPlaying()
                LyricsActivity.shared.playingChanged(self.isPlaying)
            }
        })
        setupRemoteCommands()
        observeSession()
        updateRoute()
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

    func next() { advance(auto: false) }

    func previous() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 || index == 0 {
            seek(to: 0)
        } else {
            index -= 1
            load()
        }
    }

    func seek(to t: Double) {
        let target = max(0, duration > 0 ? min(t, duration - 0.5) : t)
        currentTime = target
        av.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }

    private func advance(auto: Bool) {
        guard !queue.isEmpty else { return }
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
        av.pause()
        errorMessage = nil
        currentTime = 0
        duration = track.duration ?? 0
        segments = []
        retried = false
        isBuffering = true
        updateNowPlaying()
        loadArtwork(for: track)
        LyricsActivity.shared.trackChanged(track)
        if autoplay { Library.shared.addRecent(track) }

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url: URL
                if Library.shared.isDownloaded(track.id) {
                    url = Library.shared.fileURL(for: track.id)
                    self.qualityLabel = "Downloaded"
                } else {
                    let s = try await StreamResolver.shared.resolve(track.id, dataSaver: AppSettings.shared.dataSaver)
                    self.qualityLabel = s.label
                    url = s.url
                }
                guard !Task.isCancelled, self.current?.id == track.id else { return }
                self.start(url, autoplay: autoplay)
                self.prefetchNext()

                let segs = await SponsorBlock.segments(for: track.id)
                if self.current?.id == track.id { self.segments = segs }
            } catch {
                guard !Task.isCancelled, self.current?.id == track.id else { return }
                self.fail(track)
            }
        }
    }

    private func start(_ url: URL, autoplay: Bool, at time: Double = 0) {
        itemObservers.removeAll()
        itemNotifications.forEach { NotificationCenter.default.removeObserver($0) }
        itemNotifications.removeAll()

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 30
        itemObservers.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor in self?.itemStatusChanged(item, status: status) }
        })
        let center = NotificationCenter.default
        itemNotifications.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance(auto: true) }
        })
        itemNotifications.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recover() }
        })

        av.replaceCurrentItem(with: item)
        if time > 0 {
            av.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if autoplay {
            configureAudioSession()
            av.play()
        } else {
            isBuffering = false
        }
    }

    private func itemStatusChanged(_ item: AVPlayerItem, status: AVPlayerItem.Status) {
        guard item === av.currentItem else { return }
        switch status {
        case .readyToPlay:
            let d = item.duration.seconds
            if d.isFinite, d > 0 { duration = d }
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
            await StreamResolver.shared.invalidate(track.id)
            guard let self else { return }
            do {
                let s = try await StreamResolver.shared.resolve(track.id, dataSaver: AppSettings.shared.dataSaver)
                guard !Task.isCancelled, self.current?.id == track.id else { return }
                self.qualityLabel = s.label
                self.start(s.url, autoplay: wasPlaying, at: resumeAt)
            } catch {
                guard !Task.isCancelled, self.current?.id == track.id else { return }
                self.fail(track)
            }
        }
    }

    private func fail(_ track: Track) {
        isBuffering = false
        errorMessage = "Couldn't play “\(track.title)”"
        let message = errorMessage
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.current?.id == track.id else { return }
            if self.index + 1 < self.queue.count { self.advance(auto: true) }
            try? await Task.sleep(for: .seconds(2))
            if self.errorMessage == message { self.errorMessage = nil }
        }
    }

    private func prefetchNext() {
        guard index + 1 < queue.count else { return }
        let next = queue[index + 1]
        guard !Library.shared.isDownloaded(next.id) else { return }
        let low = AppSettings.shared.dataSaver
        Task.detached(priority: .utility) {
            _ = try? await StreamResolver.shared.resolve(next.id, dataSaver: low)
        }
    }

    // MARK: Time & skipping

    private func tick(_ t: Double) {
        guard t.isFinite, av.currentItem != nil else { return }
        currentTime = t
        LyricsActivity.shared.tick(t)
        if let d = av.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - duration) > 0.5 {
            duration = d
            updateNowPlaying()
        }
        guard AppSettings.shared.skipNonMusic, isPlaying,
              let seg = segments.first(where: { $0.contains(t) && $0.upperBound - t > 0.75 }) else { return }
        segments.removeAll { $0 == seg }
        let length = formatTime(seg.upperBound - seg.lowerBound)
        if duration > 0, seg.upperBound >= duration - 1.5 {
            showSkip("Skipped non-music outro · \(length)")
            advance(auto: true)
        } else {
            showSkip(seg.lowerBound < 2 ? "Skipped non-music intro · \(length)" : "Skipped non-music part · \(length)")
            seek(to: seg.upperBound)
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
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in self?.seek(to: t) }
            return .success
        }
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
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying && !isBuffering ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = t.album { info[MPMediaItemPropertyAlbumTitle] = album }
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
