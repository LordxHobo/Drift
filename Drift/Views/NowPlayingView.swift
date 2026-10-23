import SwiftUI
import AVKit

struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var bg: Color = Theme.playerFallback
    @State private var scrub: Double?
    @State private var dragDown: CGFloat = 0
    @State private var showLyrics = false
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
    }

    @ViewBuilder
    private func content(_ t: Track) -> some View {
        GeometryReader { geo in
            let artSize = min(geo.size.width - 48, geo.size.height * 0.45)
            VStack(spacing: 22) {
                // Header
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 44, height: 44)
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
                    }
                    .accessibilityLabel("More options")
                }
                .padding(.horizontal, -10)

                // Artwork (16:9 for podcast episodes)
                Group {
                    if t.isEpisode {
                        EpisodeArtwork(url: t.artworkURL ?? t.artwork(size: 800), width: geo.size.width - 48, corner: 8)
                    } else {
                        ArtworkView(url: t.artwork(size: 800), size: artSize, corner: 8, seed: t.id)
                    }
                }
                    .shadow(color: .black.opacity(0.45), radius: 25, y: 16)
                    .frame(maxWidth: .infinity)
                    .id(t.id)
                    .gesture(DragGesture(minimumDistance: 30).onEnded { v in
                        guard abs(v.translation.width) > abs(v.translation.height) else { return }
                        if v.translation.width < -60 { player.next() }
                        if v.translation.width > 60 { player.previous() }
                    })

                Spacer(minLength: 0)

                // Title
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title)
                            .font(.system(size: 22, weight: .heavy))
                            .tracking(-0.3)
                            .lineLimit(1)
                        Text(t.artist)
                            .font(.system(size: 15))
                            .foregroundStyle(Color(hex: 0xD4D4D8))
                            .lineLimit(1)
                    }
                    Spacer()
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

                // Progress
                VStack(spacing: 6) {
                    ScrubBar(progress: scrub ?? player.progress, onChange: { scrub = $0 }, onEnd: { p in
                        player.seek(to: p * player.duration)
                        scrub = nil
                    })
                    HStack {
                        Text(formatTime((scrub ?? player.progress) * player.duration))
                        Spacer()
                        Text(formatTime(player.duration))
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
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: 28))
                            .frame(width: 52, height: 52)
                    }
                    .accessibilityLabel("Previous")
                    Spacer()
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
                    Spacer()
                    Button { player.next() } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 28))
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

                // Skip / error toast
                Group {
                    if let msg = player.errorMessage {
                        toast(msg, icon: "exclamationmark.triangle.fill")
                    } else if let msg = player.skipMessage {
                        toast(msg, icon: "forward.frame.fill")
                    } else {
                        Color.clear
                    }
                }
                .frame(height: 30)
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
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !player.qualityLabel.isEmpty {
                        Text(player.qualityLabel.uppercased())
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(0.5)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(hex: 0x71717A)))
                            .foregroundStyle(Color(hex: 0xE4E4E7))
                            .fixedSize()
                    }

                    if t.isEpisode {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 44)
                    } else {
                    Button { showLyrics = true } label: {
                        HStack(spacing: 6) {
                            Text("Lyrics").font(.system(size: 12, weight: .bold))
                            Image(systemName: "quote.bubble")
                                .font(.system(size: 18))
                        }
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
            Color.clear.frame(width: 52, height: 44)
        }
        .buttonStyle(.plain)
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
