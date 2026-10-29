import AVFoundation
import Observation
import SwiftUI
import UIKit

/// The picture for podcast episodes (optional). The sound always comes from the normal player;
/// this silent video just follows it, so speed, skipping, the lock screen and CarPlay keep working.
/// It only loads while a video view is on screen, so it uses no data otherwise.
@Observable @MainActor
final class EpisodeVideo {
    static let shared = EpisodeVideo()

    /// Has a picture to show.
    private(set) var ready = false
    /// YouTube gave no video for this episode (or it didn't load).
    private(set) var unavailable = false
    /// The height playing now, and the ones the episode comes in.
    private(set) var height: Int?
    private(set) var heights: [Int] = []

    @ObservationIgnored let av = AVPlayer()
    @ObservationIgnored private var loader: StreamLoader?
    @ObservationIgnored private var key = ""
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var seeking = false

    private init() {
        av.isMuted = true
        av.allowsExternalPlayback = false
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        _ = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    /// The highest height to use: the setting, or 360p with Data saver on.
    private var maxHeight: Int {
        AppSettings.shared.dataSaver ? 360 : AppSettings.shared.videoQuality
    }

    /// A video view appeared or went away.
    func attach() {
        viewers += 1
        update()
    }

    func detach() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { stop() }
    }

    /// Loads the right video (or none) for what's playing and the settings.
    func update() {
        guard viewers > 0, AppSettings.shared.podcastVideo,
              let t = Player.shared.current, t.isEpisode,
              UIApplication.shared.applicationState != .background else {
            stop()
            return
        }
        let max = maxHeight
        let k = "\(t.id)#\(max)"
        guard k != key else { return }
        // Keep the old picture on screen while a new quality loads for the same episode.
        let sameEpisode = key.hasPrefix(t.id + "#")
        key = k
        if !sameEpisode { ready = false }
        unavailable = false
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let found = await StreamResolver.shared.video(t.id, maxHeight: max)
            guard let self, !Task.isCancelled, self.key == k else { return }
            guard let found else {
                self.unavailable = true
                self.ready = false
                return
            }
            self.height = found.height
            self.heights = found.heights
            let loader = StreamLoader(url: found.url)
            let item = AVPlayerItem(asset: loader.asset)
            item.preferredForwardBufferDuration = 10
            self.statusObserver = item.observe(\.status) { [weak self] item, _ in
                let status = item.status
                Task { @MainActor in
                    guard let self, self.key == k else { return }
                    if status == .readyToPlay {
                        self.ready = true
                        self.sync(force: true)
                    } else if status == .failed {
                        self.unavailable = true
                        self.ready = false
                    }
                }
            }
            self.loader = loader
            self.av.replaceCurrentItem(with: item)
            self.startTimer()
        }
    }

    func stop() {
        loadTask?.cancel()
        key = ""
        ready = false
        timer?.invalidate()
        timer = nil
        statusObserver = nil
        av.replaceCurrentItem(with: nil)
        loader = nil
    }

    /// Pick a quality (the highest choice means "always the sharpest").
    func choose(_ h: Int) {
        AppSettings.shared.videoQuality = h == heights.last ? 4320 : h
        update()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    /// Keeps the picture in step with the sound.
    private func sync(force: Bool = false) {
        guard ready, Player.shared.current?.isEpisode == true else { return }
        let clock = Player.shared.audioClock
        let videoTime = av.currentTime().seconds
        if !seeking, force || !videoTime.isFinite || abs(videoTime - clock.time) > 0.35 {
            seeking = true
            av.seek(to: CMTime(seconds: clock.time, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in self?.seeking = false }
            }
        }
        if clock.rate == 0 {
            if av.rate != 0 { av.pause() }
        } else if av.rate != clock.rate {
            av.rate = clock.rate
        }
    }
}

/// Shows the episode video (an AVPlayerLayer); several can share the one player.
struct EpisodeVideoLayer: UIViewRepresentable {
    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.playerLayer.player = EpisodeVideo.shared.av
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: LayerView, context: Context) {}
}

/// The video in the player, with the poster and a spinner until it's ready, plus quality and full screen.
struct EpisodeVideoView: View {
    let track: Track
    var width: CGFloat
    var fullScreen = false
    var onFullScreen: (() -> Void)?
    private var video: EpisodeVideo { .shared }

    var body: some View {
        ZStack {
            Color.black
            if fullScreen || video.ready {
                EpisodeVideoLayer()
            }
            if !video.ready {
                EpisodeArtwork(url: track.artworkURL ?? track.artwork(size: 800), width: width, corner: 0)
                    .opacity(0.55)
                if video.unavailable {
                    Text("No video for this episode")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.6), in: Capsule())
                } else {
                    ProgressView().tint(.white)
                }
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: fullScreen ? 0 : 8, style: .continuous))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                qualityMenu
                if let onFullScreen {
                    Button(action: onFullScreen) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 32, height: 32)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .accessibilityLabel("Full screen")
                }
            }
            .foregroundStyle(.white)
            .padding(8)
        }
        .onAppear { video.attach() }
        .onDisappear { video.detach() }
        .onChange(of: track.id) { _, _ in video.update() }
    }

    private var qualityMenu: some View {
        Menu {
            Section("Quality") {
                ForEach(video.heights.reversed(), id: \.self) { h in
                    Button {
                        video.choose(h)
                    } label: {
                        if h == video.height {
                            Label(Self.label(h), systemImage: "checkmark")
                        } else {
                            Text(Self.label(h))
                        }
                    }
                }
            }
            if AppSettings.shared.dataSaver {
                Text("Data saver keeps video at 360p")
            }
        } label: {
            HStack(spacing: 3) {
                Text(video.height.map(Self.label) ?? "Video")
                    .font(.system(size: 12, weight: .bold))
                if let h = video.height, h >= 720 {
                    Text("HD")
                        .font(.system(size: 8, weight: .heavy))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(.white, in: RoundedRectangle(cornerRadius: 2))
                        .foregroundStyle(.black)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(.black.opacity(0.55), in: Capsule())
        }
        .accessibilityLabel("Video quality \(video.height.map(Self.label) ?? "")")
    }

    static func label(_ h: Int) -> String {
        h >= 2160 ? "4K" : "\(h)p"
    }
}

/// Full screen: the video turned sideways to fill the phone, with play/pause, quality and close.
struct EpisodeVideoFullScreen: View {
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var controls = true
    private var player: Player { .shared }

    var body: some View {
        GeometryReader { geo in
            // Sideways: the long side of the screen becomes the video's width.
            let long = max(geo.size.width, geo.size.height)
            let short = min(geo.size.width, geo.size.height)
            let width = min(long, short * 16 / 9)
            ZStack {
                Color.black.ignoresSafeArea()
                EpisodeVideoView(track: track, width: width, fullScreen: true)
                    .rotationEffect(geo.size.height > geo.size.width ? .degrees(90) : .zero)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { controls.toggle() } }
                if controls {
                    VStack {
                        HStack {
                            Button { dismiss() } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 16, weight: .bold))
                                    .frame(width: 44, height: 44)
                                    .background(.black.opacity(0.55), in: Circle())
                            }
                            .accessibilityLabel("Close full screen")
                            Spacer()
                        }
                        Spacer()
                        Button { player.togglePlay() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 26))
                                .frame(width: 64, height: 64)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .padding(20)
                }
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}
