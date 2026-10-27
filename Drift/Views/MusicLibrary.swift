import SwiftUI

/// What a Library row opens in the Apple Music style.
enum LibraryCollection: String, Hashable {
    case playlists, albums, artists, songs

    var title: String {
        switch self {
        case .playlists: "Playlists"
        case .albums: "Albums"
        case .artists: "Artists"
        case .songs: "Songs"
        }
    }
}

/// A rounded cover with a title and a grey line below (Apple Music's grid cards).
struct MusicCard<Art: View>: View {
    let title: String
    let subtitle: String
    var size: CGFloat
    @ViewBuilder var art: () -> Art

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            art()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                .padding(.bottom, 5)
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
        .frame(width: size, alignment: .leading)
    }
}

// MARK: Library

struct MusicLibraryView: View {
    @State private var showNew = false
    @State private var newName = ""
    @State private var showImport = false
    @State private var openPlaylist: UUID?
    private var library: Library { .shared }
    private var accent: Color { AppSettings.shared.accent }

    /// Newest playlists and albums first.
    private var recent: [Playlist] { Array(library.playlists.reversed().prefix(6)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Library").font(Theme.titleFont)
                    Spacer()
                    Menu {
                        Button {
                            newName = ""
                            showNew = true
                        } label: { Label("New playlist", systemImage: "music.note.list") }
                        Button {
                            showImport = true
                        } label: { Label("Import from Spotify", systemImage: "square.and.arrow.down") }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(accent)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Add playlist")
                }
                .padding(.top, 8)
                .padding(.bottom, 6)

                VStack(spacing: 0) {
                    row("Playlists", "music.note.list", .collection(.playlists))
                    row("Artists", "music.mic", .collection(.artists))
                    row("Albums", "square.stack", .collection(.albums))
                    row("Songs", "music.note", .collection(.songs))
                    row("Liked Songs", "heart", .liked)
                    row("Downloaded", "arrow.down.circle", .downloads, last: true)
                }

                if !recent.isEmpty {
                    Text("Recently Added")
                        .font(.system(size: 22, weight: .bold))
                        .padding(.top, 26)
                        .padding(.bottom, 12)
                    GeometryReader { g in
                        let side = (g.size.width - 16) / 2
                        LazyVGrid(columns: [GridItem(.fixed(side), spacing: 16), GridItem(.fixed(side))],
                                  alignment: .leading, spacing: 18) {
                            ForEach(recent) { p in
                                NavigationLink(value: Route.playlist(p.id)) {
                                    MusicCard(title: p.name, subtitle: p.isAlbum == true ? (p.albumArtist ?? "Album") : "Playlist",
                                              size: side) {
                                        PlaylistArt(playlist: p, size: side, corner: 0)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(height: gridHeight(count: recent.count))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showImport) {
            ImportSpotifyView { id in openPlaylist = id }
        }
        .navigationDestination(item: $openPlaylist) { id in
            PlaylistView(kind: .playlist(id)).modifier(BottomBarSpace())
        }
        .alert("New playlist", isPresented: $showNew) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { library.createPlaylist(newName) }
        }
    }

    /// Two columns of cards (cover + two lines of text).
    private func gridHeight(count: Int) -> CGFloat {
        let side = (UIScreen.main.bounds.width - 40 - 16) / 2
        let rows = CGFloat((count + 1) / 2)
        return rows * (side + 50) + max(rows - 1, 0) * 18
    }

    private func row(_ title: String, _ icon: String, _ route: Route, last: Bool = false) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(accent)
                    .frame(width: 28)
                Text(title)
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.text)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            .frame(height: 52)
            .overlay(alignment: .bottom) {
                if !last { Rectangle().fill(Theme.line).frame(height: 0.5).padding(.leading, 42) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Playlists / Albums / Artists / Songs

struct CollectionView: View {
    let kind: LibraryCollection
    @State private var filter = ""
    private var library: Library { .shared }
    private var player: Player { .shared }

    var body: some View {
        Group {
            switch kind {
            case .playlists: grid(library.playlists.filter { $0.isAlbum != true })
            case .albums: grid(library.playlists.filter { $0.isAlbum == true })
            case .artists: artists
            case .songs: songs
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Theme.bg, for: .navigationBar)
    }

    private func grid(_ items: [Playlist]) -> some View {
        ScrollView {
            if items.isEmpty {
                Text(kind == .albums
                     ? "Albums you save with + on an album page appear here."
                     : "Playlists you make or import appear here.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .padding(40)
            }
            GeometryReader { g in
                let side = (g.size.width - 16) / 2
                LazyVGrid(columns: [GridItem(.fixed(side), spacing: 16), GridItem(.fixed(side))],
                          alignment: .leading, spacing: 18) {
                    ForEach(items) { p in
                        NavigationLink(value: Route.playlist(p.id)) {
                            MusicCard(title: p.name,
                                      subtitle: p.isAlbum == true ? (p.albumArtist ?? "Album") : "\(p.tracks.count) songs",
                                      size: side) {
                                PlaylistArt(playlist: p, size: side, corner: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: height(items.count))
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    private func height(_ count: Int) -> CGFloat {
        let side = (UIScreen.main.bounds.width - 40 - 16) / 2
        let rows = CGFloat((count + 1) / 2)
        return rows * (side + 50) + max(rows - 1, 0) * 18
    }

    private var artists: some View {
        List {
            if ArtistStore.shared.followed.isEmpty {
                Text("Artists you follow appear here. Follow one from their artist page.")
                    .foregroundStyle(Theme.muted)
                    .listRowBackground(Theme.bg)
            }
            ForEach(ArtistStore.shared.followed) { f in
                NavigationLink(value: Route.artist(f.artist)) {
                    HStack(spacing: 12) {
                        AsyncImage(url: resizedImage(f.artist.thumbnail, size: 160)) { phase in
                            if let img = phase.image { img.resizable().scaledToFill() } else { Theme.tile(seed: f.artist.name) }
                        }
                        .frame(width: 48, height: 48)
                        .clipShape(Circle())
                        .accessibilityHidden(true)
                        Text(f.artist.name).font(.system(size: 17))
                        if !f.newReleases.isEmpty {
                            Text("NEW").font(.system(size: 10, weight: .heavy)).foregroundStyle(AppSettings.shared.accent)
                        }
                    }
                }
                .listRowBackground(Theme.bg)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var songs: some View {
        let all = library.allSongs
        let shown = filter.isEmpty ? all : all.filter {
            $0.title.localizedStandardContains(filter) || $0.artist.localizedStandardContains(filter)
        }
        return List {
            if all.isEmpty {
                Text("Songs from your playlists and liked songs appear here.")
                    .foregroundStyle(Theme.muted)
                    .listRowBackground(Theme.bg)
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                TrackRow(track: t) {
                    player.play(shown, startAt: i, from: "Songs")
                }
                .listRowBackground(Theme.bg)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 12))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .searchable(text: $filter, prompt: "Find in songs")
    }
}
