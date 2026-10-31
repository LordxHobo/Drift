import SwiftUI
import AVKit
import MediaPlayer

struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var bg: Color = Theme.playerFallback
    @State private var scrub: Double?
    @State private var dragDown: CGFloat = 0
    @State private var showLyrics = false
    @State private var showStreamInfo = false
    @State private var showChapters = false
    @State private var showVideoFull = false
    @State private var showJam = false
    @State private var showQueue = false
    /// Live artwork drag. A @GestureState resets itself even when iOS cancels the drag,
    /// so the artwork can never get stuck halfway.
    @GestureState private var drag = SwipeDrag()
    /// Where the artwork sits after letting go (animates to the neighbour, then back to 0).
    @State private var settle: CGFloat = 0
    private var player: Player { .shared }
    private var library: Library { .shared }
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        ZStack {
            LinearGradient(colors: [bg, bg.opacity(0.85), Color(hex: 0x121214)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            if let t = player.current {
                content(t)
            } else {
                Color.clear.onAppear { dismiss() }
            }
        }
        .foregroundStyle(Theme.text)
        .offset(y: dragDown)
        .gesture(DragGesture().onChanged { v in
            // Sideways drags belong to the artwork.
            guard abs(v.translation.height) > abs(v.translation.width) else { return }
            dragDown = max(0, v.translation.height)
        }.onEnded { v in
            if v.translation.height > 140 || v.predictedEndTranslation.height > 400 {
                dismiss()
            } else {
                withAnimation(.spring(duration: 0.3)) { dragDown = 0 }
            }
        })
        .task(id: player.current?.id) {
            let c = await ArtworkPalette.color(for: player.current?.artwork(size: 200))
            withAnimation(.easeInOut(duration: 0.6)) { bg = c ?? Theme.playerFallback }
        }
        .fullScreenCover(isPresented: $showLyrics) {
            LyricsView(background: bg)
        }
        .sheet(isPresented: $showChapters) {
            ChaptersSheet()
        }
        .fullScreenCover(isPresented: $showVideoFull) {
            if let t = player.current { EpisodeVideoFullScreen(track: t) }
        }
        // Add to playlist, Replace and Invite from this screen's song menu open over the player.
        .songSheets(inPlayer: true)
    }

    @ViewBuilder
    private func content(_ t: Track) -> some View {
        GeometryReader { geo in
            // The artwork gets the space left after the controls (never more than before), so
            // everything fits on small phones like the iPhone 13 mini. Short screens also get smaller gaps.
            let artCap = min(geo.size.width - 48, geo.size.height * 0.45)
            VStack(spacing: geo.size.height < 740 ? 14 : 22) {
                // Header
                if Theme.isMusic {
                    // Apple Music: just a grabber at the top.
                    Button { dismiss() } label: {
                        Capsule()
                            .fill(.white.opacity(0.45))
                            .frame(width: 40, height: 5)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close player")
                } else {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .driftGlass(in: Circle(), interactive: true)
                    }
                    .accessibilityLabel("Close player")
                    Spacer()
                    VStack(spacing: 1) {
                        Text("PLAYING FROM")
                            .font(.system(size: 11, weight: .medium))
                            .tracking(1)
                            .foregroundStyle(Color(hex: 0xD4D4D8))
                        Text(player.playingFrom)
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(1)
                    }
                    Spacer()
                    Menu {
                        TrackMenuItems(track: t)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .driftGlass(in: Circle(), interactive: true)
                    }
                    .accessibilityLabel("More options")
                }
                .padding(.horizontal, -10)
                }

                // Artwork (16:9 for podcast episodes)
                if t.isFeedEpisode {
                    // A show from its feed: its square cover (audio only, no video).
                    GeometryReader { box in
                        ArtworkView(url: t.artwork(size: 800), size: max(120, min(box.size.width, box.size.height)), corner: 8, seed: t.id)
                            .shadow(color: .black.opacity(0.45), radius: 25, y: 16)
                            .frame(width: box.size.width, height: box.size.height)
                    }
                    .frame(maxWidth: .infinity, maxHeight: artCap)
                    .layoutPriority(1)
                } else if t.isEpisode && AppSettings.shared.podcastVideo {
                    // The episode's video (optional, in Settings or with the Video button below).
                    EpisodeVideoView(track: t, width: geo.size.width - 48) { showVideoFull = true }
                        .shadow(color: .black.opacity(0.45), radius: 25, y: 16)
                        .frame(maxWidth: .infinity)
                } else if t.isEpisode {
                    EpisodeArtwork(url: t.artworkURL ?? t.artwork(size: 800), width: geo.size.width - 48, corner: 8)
                        .shadow(color: .black.opacity(0.45), radius: 25, y: 16)
                        .frame(maxWidth: .infinity)
                } else {
                    GeometryReader { box in
                        artworkCarousel(t, size: max(120, min(box.size.width, box.size.height)))
                            .frame(width: box.size.width, height: box.size.height)
                    }
                    .frame(maxWidth: .infinity, maxHeight: artCap)
                    // Sized before the spacer below, so it takes the room first (up to its old size).
                    .layoutPriority(1)
                }

                Spacer(minLength: 0)

                // Title
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title)
                            .font(Theme.isMusic ? .system(size: 21, weight: .semibold) : .system(size: 22, weight: .heavy))
                            .tracking(Theme.isMusic ? 0 : -0.3)
                            .lineLimit(1)
                        Text(t.artist)
                            .font(.system(size: Theme.isMusic ? 20 : 15))
                            .foregroundStyle(Theme.isMusic ? Color.white.opacity(0.6) : Color(hex: 0xD4D4D8))
                            .lineLimit(1)
                    }
                    Spacer()
                    if Theme.isMusic {
                        Menu {
                            TrackMenuItems(track: t)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 15, weight: .bold))
                                .frame(width: 30, height: 30)
                                .background(.white.opacity(0.2), in: Circle())
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("More options")
                    }
                    if t.isEpisode {
                        if let c = PodcastStore.shared.channel(for: t) {
                            FollowButton(channel: c, compact: true)
                        }
                    } else {
                    Button {
                        library.toggleLike(t)
                    } label: {
                        Image(systemName: library.isLiked(t.id) ? "heart.fill" : "heart")
                            .font(.system(size: 24))
                            .foregroundStyle(library.isLiked(t.id) ? accent : Theme.text)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(library.isLiked(t.id) ? "Remove from Liked songs" : "Like")
                    }
                }

                // Current chapter
                if t.isEpisode, let i = player.chapterIndex, let ch = player.currentChapter {
                    Button { showChapters = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(accent)
                            Text("\(i + 1)/\(player.chapters.count)")
                                .font(.system(size: 12, weight: .bold).monospacedDigit())
                                .foregroundStyle(Color(hex: 0xD4D4D8))
                            Text(ch.title)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color(hex: 0xD4D4D8))
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Chapter \(i + 1) of \(player.chapters.count): \(ch.title). Show all chapters")
                }

                // Progress
                VStack(spacing: 6) {
                    ScrubBar(progress: scrub ?? player.progress,
                             markers: chapterMarkers,
                             onChange: { scrub = $0 }, onEnd: { p in
                        player.seek(to: p * player.duration)
                        scrub = nil
                    })
                    HStack {
                        Text(player.duration > 0
                             ? formatTime((scrub ?? player.progress) * player.duration)
                             : (player.isBuffering ? "Loading…" : "0:00"))
                        Spacer()
                        Text(player.duration > 0
                             ? (Theme.isMusic ? "-" + formatTime(max(player.duration - (scrub ?? player.progress) * player.duration, 0))
                                              : formatTime(player.duration))
                             : "--:--")
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color(hex: 0xD4D4D8))
                }

                // Controls
                if t.isEpisode {
                    episodeControls
                } else {
                HStack {
                    Button { player.toggleShuffle() } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(player.shuffle ? accent : Color(hex: 0xD4D4D8))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(player.shuffle ? "Shuffle on" : "Shuffle off")
                    Spacer()
                    Button { player.previous() } label: {
                        Image(systemName: Theme.isMusic ? "backward.fill" : "backward.end.fill")
                            .font(.system(size: Theme.isMusic ? 34 : 28))
                            .frame(width: 52, height: 52)
                    }
                    .accessibilityLabel("Previous")
                    Spacer()
                    Button { player.togglePlay() } label: {
                        let glass = DriftGlass.isOn || Theme.isMusic
                        ZStack {
                            if !glass { Circle().fill(Theme.text) }
                            if player.isBuffering && !player.isPlaying {
                                ProgressView().tint(glass ? Theme.text : Theme.bg)
                            } else {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: Theme.isMusic ? 46 : 28))
                                    .foregroundStyle(glass ? Theme.text : Theme.bg)
                            }
                        }
                        .frame(width: 72, height: 72)
                        .driftGlass(in: Circle(), clear: false, tint: .white.opacity(0.12), interactive: true)
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    Spacer()
                    Button { player.next() } label: {
                        Image(systemName: Theme.isMusic ? "forward.fill" : "forward.end.fill")
                            .font(.system(size: Theme.isMusic ? 34 : 28))
                            .frame(width: 52, height: 52)
                    }
                    .accessibilityLabel("Next")
                    Spacer()
                    Button { player.cycleRepeat() } label: {
                        Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(player.repeatMode == .off ? Color(hex: 0xD4D4D8) : accent)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(repeatLabel)
                }
                .buttonStyle(.plain)
                }

                // Volume (Apple Music style)
                if Theme.isMusic {
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.fill").font(.system(size: 12))
                        VolumeSlider().frame(height: 24)
                        Image(systemName: "speaker.wave.3.fill").font(.system(size: 12))
                    }
                    .foregroundStyle(.white.opacity(0.6))
                }

                // Skip / error toast
                Group {
                    if let msg = player.errorMessage {
                        errorBanner(msg)
                    } else if let msg = player.skipMessage {
                        toast(msg, icon: "forward.frame.fill")
                    } else {
                        Color.clear
                    }
                }
                .frame(minHeight: 30)
                .animation(.easeOut(duration: 0.25), value: player.skipMessage)
                .animation(.easeOut(duration: 0.25), value: player.errorMessage)

                // Bottom row
                HStack {
                    HStack(spacing: 2) {
                        RoutePicker(tint: player.routeName == "This iPhone" ? UIColor(hex: 0xD4D4D8) : UIColor(hex: AppSettings.shared.accentHex))
                            .frame(width: 32, height: 44)
                        Text(player.routeName)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(player.routeName == "This iPhone" ? Color(hex: 0xD4D4D8) : accent)
                            .lineLimit(1)
                    }
                    .padding(.trailing, DriftGlass.isOn ? 12 : 0)
                    .padding(.leading, DriftGlass.isOn ? 4 : 0)
                    .frame(height: DriftGlass.isOn ? 38 : 44)
                    .driftGlass(in: Capsule(), interactive: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !player.qualityLabel.isEmpty {
                        Button { showStreamInfo = true } label: {
                            Text(player.qualityLabel.uppercased())
                                .font(.system(size: 10, weight: .heavy))
                                .tracking(0.5)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(hex: 0x71717A))
                                    .opacity(DriftGlass.isOn ? 0 : 1))
                                .padding(.horizontal, DriftGlass.isOn ? 4 : 0)
                                .padding(.vertical, DriftGlass.isOn ? 3 : 0)
                                .driftGlass(in: Capsule())
                                .foregroundStyle(Color(hex: 0xE4E4E7))
                                .fixedSize()
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(player.qualityLabel), stream info")
                        .sheet(isPresented: $showStreamInfo) { StreamInfoSheet() }
                    }

                    // Listen Together (lit, with how many, while in a session).
                    let jam = JamSession.shared.state
                    Button { showJam = true } label: {
                        HStack(spacing: 3) {
                            Image(systemName: jam != nil ? "person.2.fill" : "person.2")
                                .font(.system(size: 16))
                            if let jam {
                                Text("\(jam.members.count)").font(.system(size: 12, weight: .bold))
                            }
                        }
                        .foregroundStyle(jam != nil ? accent : Theme.text)
                        .padding(.horizontal, DriftGlass.isOn ? 12 : 6)
                        .frame(height: DriftGlass.isOn ? 38 : 44)
                        .driftGlass(in: Capsule(), interactive: true)
                        .frame(height: 44)
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel(jam != nil ? "Listening together, \(jam!.members.count) people" : "Listen together")
                    .sheet(isPresented: $showJam) { JamSheet() }

                    Button { showQueue = true } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(.horizontal, DriftGlass.isOn ? 12 : 6)
                            .frame(height: DriftGlass.isOn ? 38 : 44)
                            .driftGlass(in: Capsule(), interactive: true)
                            .frame(height: 44)
                            .fixedSize()
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Queue")
                    .sheet(isPresented: $showQueue) { QueueSheet() }

                    if t.isFeedEpisode {
                        // Episodes from a show's feed are audio only.
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 44)
                    } else if t.isEpisode {
                        // Where songs have Lyrics: turns the episode's video on or off.
                        let on = AppSettings.shared.podcastVideo
                        Button { AppSettings.shared.podcastVideo.toggle() } label: {
                            HStack(spacing: 6) {
                                Text("Video").font(.system(size: 12, weight: .bold))
                                Image(systemName: on ? "play.rectangle.fill" : "play.rectangle")
                                    .font(.system(size: 18))
                            }
                            .foregroundStyle(on ? accent : Theme.text)
                            .padding(.horizontal, DriftGlass.isOn ? 14 : 0)
                            .frame(height: DriftGlass.isOn ? 38 : 44)
                            .driftGlass(in: Capsule(), interactive: true)
                            .frame(height: 44)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityLabel(on ? "Hide video" : "Show video")
                    } else {
                    Button { showLyrics = true } label: {
                        HStack(spacing: 6) {
                            Text("Lyrics").font(.system(size: 12, weight: .bold))
                            Image(systemName: "quote.bubble")
                                .font(.system(size: 18))
                        }
                        .padding(.horizontal, DriftGlass.isOn ? 14 : 0)
                        .frame(height: DriftGlass.isOn ? 38 : 44)
                        .driftGlass(in: Capsule(), interactive: true)
                        .frame(height: 44)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityLabel("Show lyrics")
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    /// Previous, current and next artwork side by side; the drag pulls the neighbour in, like Spotify.
    private func artworkCarousel(_ t: Track, size: CGFloat) -> some View {
        let step = size + 32
        let prev = player.previousInQueue
        let next = player.nextInQueue
        let offset = drag.x + settle
        // Nothing on that side: resist instead of sliding freely.
        func resisted(_ x: CGFloat) -> CGFloat {
            (x > 0 && prev == nil) || (x < 0 && next == nil) ? x / 3 : x
        }
        // Each cover belongs to its song (not to a left/middle/right slot), so the cover you
        // swipe in stays on screen with its image already loaded: no flash of the old artwork.
        var covers: [(track: Track, base: CGFloat)] = [(t, 0)]
        if let prev, prev.id != t.id { covers.insert((prev, -step), at: 0) }
        if let next, next.id != t.id, next.id != prev?.id { covers.append((next, step)) }
        return ZStack {
            ForEach(covers, id: \.track.id) { cover in
                ArtworkView(url: cover.track.artwork(size: 800), size: size, corner: 8, seed: cover.track.id)
                    .shadow(color: .black.opacity(cover.base == 0 ? 0.45 : 0), radius: 25, y: 16)
                    .offset(x: offset + cover.base)
            }
        }
        .frame(height: size)
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 8)
            .updating($drag) { v, state, _ in
                if state.axis == nil {
                    state.axis = abs(v.translation.width) > abs(v.translation.height) ? .horizontal : .vertical
                }
                guard state.axis == .horizontal else { return }
                state.x = resisted(v.translation.width)
            }
            .onEnded { v in
                guard abs(v.translation.width) > abs(v.translation.height) else { return }
                // Take over from the finger exactly where it let go.
                instantly { settle = resisted(v.translation.width) }
                let x = v.predictedEndTranslation.width
                if x < -step / 3, next != nil {
                    withAnimation(.easeOut(duration: 0.22)) { settle = -step } completion: {
                        player.next()
                        instantly { settle = 0 }
                    }
                } else if x > step / 3, prev != nil {
                    withAnimation(.easeOut(duration: 0.22)) { settle = step } completion: {
                        player.skipToPrevious()
                        instantly { settle = 0 }
                    }
                } else {
                    withAnimation(.spring(duration: 0.3)) { settle = 0 }
                }
            })
    }

    /// Change without animating (the new song's artwork is already where the old one was).
    private func instantly(_ change: () -> Void) {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx, change)
    }

    private var playButton: some View {
        Button { player.togglePlay() } label: {
            ZStack {
                Circle().fill(Theme.text)
                if player.isBuffering && !player.isPlaying {
                    ProgressView().tint(Theme.bg)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.bg)
                }
            }
            .frame(width: 72, height: 72)
        }
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }

    /// Speed · back 15 · play · forward 30.
    private var episodeControls: some View {
        HStack {
            Menu {
                ForEach(Player.speeds, id: \.self) { s in
                    Button {
                        player.setSpeed(s)
                    } label: {
                        if s == player.speed {
                            Label(speedText(s), systemImage: "checkmark")
                        } else {
                            Text(speedText(s))
                        }
                    }
                }
            } label: {
                Text(speedText(player.speed))
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .foregroundStyle(player.speed == 1 ? Color(hex: 0xD4D4D8) : accent)
                    .frame(width: 52, height: 44)
            }
            .accessibilityLabel("Playback speed \(speedText(player.speed))")
            Spacer()
            Button { player.skip(by: -15) } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 30))
                    .frame(width: 52, height: 52)
            }
            .accessibilityLabel("Back 15 seconds")
            Spacer()
            playButton
            Spacer()
            Button { player.skip(by: 30) } label: {
                Image(systemName: "goforward.30")
                    .font(.system(size: 30))
                    .frame(width: 52, height: 52)
            }
            .accessibilityLabel("Forward 30 seconds")
            Spacer()
            if player.chapters.isEmpty {
                Color.clear.frame(width: 52, height: 44)
            } else {
                Button { showChapters = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 52, height: 44)
                }
                .accessibilityLabel("Chapters")
            }
        }
        .buttonStyle(.plain)
    }

    private var chapterMarkers: [Double] {
        guard player.isEpisode, player.duration > 0 else { return [] }
        return player.chapters.dropFirst().map { $0.start / player.duration }
    }

    private func speedText(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s))×" : String(format: "%g×", s)
    }

    private var repeatLabel: String {
        switch player.repeatMode {
        case .off: "Repeat off"
        case .all: "Repeat all"
        case .one: "Repeat one"
        }
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: 0xFF6B5B))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: 0xE4E4E7))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Try again") { player.retry() }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(accent)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 12)
        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .transition(.opacity)
    }

    private func toast(_ text: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(accent)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: 0xE4E4E7))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.black.opacity(0.3), in: Capsule())
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
}

struct ScrubBar: View {
    var progress: Double
    /// Positions (0...1) of chapter starts, drawn as small gaps in the bar.
    var markers: [Double] = []
    var onChange: (Double) -> Void
    var onEnd: (Double) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let x = w * min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: dragging ? 6 : 4)
                Capsule().fill(Theme.text).frame(width: x, height: dragging ? 6 : 4)
                ForEach(Array(markers.enumerated()), id: \.offset) { _, m in
                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: 2, height: dragging ? 6 : 4)
                        .offset(x: w * min(max(m, 0), 1) - 1)
                }
                Circle().fill(Theme.text)
                    .frame(width: dragging ? 16 : 12, height: dragging ? 16 : 12)
                    .offset(x: x - (dragging ? 8 : 6))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                dragging = true
                onChange(min(max(v.location.x / w, 0), 1))
            }.onEnded { v in
                dragging = false
                onEnd(min(max(v.location.x / w, 0), 1))
            })
            .animation(.easeOut(duration: 0.15), value: dragging)
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

/// AirPlay / Bluetooth / CarPlay output picker.
struct RoutePicker: UIViewRepresentable {
    var tint: UIColor

    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        v.tintColor = tint
        v.activeTintColor = tint
        return v
    }

    func updateUIView(_ v: AVRoutePickerView, context: Context) {
        v.tintColor = tint
        v.activeTintColor = tint
    }
}

/// Every chapter of the current episode; tap one to jump there.
struct ChaptersSheet: View {
    @Environment(\.dismiss) private var dismiss
    private var player: Player { .shared }
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(player.chapters.enumerated()), id: \.offset) { i, ch in
                        let isCurrent = i == player.chapterIndex
                        Button {
                            player.seekToChapter(i)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Text(formatTime(ch.start))
                                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(isCurrent ? accent : Theme.muted)
                                    .frame(width: 64, alignment: .leading)
                                Text(ch.title)
                                    .font(.system(size: 15, weight: isCurrent ? .bold : .medium))
                                    .foregroundStyle(isCurrent ? accent : Theme.text)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                if isCurrent {
                                    Image(systemName: "waveform")
                                        .foregroundStyle(accent)
                                        .accessibilityLabel("Playing")
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.bg)
                        .id(i)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onAppear {
                    if let i = player.chapterIndex { proxy.scrollTo(i, anchor: .center) }
                }
            }
            .background(Theme.bg)
            .foregroundStyle(Theme.text)
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .tint(accent)
    }
}

/// One artwork drag: which way it's going and how far.
struct SwipeDrag {
    var axis: Axis?
    var x: CGFloat = 0
}


/// What's actually playing: which YouTube video, its length and how the album version was found.
struct StreamInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    private var player: Player { .shared }

    var body: some View {
        NavigationStack {
            List {
                if let t = player.current {
                    Section {
                        Text("\(t.title) · \(t.artist)").font(.system(size: 15, weight: .semibold))
                    }
                }
                Section {
                    ForEach(Array(player.streamInfo.enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(line.0).font(.system(size: 12)).foregroundStyle(.secondary)
                            Text(line.1).font(.system(size: 14).monospaced()).textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
                Section {
                    Button(copied ? "Copied" : "Copy all") {
                        let title = player.current.map { "\($0.title) - \($0.artist)\n" } ?? ""
                        UIPasteboard.general.string = title + player.streamInfo.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
                        copied = true
                    }
                }
            }
            .navigationTitle("Stream info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}


/// The iPhone's volume as a slider (Apple Music style player).
struct VolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: .zero)
        v.tintColor = .white
        v.setVolumeThumbImage(UIImage(), for: .normal)
        return v
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
