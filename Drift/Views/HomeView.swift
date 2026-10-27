import SwiftUI

struct HomeView: View {
    private var library: Library { .shared }
    private var player: Player { .shared }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    var body: some View {
        if Theme.isMusic {
            MusicHomeView()
        } else {
            spotifyBody
        }
    }

    private var spotifyBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    // Opens the drawer (profile, notifications, friends, settings).
                    Button {
                        UIState.shared.showDrawer = true
                    } label: {
                        UserAvatar(data: SocialStore.shared.me?.avatar,
                                   name: SocialStore.shared.me?.username ?? "?", size: 34)
                            .overlay(alignment: .topTrailing) {
                                if NotificationStore.shared.unreadCount > 0 {
                                    Circle()
                                        .fill(AppSettings.shared.accent)
                                        .frame(width: 11, height: 11)
                                        .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
                                        .offset(x: 2, y: -2)
                                }
                            }
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NotificationStore.shared.unreadCount > 0
                                        ? "Menu, \(NotificationStore.shared.unreadCount) unread notifications" : "Menu")
                    Text(greeting)
                        .font(.system(size: 26, weight: .heavy))
                        .tracking(-0.5)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer()
                    NavigationLink(value: Route.settings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 20))
                            .frame(width: 44, height: 44)
                            .driftGlass(in: Circle(), interactive: true)
                    }
                    .accessibilityLabel("Settings")
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    NavigationLink(value: Route.liked) {
                        QuickTile(title: "Liked songs") {
                            SymbolTile(symbol: "heart.fill", color: Color(hex: 0x4338CA), size: 56)
                        }
                    }
                    NavigationLink(value: Route.downloads) {
                        QuickTile(title: "Downloaded") {
                            SymbolTile(symbol: "arrow.down", color: Color(hex: 0x3F3F46), size: 56)
                        }
                    }
                    ForEach(library.playlists.prefix(4)) { p in
                        NavigationLink(value: Route.playlist(p.id)) {
                            QuickTile(title: p.name) {
                                PlaylistArt(playlist: p, size: 56, corner: 0)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)

                if library.recent.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nothing played yet")
                            .font(.system(size: 20, weight: .heavy))
                        Text("Find a song in Search and it will show up here.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.top, 12)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Jump back in")
                            .font(.system(size: 20, weight: .heavy))
                            .tracking(-0.3)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(Array(library.recent.prefix(15).enumerated()), id: \.element.id) { i, t in
                                    Button {
                                        player.play(Array(library.recent.prefix(15)), startAt: i, from: "Recently played")
                                    } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            ArtworkView(url: t.artwork(size: 400), size: 140, corner: 6, seed: t.id)
                                            Text(t.title)
                                                .font(.system(size: 13, weight: .bold))
                                                .lineLimit(1)
                                            Text(t.artist)
                                                .font(.system(size: 12))
                                                .foregroundStyle(Theme.muted)
                                                .lineLimit(1)
                                        }
                                        .frame(width: 140, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu { TrackMenuItems(track: t) }
                                }
                            }
                        }
                        .scrollClipDisabled()
                    }
                }

                let releases = ArtistStore.shared.allNewReleases
                if !releases.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("New releases")
                            .font(.system(size: 20, weight: .heavy))
                            .tracking(-0.3)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(releases) { r in
                                    NavigationLink(value: Route.album(r.album, artist: r.artistName)) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            AlbumCard(album: r.album, size: 140)
                                            Text(r.artistName)
                                                .font(.system(size: 12))
                                                .foregroundStyle(Theme.muted)
                                                .lineLimit(1)
                                                .frame(width: 140, alignment: .leading)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .scrollClipDisabled()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .task { player.prefetch(Array(library.recent.prefix(2))) }
    }
}

struct QuickTile<Art: View>: View {
    let title: String
    @ViewBuilder var art: () -> Art

    var body: some View {
        HStack(spacing: 10) {
            art()
                .frame(width: 56, height: 56)
                .clipped()
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 4)
        }
        .frame(height: 56)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
    }
}


// MARK: Apple Music style

struct MusicHomeView: View {
    private var library: Library { .shared }
    private var player: Player { .shared }
    private var social: SocialStore { .shared }
    private let card: CGFloat = 170

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Home").font(Theme.titleFont)
                    Spacer()
                    Button {
                        UIState.shared.showDrawer = true
                    } label: {
                        UserAvatar(data: social.me?.avatar, name: social.me?.username ?? "?", size: 34)
                            .overlay(alignment: .topTrailing) {
                                if NotificationStore.shared.unreadCount > 0 {
                                    Circle().fill(AppSettings.shared.accent)
                                        .frame(width: 11, height: 11)
                                        .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
                                        .offset(x: 2, y: -2)
                                }
                            }
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Menu")
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                if library.recent.isEmpty && library.playlists.isEmpty {
                    Text("Find a song in Search and it will show up here.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                }

                if !library.recent.isEmpty {
                    sectionTitle("Recently Played")
                    shelf {
                        ForEach(Array(library.recent.prefix(15).enumerated()), id: \.element.id) { i, t in
                            Button {
                                player.play(Array(library.recent.prefix(15)), startAt: i, from: "Recently played")
                            } label: {
                                MusicCard(title: t.title, subtitle: t.artist, size: card) {
                                    ArtworkView(url: t.artwork(size: 400), size: card, corner: 0, seed: t.id)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu { TrackMenuItems(track: t) }
                        }
                    }
                }

                let releases = ArtistStore.shared.allNewReleases
                if !releases.isEmpty {
                    sectionTitle("New Releases")
                    shelf {
                        ForEach(releases) { r in
                            NavigationLink(value: Route.album(r.album, artist: r.artistName)) {
                                MusicCard(title: r.album.title, subtitle: r.artistName, size: card) {
                                    AsyncImage(url: resizedImage(r.album.thumbnail, size: 400)) { phase in
                                        if let img = phase.image { img.resizable().scaledToFill() } else { Theme.tile(seed: r.album.id) }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                sectionTitle("Your Playlists", route: .collection(.playlists))
                shelf {
                    NavigationLink(value: Route.liked) {
                        MusicCard(title: "Liked Songs", subtitle: "\(library.liked.count) songs", size: card) {
                            SymbolTile(symbol: "heart.fill", color: AppSettings.shared.accent, size: card)
                        }
                    }
                    .buttonStyle(.plain)
                    ForEach(library.playlists.filter { $0.isAlbum != true }.reversed()) { p in
                        NavigationLink(value: Route.playlist(p.id)) {
                            MusicCard(title: p.name, subtitle: "Playlist", size: card) {
                                PlaylistArt(playlist: p, size: card, corner: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                let albums = library.playlists.filter { $0.isAlbum == true }
                if !albums.isEmpty {
                    sectionTitle("Albums", route: .collection(.albums))
                    shelf {
                        ForEach(albums.reversed()) { p in
                            NavigationLink(value: Route.playlist(p.id)) {
                                MusicCard(title: p.name, subtitle: p.albumArtist ?? "Album", size: card) {
                                    PlaylistArt(playlist: p, size: card, corner: 0)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .task { player.prefetch(Array(library.recent.prefix(2))) }
    }

    @ViewBuilder private func sectionTitle(_ title: String, route: Route? = nil) -> some View {
        Group {
            if let route {
                NavigationLink(value: route) {
                    HStack(spacing: 4) {
                        Text(title)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Theme.muted)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Text(title)
            }
        }
        .font(.system(size: 22, weight: .bold))
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    private func shelf<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) { content() }
                .padding(.horizontal, 20)
        }
    }
}
