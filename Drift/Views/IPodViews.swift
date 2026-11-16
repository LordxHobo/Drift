import AudioToolbox
import AVFoundation
import MediaPlayer
import SwiftUI

// The iPod theme: Cover Flow and a click wheel, one thumb at a time. Menu (top of the ring) goes back,
// the centre button selects, play/pause and skipping sit on the ring. Now playing: the wheel sets the
// volume, and Select switches it to seeking (back to volume a few seconds after you stop).

/// One place to browse.
enum IPodScreen: Hashable {
    case menu
    case covers(IPodShelf)
    case songs(title: String, tracks: [Track])
    case nowPlaying
}

enum IPodShelf: Hashable {
    case playlists, albums, artists

    var title: String {
        switch self {
        case .playlists: "Playlists"
        case .albums: "Albums"
        case .artists: "Artists"
        }
    }
}

/// An album, playlist or artist in Cover Flow.
struct IPodCover: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let tracks: [Track]
    var playlist: Playlist?
}

/// A row of the main menu.
private struct IPodMenuItem: Identifiable {
    let id: String
    let title: String
    let action: () -> Void
}

// MARK: Feel: ticks and clicks

@MainActor
enum IPodFeel {
    private static let selection = UISelectionFeedbackGenerator()
    private static let press = UIImpactFeedbackGenerator(style: .medium)
    private static let edge = UIImpactFeedbackGenerator(style: .soft)

    static func ready() {
        selection.prepare()
        press.prepare()
    }

    /// One step of the wheel.
    static func tick() {
        if AppSettings.shared.ipodHaptics { selection.selectionChanged() }
        // The keyboard's click (quiet with the silent switch on).
        if AppSettings.shared.ipodClicks { AudioServicesPlaySystemSound(1104) }
    }

    /// A button on the wheel.
    static func pressed() {
        if AppSettings.shared.ipodHaptics { press.impactOccurred() }
        if AppSettings.shared.ipodClicks { AudioServicesPlaySystemSound(1104) }
    }

    /// The end of a list: can't go further.
    static func bump() {
        if AppSettings.shared.ipodHaptics { edge.impactOccurred(intensity: 0.6) }
    }
}

// MARK: The phone's volume

/// The phone's own volume (what the side buttons change). iOS only lets apps set it through its volume
/// view, so one sits hidden on the iPod screen; it also keeps iOS's volume pop-up away while the wheel turns.
@Observable @MainActor
final class SystemVolume {
    static let shared = SystemVolume()
    private(set) var level: Float = AVAudioSession.sharedInstance().outputVolume
    @ObservationIgnored weak var view: MPVolumeView?
    @ObservationIgnored private var watch: NSKeyValueObservation?

    private init() {
        watch = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { _, change in
            guard let v = change.newValue else { return }
            Task { @MainActor in SystemVolume.shared.level = v }
        }
    }

    func change(by delta: Float) {
        let v = min(1, max(0, level + delta))
        level = v
        guard let slider = view?.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.setValue(v, animated: false)
        slider.sendActions(for: .valueChanged)
    }
}

private struct VolumeHost: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: CGRect(x: -200, y: -200, width: 10, height: 10))
        v.alpha = 0.01
        v.isUserInteractionEnabled = false
        SystemVolume.shared.view = v
        return v
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

// MARK: The theme

struct IPodRoot: View {
    @State private var stack: [IPodScreen] = [.menu]
    @State private var picks: [Int] = [0]
    @State private var sheet: Sheet?
    @State private var seeking = false
    @State private var lastTurn = Date()
    private var player: Player { .shared }
    private var library: Library { .shared }
    private var settings: AppSettings { .shared }

    enum Sheet: String, Identifiable {
        case search, settings
        var id: String { rawValue }
    }

    private var screen: IPodScreen { stack.last ?? .menu }
    private var pick: Int { picks.last ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            nowPlayingChip
            ClickWheel(
                onTurn: turn,
                onMenu: menu,
                onSelect: select,
                onPrevious: { player.skipToPrevious() },
                onNext: { player.next() },
                onPlayPause: { player.togglePlay() },
                playing: player.isPlaying
            )
            .padding(.bottom, 18)
        }
        .background(Theme.bg.ignoresSafeArea())
        .background(VolumeHost().frame(width: 1, height: 1))
        .onAppear { IPodFeel.ready() }
        .sheet(item: $sheet) { s in
            switch s {
            case .search: NavigationStack { SearchView().withRoutes() }
            case .settings: NavigationStack { SettingsView().withRoutes() }
            }
        }
        // Seeking goes back to the volume a few seconds after the wheel was last turned (like the iPod).
        .task(id: lastTurn) {
            guard seeking else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { seeking = false }
        }
        .onChange(of: player.current?.id) { _, new in
            // Nothing playing any more: leave the now playing screen.
            if new == nil, screen == .nowPlaying { menu() }
        }
    }

    // MARK: Top

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(crumb)
                Spacer()
                if let p = position { Text(p).monospacedDigit() }
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.muted)
            Text(title)
                .font(.system(size: 30, weight: .heavy))
                .lineLimit(1)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        switch screen {
        case .menu: "Drift"
        case .covers(let shelf): shelf.title
        case .songs(let t, _): t
        case .nowPlaying: "Now playing"
        }
    }

    private var crumb: String {
        stack.count < 2 ? "iPod" : stack.dropLast().map { s -> String in
            switch s {
            case .menu: "Drift"
            case .covers(let shelf): shelf.title
            case .songs(let t, _): t
            case .nowPlaying: "Now playing"
            }
        }.joined(separator: " › ")
    }

    private var position: String? {
        let n = count(of: screen)
        guard n > 0, screen != .nowPlaying else { return nil }
        return "\(pick + 1) of \(n)"
    }

    @ViewBuilder private var content: some View {
        switch screen {
        case .menu:
            IPodList(rows: menuItems.map { ($0.id, $0.title, String?.none, String?.none) }, selected: pick)
        case .covers(let shelf):
            let items = covers(shelf)
            if items.isEmpty {
                Text(shelf == .albums ? "Albums you save show up here." : "Nothing here yet.")
                    .foregroundStyle(Theme.muted)
            } else {
                CoverFlow(items: items, selected: min(pick, items.count - 1))
            }
        case .songs(_, let tracks):
            if tracks.isEmpty {
                Text("No songs.").foregroundStyle(Theme.muted)
            } else {
                IPodList(rows: tracks.enumerated().map { i, t in ("\(i)-\(t.id)", t.title, Optional(t.artist), t.duration.map { time($0) }) },
                         selected: min(pick, tracks.count - 1))
            }
        case .nowPlaying:
            IPodNowPlaying(seeking: seeking)
        }
    }

    @ViewBuilder private var nowPlayingChip: some View {
        if let t = player.current, screen != .nowPlaying {
            Button {
                IPodFeel.pressed()
                push(.nowPlaying)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(settings.accent)
                    Text(t.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(t.artist).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Theme.surface, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)
            .accessibilityLabel("Now playing: \(t.title)")
        } else {
            Color.clear.frame(height: 16)
        }
    }

    // MARK: What's in each place

    private var menuItems: [IPodMenuItem] {
        var items: [IPodMenuItem] = []
        if player.current != nil { items.append(.init(id: "now", title: "Now playing") { push(.nowPlaying) }) }
        items += [
            .init(id: "playlists", title: "Playlists") { push(.covers(.playlists)) },
            .init(id: "albums", title: "Albums") { push(.covers(.albums)) },
            .init(id: "artists", title: "Artists") { push(.covers(.artists)) },
            .init(id: "songs", title: "Songs") { push(.songs(title: "Songs", tracks: library.allSongs)) },
            .init(id: "liked", title: "Liked songs") { push(.songs(title: "Liked songs", tracks: library.liked)) },
            .init(id: "recent", title: "Recently played") { push(.songs(title: "Recently played", tracks: library.recent)) },
            .init(id: "downloads", title: "Downloads") { push(.songs(title: "Downloads", tracks: library.downloaded)) },
            .init(id: "search", title: "Search") { sheet = .search },
            .init(id: "settings", title: "Settings") { sheet = .settings },
        ]
        return items
    }

    private func covers(_ shelf: IPodShelf) -> [IPodCover] {
        switch shelf {
        case .playlists:
            return library.playlists.filter { $0.isAlbum != true }.map {
                IPodCover(id: $0.id.uuidString, title: $0.name, subtitle: "\($0.tracks.count) songs", tracks: $0.tracks, playlist: $0)
            }
        case .albums:
            return library.playlists.filter { $0.isAlbum == true }.map {
                IPodCover(id: $0.id.uuidString, title: $0.name, subtitle: $0.albumArtist ?? "", tracks: $0.tracks, playlist: $0)
            }
        case .artists:
            var order: [String] = []
            var songs: [String: [Track]] = [:]
            for t in library.allSongs {
                let name = t.artist.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                if songs[name] == nil { order.append(name) }
                songs[name, default: []].append(t)
            }
            return order.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
                let list = songs[name] ?? []
                return IPodCover(id: "artist-" + name, title: name, subtitle: list.count == 1 ? "1 song" : "\(list.count) songs", tracks: list)
            }
        }
    }

    private func count(of s: IPodScreen) -> Int {
        switch s {
        case .menu: menuItems.count
        case .covers(let shelf): covers(shelf).count
        case .songs(_, let tracks): tracks.count
        case .nowPlaying: 0
        }
    }

    // MARK: The wheel and its buttons

    private func push(_ s: IPodScreen) {
        stack.append(s)
        picks.append(0)
    }

    private func turn(_ steps: Int) {
        if screen == .nowPlaying {
            if seeking {
                player.seek(to: max(0, min(player.duration, player.currentTime + Double(steps) * 5)))
            } else {
                SystemVolume.shared.change(by: Float(steps) / 32)
            }
            lastTurn = Date()
            IPodFeel.tick()
            return
        }
        let n = count(of: screen)
        guard n > 0 else { return }
        let moved = min(n - 1, max(0, pick + steps))
        if moved == pick {
            IPodFeel.bump()
            return
        }
        withAnimation(.easeOut(duration: 0.2)) { picks[picks.count - 1] = moved }
        IPodFeel.tick()
    }

    /// Menu: back up one place (like the iPod).
    private func menu() {
        guard stack.count > 1 else { return }
        seeking = false
        withAnimation(.easeOut(duration: 0.2)) {
            stack.removeLast()
            picks.removeLast()
        }
    }

    /// The centre button.
    private func select() {
        switch screen {
        case .menu:
            let items = menuItems
            guard pick < items.count else { return }
            items[pick].action()
        case .covers(let shelf):
            let items = covers(shelf)
            guard pick < items.count else { return }
            let c = items[pick]
            push(.songs(title: c.title, tracks: c.tracks))
        case .songs(let title, let tracks):
            guard pick < tracks.count else { return }
            player.play(tracks, startAt: pick, from: title)
            push(.nowPlaying)
        case .nowPlaying:
            seeking.toggle()
            lastTurn = Date()
        }
    }

    private func time(_ s: Double) -> String {
        let t = Int(s)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: Lists (menus and songs)

private struct IPodList: View {
    /// id, title, subtitle, trailing text.
    let rows: [(String, String, String?, String?)]
    let selected: Int
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element.0) { i, row in
                        let on = i == selected
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.1).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                                if let sub = row.2 {
                                    Text(sub).font(.system(size: 12)).lineLimit(1).opacity(0.7)
                                }
                            }
                            Spacer(minLength: 8)
                            if let trailing = row.3 {
                                Text(trailing).font(.system(size: 13).monospacedDigit()).opacity(0.7)
                            } else if row.2 == nil {
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).opacity(0.6)
                            }
                        }
                        .foregroundStyle(on ? Color.black : Theme.text)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 46)
                        .background(on ? accent : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .id(i)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .scrollDisabled(true)
            .onChange(of: selected) { _, new in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(new, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
        }
    }
}

// MARK: Cover Flow

private struct CoverFlow: View {
    let items: [IPodCover]
    let selected: Int

    var body: some View {
        GeometryReader { geo in
            let big = min(geo.size.width * 0.58, geo.size.height - 90)
            let small = big * 0.74
            VStack(spacing: 14) {
                ZStack {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        let d = i - selected
                        if abs(d) <= 4 {
                            let side = Double(d.signum())
                            let size = d == 0 ? big : small
                            art(item, size: size)
                                .shadow(color: .black.opacity(0.5), radius: 16, y: 12)
                                .rotation3DEffect(.degrees(d == 0 ? 0 : -side * 62), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                                .offset(x: d == 0 ? 0 : side * (big * 0.55 + Double(abs(d) - 1) * small * 0.28),
                                        y: d == 0 ? 0 : (big - small) / 2)
                                .zIndex(Double(10 - abs(d)))
                                .opacity(abs(d) >= 4 ? 0 : abs(d) == 3 ? 0.45 : 1)
                        }
                    }
                }
                .frame(width: geo.size.width, height: big)
                .animation(.easeOut(duration: 0.22), value: selected)

                if items.indices.contains(selected) {
                    VStack(spacing: 4) {
                        Text(items[selected].title).font(.system(size: 19, weight: .bold)).lineLimit(1)
                        Text(items[selected].subtitle).font(.system(size: 14)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    .padding(.horizontal, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func art(_ item: IPodCover, size: CGFloat) -> some View {
        if let p = item.playlist {
            PlaylistArt(playlist: p, size: size, corner: 10)
        } else {
            ArtworkView(url: item.tracks.first?.artwork(size: 600), size: size, corner: 10, seed: item.id)
        }
    }
}

// MARK: Now playing

private struct IPodNowPlaying: View {
    let seeking: Bool
    private var player: Player { .shared }
    private var volume: SystemVolume { .shared }
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width * 0.6, geo.size.height - 150)
            VStack(spacing: 12) {
                if let t = player.current {
                    ArtworkView(url: t.artwork(size: 600), size: max(80, size), corner: 12, seed: t.id)
                        .shadow(color: .black.opacity(0.5), radius: 18, y: 12)
                    VStack(spacing: 3) {
                        Text(t.title).font(.system(size: 19, weight: .bold)).lineLimit(1)
                        Text([t.artist, t.album ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 14)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    .padding(.horizontal, 24)
                    VStack(spacing: 6) {
                        bar(player.duration > 0 ? player.currentTime / player.duration : 0, on: seeking)
                        HStack {
                            Text(time(player.currentTime))
                            Spacer()
                            Text("-" + time(max(0, player.duration - player.currentTime)))
                        }
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 28)
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.fill").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        bar(Double(volume.level), on: !seeking)
                        Image(systemName: "speaker.wave.3.fill").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 28)
                    HStack(spacing: 6) {
                        Text("Wheel:").foregroundStyle(Theme.muted)
                        Text(seeking ? "Seeking" : "Volume").fontWeight(.bold).foregroundStyle(accent)
                        Text("· press the centre to switch").foregroundStyle(Theme.muted)
                    }
                    .font(.system(size: 12))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func bar(_ fraction: Double, on: Bool) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface2)
                Capsule().fill(on ? accent : Theme.text2).frame(width: g.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 6)
    }

    private func time(_ s: Double) -> String {
        let t = Int(max(0, s))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: The click wheel

struct ClickWheel: View {
    var onTurn: (Int) -> Void
    var onMenu: () -> Void
    var onSelect: () -> Void
    var onPrevious: () -> Void
    var onNext: () -> Void
    var onPlayPause: () -> Void
    var playing: Bool
    /// Degrees per step (about 24 steps a turn, like the iPod).
    var step: Double = 15
    @State private var last: Double?
    @State private var turned: Double = 0
    @State private var finger: Double?

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            let r = d / 2
            ZStack {
                Circle()
                    .fill(Theme.surface)
                    .overlay(Circle().stroke(Theme.line, lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 20, y: 14)
                    .contentShape(Circle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in drag(v.location, center: CGPoint(x: r, y: r), radius: r) }
                        .onEnded { _ in
                            last = nil
                            turned = 0
                            withAnimation(.easeOut(duration: 0.3)) { finger = nil }
                        })
                if let finger {
                    Circle()
                        .fill(AppSettings.shared.accent)
                        .frame(width: 12, height: 12)
                        .offset(y: -(r - 22))
                        .rotationEffect(.degrees(finger + 90))
                        .allowsHitTesting(false)
                }
                ringButton("MENU", system: nil, label: "Menu") { onMenu() }
                    .offset(y: -(r - 30))
                ringButton(nil, system: "backward.end.alt.fill", label: "Previous") { onPrevious() }
                    .offset(x: -(r - 30))
                ringButton(nil, system: "forward.end.alt.fill", label: "Next") { onNext() }
                    .offset(x: r - 30)
                ringButton(nil, system: "playpause.fill", label: playing ? "Pause" : "Play") { onPlayPause() }
                    .offset(y: r - 30)
                Button {
                    IPodFeel.pressed()
                    onSelect()
                } label: {
                    Circle()
                        .fill(Theme.surface2)
                        .overlay(Circle().stroke(Theme.line, lineWidth: 1))
                        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
                        .frame(width: d * 0.4, height: d * 0.4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Select")
            }
            .frame(width: d, height: d)
            .frame(maxWidth: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 300)
        .padding(.horizontal, 40)
    }

    private func ringButton(_ text: String?, system: String?, label: String, action: @escaping () -> Void) -> some View {
        Button {
            IPodFeel.pressed()
            action()
        } label: {
            Group {
                if let text {
                    Text(text).font(.system(size: 13, weight: .bold)).tracking(1.5)
                } else if let system {
                    Image(systemName: system).font(.system(size: 17, weight: .semibold))
                }
            }
            .foregroundStyle(Theme.text2)
            .frame(width: 60, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func drag(_ p: CGPoint, center c: CGPoint, radius r: CGFloat) {
        let dx = p.x - c.x, dy = p.y - c.y
        // Turning starts outside the centre button.
        guard dx * dx + dy * dy > (r * 0.2) * (r * 0.2) else { return }
        let angle = atan2(dy, dx) * 180 / .pi
        finger = angle
        guard let l = last else {
            last = angle
            IPodFeel.ready()
            return
        }
        var delta = angle - l
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        last = angle
        turned += delta
        var steps = 0
        while turned >= step { steps += 1; turned -= step }
        while turned <= -step { steps -= 1; turned += step }
        if steps != 0 { onTurn(steps) }
    }
}
