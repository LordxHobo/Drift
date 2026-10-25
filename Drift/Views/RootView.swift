import SwiftUI

enum AppTab: Hashable {
    case home, search, podcasts, library
}

struct RootView: View {
    @State private var tab: AppTab = .home
    /// Pages opened inside each tab; emptied when the tab is tapped again.
    @State private var homePath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var podcastsPath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var ui = UIState.shared
    @State private var social = SocialStore.shared
    @Environment(\.scenePhase) private var scenePhase
    private var player: Player { .shared }
    private var settings: AppSettings { .shared }

    var body: some View {
        ZStack {
                NavigationStack(path: $homePath) { HomeView().withRoutes() }
                    .opacity(tab == .home ? 1 : 0)
                    .allowsHitTesting(tab == .home)
                NavigationStack(path: $searchPath) { SearchView().withRoutes() }
                    .opacity(tab == .search ? 1 : 0)
                    .allowsHitTesting(tab == .search)
                NavigationStack(path: $podcastsPath) { PodcastsView().withRoutes() }
                    .opacity(tab == .podcasts ? 1 : 0)
                    .allowsHitTesting(tab == .podcasts)
                NavigationStack(path: $libraryPath) { LibraryView().withRoutes() }
                    .opacity(tab == .library ? 1 : 0)
                    .allowsHitTesting(tab == .library)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .leading) {
                // Swipe in from the left edge to open the drawer (on a tab's first page only,
                // so the iPhone's swipe-back keeps working everywhere else).
                if isAtStart(tab) && !ui.showDrawer {
                    Color.clear
                        .frame(width: 16)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 10).onEnded { v in
                            if v.translation.width > 40 || v.predictedEndTranslation.width > 120 {
                                ui.showDrawer = true
                            }
                        })
                        .accessibilityHidden(true)
                }
            }
            // Pages scroll behind the bars (visible through them with glass effects on);
            // every page leaves room for them at the bottom (see `withRoutes`).
            .overlay(alignment: .bottom) {
                bottomBars
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { ui.bottomInset = $0 }
            }
            .fullScreenCover(isPresented: $social.showOnboarding) {
                OnboardingView()
            }
        .overlay {
            ProfileDrawer(isOpen: $ui.showDrawer, open: openFromDrawer)
        }
        .background(Theme.bg.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .tint(settings.accent)
        .fullScreenCover(isPresented: $ui.showPlayer) {
            NowPlayingView()
                .foregroundStyle(Theme.text)
                .environment(\.colorScheme, .dark)
                .preferredColorScheme(.dark)
        }
        .sheet(item: $ui.addToPlaylist) { track in
            AddToPlaylistSheet(track: track)
        }
        .sheet(item: $ui.replacing) { r in
            ReplaceSongSheet(request: r)
        }
        .animation(.easeOut(duration: 0.25), value: player.current?.id)
        .onAppear { settings.applyAppearance() }
        .task { await ArtistStore.shared.check() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                settings.applyAppearance()
                Task { await ArtistStore.shared.check() }
                LyricsActivity.shared.appBecameActive()
            }
            if phase == .background {
                player.savePosition()
                PodcastStore.shared.flush()
                LyricsActivity.shared.appWentToBackground(playing: player.isPlaying)
            }
        }
    }
}

extension RootView {
    @ViewBuilder var bottomBars: some View {
        let glass = DriftGlass.isOn
        VStack(spacing: glass ? 8 : 0) {
            if player.current != nil {
                MiniPlayer { ui.showPlayer = true }
                    .foregroundStyle(Theme.text)
                    .environment(\.colorScheme, .dark)
                    .padding(.horizontal, glass ? 14 : 8)
                    .padding(.top, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            TabBar(tab: $tab, reselect: backToStart)
        }
        .background {
            if !glass { Theme.bg.ignoresSafeArea(edges: .bottom) }
        }
    }

    func isAtStart(_ t: AppTab) -> Bool {
        switch t {
        case .home: homePath.isEmpty
        case .search: searchPath.isEmpty
        case .podcasts: podcastsPath.isEmpty
        case .library: libraryPath.isEmpty
        }
    }

    /// Pages picked in the drawer open in the tab you're on.
    func openFromDrawer(_ route: Route) {
        ui.showDrawer = false
        switch tab {
        case .home: homePath.append(route)
        case .search: searchPath.append(route)
        case .podcasts: podcastsPath.append(route)
        case .library: libraryPath.append(route)
        }
    }

    /// Tapping the tab you're already on goes back to its first page (like Spotify).
    func backToStart(_ t: AppTab) {
        switch t {
        case .home: homePath = NavigationPath()
        case .search: searchPath = NavigationPath()
        case .podcasts: podcastsPath = NavigationPath()
        case .library: libraryPath = NavigationPath()
        }
    }
}

struct TabBar: View {
    @Binding var tab: AppTab
    var reselect: (AppTab) -> Void = { _ in }

    var body: some View {
        let items = HStack {
            item(.home, "Home", "house", "house.fill")
            item(.search, "Search", "magnifyingglass", "magnifyingglass")
            item(.podcasts, "Podcasts", "mic", "mic.fill")
            item(.library, "Library", "books.vertical", "books.vertical.fill")
        }
        if DriftGlass.isOn {
            // Floating glass capsule.
            items
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .driftGlass(in: Capsule())
                .padding(.horizontal, 14)
                .padding(.bottom, 2)
        } else {
            items
                .padding(.top, 8)
                .padding(.bottom, 2)
                .background(Theme.bg.ignoresSafeArea(edges: .bottom))
        }
    }

    private func item(_ t: AppTab, _ title: String, _ icon: String, _ selectedIcon: String) -> some View {
        let selected = tab == t
        return Button {
            if tab == t { reselect(t) } else { tab = t }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: selected ? selectedIcon : icon)
                    .font(.system(size: 21, weight: selected ? .bold : .regular))
                    .frame(height: 24)
                Text(title).font(.system(size: 11, weight: selected ? .bold : .medium))
            }
            .foregroundStyle(selected ? (DriftGlass.isOn ? AppSettings.shared.accent : Theme.text)
                                      : (DriftGlass.isOn ? Theme.text2 : Theme.muted))
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct MiniPlayer: View {
    var open: () -> Void
    /// Live drag (resets itself even if iOS cancels it) plus the slide after letting go.
    @GestureState private var dragX: CGFloat = 0
    @State private var settle: CGFloat = 0
    private var swipe: CGFloat { dragX + settle }

    /// Current song slides out one side, the new one slides in from the other.
    private func slide(from start: CGFloat, out x: CGFloat, change: @escaping () -> Void) {
        instantly { settle = start }
        withAnimation(.easeIn(duration: 0.15)) { settle = x } completion: {
            change()
            instantly { settle = -x }
            withAnimation(.easeOut(duration: 0.2)) { settle = 0 }
        }
    }

    private func instantly(_ change: () -> Void) {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx, change)
    }
    private var player: Player { .shared }
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        if let t = player.current {
            HStack(spacing: 10) {
                Button(action: open) {
                    HStack(spacing: 10) {
                        ArtworkView(url: t.artwork(size: 120), size: 44, corner: 5, seed: t.id)
                            .offset(x: swipe)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title)
                                .font(.system(size: 13, weight: .bold))
                                .lineLimit(1)
                            HStack(spacing: 0) {
                                Text(t.artist).lineLimit(1)
                                if player.isCarRoute || player.routeName != "This iPhone" {
                                    Text(" · ")
                                    Text(player.routeName).foregroundStyle(accent).lineLimit(1)
                                }
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                        }
                        .offset(x: swipe)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .clipped()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open player, \(t.title) by \(t.artist)")

                if t.isEpisode {
                    Button {
                        player.skip(by: 30)
                    } label: {
                        Image(systemName: "goforward.30")
                            .font(.system(size: 19, weight: .semibold))
                            .frame(width: 36, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Skip forward 30 seconds")
                } else {
                    LikeButton(track: t, size: 20, inactive: Theme.text)
                }

                Button {
                    player.togglePlay()
                } label: {
                    Group {
                        if player.isBuffering && !player.isPlaying {
                            ProgressView().tint(Theme.text)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 20))
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            }
            .padding(8)
            .driftGlass(in: DriftGlass.isOn ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: 10, style: .continuous)),
                        clear: false, tint: Theme.miniPlayer.opacity(0.55), interactive: true,
                        fallback: Theme.miniPlayer)
            .overlay(alignment: .bottom) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.line)
                        Rectangle().fill(accent).frame(width: g.size.width * player.progress)
                    }
                }
                .frame(height: 2)
                .clipShape(Capsule())
                .padding(.horizontal, DriftGlass.isOn ? 26 : 8)
                .padding(.bottom, DriftGlass.isOn ? 1 : 0)
            }
            .gesture(DragGesture(minimumDistance: 12)
                .updating($dragX) { v, state, _ in
                    if abs(v.translation.width) > abs(v.translation.height) { state = v.translation.width }
                }
                .onEnded { v in
                    let x = v.predictedEndTranslation.width
                    let start = abs(v.translation.width) > abs(v.translation.height) ? v.translation.width : 0
                    if x < -80, player.nextInQueue != nil {
                        slide(from: start, out: -360) { player.next() }
                    } else if x > 80, player.previousInQueue != nil {
                        slide(from: start, out: 360) { player.skipToPrevious() }
                    } else {
                        instantly { settle = start }
                        withAnimation(.spring(duration: 0.3)) { settle = 0 }
                        if v.translation.height < -30 { open() }
                    }
                })
        }
    }
}
