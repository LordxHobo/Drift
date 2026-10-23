import SwiftUI

enum AppTab: Hashable {
    case home, search, library
}

struct RootView: View {
    @State private var tab: AppTab = .home
    @State private var ui = UIState.shared
    @Environment(\.scenePhase) private var scenePhase
    private var player: Player { .shared }
    private var settings: AppSettings { .shared }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                NavigationStack { HomeView().withRoutes() }
                    .opacity(tab == .home ? 1 : 0)
                    .allowsHitTesting(tab == .home)
                NavigationStack { SearchView().withRoutes() }
                    .opacity(tab == .search ? 1 : 0)
                    .allowsHitTesting(tab == .search)
                NavigationStack { LibraryView().withRoutes() }
                    .opacity(tab == .library ? 1 : 0)
                    .allowsHitTesting(tab == .library)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if player.current != nil {
                MiniPlayer { ui.showPlayer = true }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            TabBar(tab: $tab)
        }
        .background(Theme.bg.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .tint(settings.accent)
        .fullScreenCover(isPresented: $ui.showPlayer) {
            NowPlayingView()
        }
        .sheet(item: $ui.addToPlaylist) { track in
            AddToPlaylistSheet(track: track)
        }
        .animation(.easeOut(duration: 0.25), value: player.current?.id)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { LyricsActivity.shared.appBecameActive() }
        }
    }
}

struct TabBar: View {
    @Binding var tab: AppTab

    var body: some View {
        HStack {
            item(.home, "Home", "house", "house.fill")
            item(.search, "Search", "magnifyingglass", "magnifyingglass")
            item(.library, "Library", "books.vertical", "books.vertical.fill")
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
        .background(Theme.bg)
    }

    private func item(_ t: AppTab, _ title: String, _ icon: String, _ selectedIcon: String) -> some View {
        let selected = tab == t
        return Button {
            tab = t
        } label: {
            VStack(spacing: 4) {
                Image(systemName: selected ? selectedIcon : icon)
                    .font(.system(size: 21, weight: selected ? .bold : .regular))
                    .frame(height: 24)
                Text(title).font(.system(size: 11, weight: selected ? .bold : .medium))
            }
            .foregroundStyle(selected ? Theme.text : Theme.muted)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct MiniPlayer: View {
    var open: () -> Void
    private var player: Player { .shared }
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        if let t = player.current {
            HStack(spacing: 10) {
                Button(action: open) {
                    HStack(spacing: 10) {
                        ArtworkView(url: t.artwork(size: 120), size: 44, corner: 5, seed: t.id)
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
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open player, \(t.title) by \(t.artist)")

                LikeButton(track: t, size: 20, inactive: Theme.text)

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
            .background(Theme.miniPlayer, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottom) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.line)
                        Rectangle().fill(accent).frame(width: g.size.width * player.progress)
                    }
                }
                .frame(height: 2)
                .padding(.horizontal, 8)
            }
            .gesture(DragGesture(minimumDistance: 30).onEnded { v in
                if v.translation.width < -60 { player.next() }
                else if v.translation.width > 60 { player.previous() }
                else if v.translation.height < -30 { open() }
            })
        }
    }
}
