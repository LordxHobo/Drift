import SwiftUI

struct LibraryView: View {
    @State private var showNew = false
    @State private var newName = ""
    @State private var editing: Playlist?
    @State private var showImport = false
    @State private var openPlaylist: UUID?
    @State private var folderRequest: FolderRequest?
    private var library: Library { .shared }

    var body: some View {
        if Theme.isMusic {
            MusicLibraryView()
        } else {
            spotifyBody
        }
    }

    private var spotifyBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Your Library")
                    .font(.system(size: 26, weight: .heavy))
                    .tracking(-0.5)
                Spacer()
                Menu {
                    Button {
                        newName = ""
                        showNew = true
                    } label: { Label("New playlist", systemImage: "music.note.list") }
                    Button {
                        folderRequest = .new(moving: nil)
                    } label: { Label("New folder", systemImage: "folder.badge.plus") }
                    Button {
                        showImport = true
                    } label: { Label("Import from Spotify", systemImage: "square.and.arrow.down") }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Add playlist")
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            List {
                NavigationLink(value: Route.liked) {
                    row(title: "Liked songs", subtitle: "Playlist · \(library.liked.count) songs") {
                        SymbolTile(symbol: "heart.fill", color: Color(hex: 0x4338CA), size: 64)
                    }
                }
                .listRowBackground(Theme.bg)

                NavigationLink(value: Route.downloads) {
                    row(title: "Downloaded", subtitle: "\(library.downloaded.count) songs on this iPhone") {
                        SymbolTile(symbol: "arrow.down", color: Color(hex: 0x3F3F46), size: 64)
                    }
                }
                .listRowBackground(Theme.bg)

                ForEach(library.folders) { f in
                    NavigationLink(value: Route.folder(f.id)) {
                        row(title: f.name, subtitle: "Folder · \(library.playlists(in: f.id).count) playlists") {
                            FolderTile(size: 64)
                        }
                    }
                    .listRowBackground(Theme.bg)
                    .contextMenu {
                        Button {
                            folderRequest = .rename(f.id)
                        } label: { Label("Rename folder", systemImage: "pencil") }
                        Button(role: .destructive) {
                            library.deleteFolder(f.id)
                        } label: { Label("Delete folder (keeps its playlists)", systemImage: "trash") }
                    }
                }

                ForEach(library.playlists(in: nil)) { p in
                    NavigationLink(value: Route.playlist(p.id)) {
                        row(title: p.name, subtitle: "Playlist · \(p.tracks.count) songs") {
                            PlaylistArt(playlist: p, size: 64, corner: 0)
                        }
                    }
                    .listRowBackground(Theme.bg)
                    .contextMenu {
                        Button {
                            editing = p
                        } label: { Label("Edit playlist", systemImage: "pencil") }
                        MoveToFolderMenu(playlist: p) { folderRequest = .new(moving: p.id) }
                        Button(role: .destructive) {
                            library.deletePlaylist(p.id)
                        } label: { Label("Delete playlist", systemImage: "trash") }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            library.deletePlaylist(p.id)
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }

                ForEach(ArtistStore.shared.followed) { f in
                    NavigationLink(value: Route.artist(f.artist)) {
                        HStack(spacing: 12) {
                            AsyncImage(url: resizedImage(f.artist.thumbnail, size: 200)) { phase in
                                if let img = phase.image { img.resizable().scaledToFill() } else { Theme.tile(seed: f.artist.name) }
                            }
                            .frame(width: 64, height: 64)
                            .clipShape(Circle())
                            .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(f.artist.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                                Text(f.newReleases.isEmpty ? "Artist" : "Artist · new release")
                                    .font(.system(size: 13))
                                    .foregroundStyle(f.newReleases.isEmpty ? Theme.muted : AppSettings.shared.accent)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowBackground(Theme.bg)
                    .swipeActions {
                        Button(role: .destructive) {
                            ArtistStore.shared.unfollow(f.id)
                        } label: { Label("Unfollow", systemImage: "person.badge.minus") }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
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
        .sheet(item: $editing) { p in
            EditPlaylistView(playlist: p)
        }
        .folderNameAlert($folderRequest)
    }

    private func row<Art: View>(title: String, subtitle: String, @ViewBuilder art: () -> Art) -> some View {
        HStack(spacing: 12) {
            art()
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
