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
        layout
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

    // MARK: The four styles

    /// The same places and buttons, driven four ways.
    @ViewBuilder private var layout: some View {
        switch settings.ipodStyle {
        case .wheel:
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
        case .summoned:
            // Swipe to flip, tap to open; hold anywhere for a wheel under your thumb.
            VStack(spacing: 0) {
                header
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(IPodGestures(axis: swipeAxis, summon: true, onTurn: turn, onTap: select))
                IPodMiniBar(open: openNowPlaying)
            }
        case .crate:
            // A turntable on top (the song playing), the crate (or a list) below.
            VStack(spacing: 0) {
                IPodTurntable()
                header
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(IPodGestures(axis: .vertical, summon: false, onTurn: turn, onTap: select))
            }
        case .arc:
            // A dial rising from the bottom edge.
            GeometryReader { geo in
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        header
                        content
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        nowPlayingChip
                        Color.clear.frame(height: 196)
                    }
                    IPodArcDial(size: geo.size, onTurn: turn, onBack: menu, onSelect: select,
                                onPrevious: { player.skipToPrevious() }, onNext: { player.next() })
                }
            }
        }
    }

    /// Which way swiping flips: sideways through covers, up and down through lists.
    private var swipeAxis: Axis {
        if case .covers = screen { return .horizontal }
        return .vertical
    }

    private func openNowPlaying() {
        guard player.current != nil, screen != .nowPlaying else { return }
        IPodFeel.pressed()
        push(.nowPlaying)
    }

    // MARK: Top

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                // The click wheel has Menu on its ring; the other styles go back from here.
                if settings.ipodStyle != .wheel, stack.count > 1 {
                    Button {
                        IPodFeel.pressed()
                        menu()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
                            Text(crumbBack)
                        }
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                } else {
                    Text(crumb)
                }
                Spacer()
                if let p = position { Text(p).monospacedDigit() }
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.muted)
            Text(title)
                .font(.system(size: settings.ipodStyle == .crate ? 24 : 30, weight: .heavy))
                .lineLimit(1)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The place one back.
    private var crumbBack: String {
        guard stack.count > 1 else { return "" }
        switch stack[stack.count - 2] {
        case .menu: return "Drift"
        case .covers(let shelf): return shelf.title
        case .songs(let t, _): return t
        case .nowPlaying: return "Now playing"
        }
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
            } else if settings.ipodStyle == .crate {
                IPodCrate(items: items, selected: min(pick, items.count - 1))
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

// MARK: Turning, shared by the styles

/// Turns finger angles into steps (one per `step` degrees).
struct IPodTurns {
    var step: Double
    private var last: Double?
    private var turned: Double = 0

    init(step: Double) { self.step = step }

    /// Steps since the last angle (degrees; + clockwise).
    mutating func feed(_ angle: Double) -> Int {
        defer { last = angle }
        guard let l = last else { return 0 }
        var d = angle - l
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        turned += d
        var n = 0
        while turned >= step { n += 1; turned -= step }
        while turned <= -step { n -= 1; turned += step }
        return n
    }

    mutating func reset() {
        last = nil
        turned = 0
    }
}

// MARK: Summoned wheel (and the crate's flicking)

/// Swipe to flip (a step every so often along `axis`), tap to select, and, with `summon`, touch and hold
/// anywhere for a wheel under your thumb: circle to scroll, let go and it's gone.
private struct IPodGestures: View {
    let axis: Axis
    let summon: Bool
    var onTurn: (Int) -> Void
    var onTap: () -> Void
    @State private var began: Date?
    @State private var moved = false
    @State private var stepped: CGFloat = 0
    @State private var wheel: CGPoint?
    @State private var finger: Double?
    @State private var turns = IPodTurns(step: 22)
    @State private var hold: Task<Void, Never>?
    private let radius: CGFloat = 105

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged(changed)
                .onEnded(ended))
            .overlay {
                if let w = wheel {
                    ZStack {
                        Circle()
                            .fill(Theme.surface.opacity(0.92))
                            .overlay(Circle().stroke(AppSettings.shared.accent, lineWidth: 2))
                            .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                        if let finger {
                            Circle()
                                .fill(AppSettings.shared.accent)
                                .frame(width: 14, height: 14)
                                .offset(y: -(radius - 18))
                                .rotationEffect(.degrees(finger + 90))
                        }
                    }
                    .frame(width: radius * 2, height: radius * 2)
                    .position(w)
                    .allowsHitTesting(false)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Swipe to scroll, tap to open")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onTap() }
            .accessibilityAdjustableAction { direction in
                onTurn(direction == .increment ? 1 : -1)
            }
    }

    private func changed(_ v: DragGesture.Value) {
        if began == nil {
            began = Date()
            moved = false
            stepped = 0
            IPodFeel.ready()
            if summon {
                let at = v.startLocation
                hold?.cancel()
                hold = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(280))
                    guard !Task.isCancelled, !moved else { return }
                    turns.reset()
                    withAnimation(.easeOut(duration: 0.15)) { wheel = at }
                    IPodFeel.pressed()
                }
            }
        }
        if let w = wheel {
            let dx = v.location.x - w.x, dy = v.location.y - w.y
            guard dx * dx + dy * dy > 400 else { return }
            let angle = atan2(dy, dx) * 180 / .pi
            finger = angle
            let n = turns.feed(angle)
            if n != 0 { onTurn(n) }
            return
        }
        let t = v.translation
        if !moved, abs(t.width) > 10 || abs(t.height) > 10 {
            moved = true
            hold?.cancel()
        }
        guard moved else { return }
        // Up or left moves on (like scrolling content toward you).
        let along = axis == .horizontal ? -t.width : -t.height
        let size: CGFloat = axis == .horizontal ? 54 : 38
        while along - stepped >= size { onTurn(1); stepped += size }
        while along - stepped <= -size { onTurn(-1); stepped -= size }
    }

    private func ended(_ v: DragGesture.Value) {
        hold?.cancel()
        let quick = began.map { Date().timeIntervalSince($0) < 0.3 } ?? false
        if wheel != nil {
            withAnimation(.easeOut(duration: 0.2)) {
                wheel = nil
                finger = nil
            }
        } else if !moved, quick {
            IPodFeel.pressed()
            onTap()
        }
        began = nil
    }
}

/// The summoned wheel's mini player: what's playing (tap for Now playing), previous, play/pause, next.
private struct IPodMiniBar: View {
    var open: () -> Void
    private var player: Player { .shared }

    var body: some View {
        if let t = player.current {
            HStack(spacing: 10) {
                Button(action: open) {
                    HStack(spacing: 10) {
                        ArtworkView(url: t.artwork(size: 120), size: 44, corner: 8, seed: t.id)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            Text(t.artist).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Now playing: \(t.title)")
                barButton("backward.end.fill", "Previous") { player.skipToPrevious() }
                barButton(player.isPlaying ? "pause.fill" : "play.fill", player.isPlaying ? "Pause" : "Play") { player.togglePlay() }
                barButton("forward.end.fill", "Next") { player.next() }
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(height: 64)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        } else {
            Text("Touch and hold anywhere for the wheel")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .padding(.vertical, 18)
        }
    }

    private func barButton(_ icon: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button {
            IPodFeel.pressed()
            run()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: Record crate

/// Sleeves standing in a crate, the chosen one in front; the ones behind lean back.
private struct IPodCrate: View {
    let items: [IPodCover]
    let selected: Int

    var body: some View {
        GeometryReader { geo in
            let front = min(geo.size.width * 0.62, geo.size.height - 80)
            ZStack(alignment: .bottom) {
                ForEach(Array(items.enumerated()).reversed(), id: \.element.id) { i, item in
                    let k = i - selected
                    if k >= 0 && k <= 3 {
                        let size = front - CGFloat(k) * 18
                        sleeve(item, size: size)
                            .brightness(-0.12 * Double(k))
                            .rotation3DEffect(.degrees(k == 0 ? 4 : 16), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                            .offset(y: -(70 + CGFloat(k) * 26))
                            .zIndex(Double(10 - k))
                    }
                }
                // The crate's front, with what's in front.
                VStack(spacing: 3) {
                    if items.indices.contains(selected) {
                        Text(items[selected].title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                        Text(items[selected].subtitle).font(.system(size: 12)).opacity(0.8).lineLimit(1)
                    }
                }
                .foregroundStyle(Color(red: 0.95, green: 0.9, blue: 0.85))
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .background(Color(red: 0.23, green: 0.17, blue: 0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .top) {
                    Rectangle().fill(Color(red: 0.35, green: 0.27, blue: 0.19)).frame(height: 3)
                }
                .shadow(color: .black.opacity(0.5), radius: 14, y: -6)
                .padding(.horizontal, 30)
                .padding(.bottom, 12)
                .zIndex(20)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.easeOut(duration: 0.2), value: selected)
        }
    }

    @ViewBuilder private func sleeve(_ item: IPodCover, size: CGFloat) -> some View {
        if let p = item.playlist {
            PlaylistArt(playlist: p, size: size, corner: 6)
        } else {
            ArtworkView(url: item.tracks.first?.artwork(size: 600), size: size, corner: 6, seed: item.id)
        }
    }
}

/// The crate's turntable: the song playing spins on it; drag the record round to seek.
private struct IPodTurntable: View {
    @State private var dragAngle: Double?
    @State private var scratch: Double = 0
    @State private var spinAt: Double = 0
    private var player: Player { .shared }

    var body: some View {
        HStack(spacing: 16) {
            record
            VStack(alignment: .leading, spacing: 6) {
                if let t = player.current {
                    Text(t.title).font(.system(size: 16, weight: .bold)).lineLimit(2)
                    Text(t.artist).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                    Text("\(time(player.currentTime + scratch)) / \(time(player.duration))")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                } else {
                    Text("Nothing playing").font(.system(size: 15, weight: .semibold))
                    Text("Tap a sleeve to put it on").font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                HStack(spacing: 4) {
                    button("backward.end.fill", "Previous") { player.skipToPrevious() }
                    button(player.isPlaying ? "pause.fill" : "play.fill", player.isPlaying ? "Pause" : "Play") { player.togglePlay() }
                    button("forward.end.fill", "Next") { player.next() }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private var record: some View {
        let size: CGFloat = 150
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !player.isPlaying || dragAngle != nil)) { ctx in
            let spin = player.isPlaying && dragAngle == nil
                ? (ctx.date.timeIntervalSinceReferenceDate * 200).truncatingRemainder(dividingBy: 360) : spinAt
            ZStack {
                Circle()
                    .fill(Color(white: 0.07))
                    .overlay(
                        ForEach(0..<9) { i in
                            Circle().stroke(Color(white: 0.13), lineWidth: 1).padding(CGFloat(8 + i * 6))
                        }
                    )
                if let t = player.current {
                    ArtworkView(url: t.artwork(size: 200), size: 56, corner: 28, seed: t.id)
                        .overlay(Circle().fill(Theme.bg).frame(width: 6, height: 6))
                } else {
                    Circle().fill(Theme.surface2).frame(width: 56, height: 56)
                }
            }
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin + (dragAngle ?? 0)))
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.6), radius: 10, y: 6)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 4)
            .onChanged { v in
                let c = CGPoint(x: size / 2, y: size / 2)
                let a0 = atan2(v.startLocation.y - c.y, v.startLocation.x - c.x) * 180 / .pi
                let a1 = atan2(v.location.y - c.y, v.location.x - c.x) * 180 / .pi
                var d = a1 - a0
                if d > 180 { d -= 360 }
                if d < -180 { d += 360 }
                if dragAngle == nil {
                    spinAt = (Date().timeIntervalSinceReferenceDate * 200).truncatingRemainder(dividingBy: 360)
                    IPodFeel.ready()
                }
                let old = Int(scratch / 2)
                dragAngle = d
                // A full turn of the record: 8 seconds of the song.
                scratch = d / 360 * 8
                if Int(scratch / 2) != old { IPodFeel.tick() }
            }
            .onEnded { _ in
                if player.current != nil {
                    player.seek(to: max(0, min(player.duration, player.currentTime + scratch)))
                }
                spinAt += dragAngle ?? 0
                dragAngle = nil
                scratch = 0
            })
        .accessibilityLabel("Record: drag round to seek")
    }

    private func button(_ icon: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button {
            IPodFeel.pressed()
            run()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 44, height: 40)
                .background(Theme.surface2, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func time(_ s: Double) -> String {
        let t = Int(max(0, s))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: Thumb arc

/// A dial rising from the bottom edge: its ticks turn under your thumb; Select in the notch, previous and
/// next at its ends; swipe down on it to go back.
private struct IPodArcDial: View {
    let size: CGSize
    var onTurn: (Int) -> Void
    var onBack: () -> Void
    var onSelect: () -> Void
    var onPrevious: () -> Void
    var onNext: () -> Void
    @State private var rotation: Double = 0
    @State private var turns = IPodTurns(step: 12)
    @State private var gestureTurned: Double = 0
    @State private var gestureSteps = 0
    /// How much of the dial shows.
    private let visible: CGFloat = 196

    var body: some View {
        let d = size.width * 1.45
        let top = size.height - visible
        ZStack(alignment: .top) {
            ZStack {
                Circle()
                    .fill(Theme.surface)
                    .overlay(Circle().stroke(Theme.line, lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 18, y: -8)
                ForEach(0..<72, id: \.self) { i in
                    Capsule()
                        .fill(i % 3 == 0 ? Theme.muted.opacity(0.7) : Theme.line)
                        .frame(width: 2, height: i % 3 == 0 ? 16 : 9)
                        .offset(y: -(d / 2 - 14))
                        .rotationEffect(.degrees(Double(i) * 5))
                }
                .rotationEffect(.degrees(rotation))
            }
            .frame(width: d, height: d)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let c = CGPoint(x: d / 2, y: d / 2)
                    let angle = atan2(v.location.y - c.y, v.location.x - c.x) * 180 / .pi
                    let before = rotation
                    let n = turns.feed(angle)
                    // The ticks follow the thumb.
                    if let last = lastAngle {
                        var delta = angle - last
                        if delta > 180 { delta -= 360 }
                        if delta < -180 { delta += 360 }
                        rotation = before + delta
                        gestureTurned += abs(delta)
                    } else {
                        IPodFeel.ready()
                    }
                    lastAngle = angle
                    if n != 0 {
                        gestureSteps += abs(n)
                        onTurn(n)
                    }
                }
                .onEnded { v in
                    // A swipe down that barely turned it: back.
                    if v.translation.height > 60, abs(v.translation.width) < v.translation.height, gestureSteps == 0 {
                        IPodFeel.pressed()
                        onBack()
                    }
                    turns.reset()
                    lastAngle = nil
                    gestureTurned = 0
                    gestureSteps = 0
                })
            .accessibilityElement()
            .accessibilityLabel("Dial: turn to scroll, swipe down to go back")
            .accessibilityAdjustableAction { direction in onTurn(direction == .increment ? 1 : -1) }
            .offset(x: (size.width - d) / 2, y: top)

            Button {
                IPodFeel.pressed()
                onSelect()
            } label: {
                Circle()
                    .fill(Theme.surface2)
                    .overlay(Circle().stroke(Theme.line, lineWidth: 1))
                    .overlay(Image(systemName: "checkmark").font(.system(size: 20, weight: .bold)).foregroundStyle(AppSettings.shared.accent))
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
                    .frame(width: 84, height: 84)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Select")
            .offset(y: top + 58)

            HStack {
                end("backward.end.fill", "Previous", onPrevious)
                Spacer()
                end("forward.end.fill", "Next", onNext)
            }
            .padding(.horizontal, 22)
            .offset(y: top + 92)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    @State private var lastAngle: Double?

    private func end(_ icon: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button {
            IPodFeel.pressed()
            run()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
