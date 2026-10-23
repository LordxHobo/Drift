import SwiftUI

struct LibraryView: View {
    @State private var showNew = false
    @State private var newName = ""
    @State private var renaming: Playlist?
    @State private var renameText = ""
    @State private var showImport = false
    @State private var openPlaylist: UUID?
    private var library: Library { .shared }

    var body: some View {
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
                        SymbolTile(symbol: "arrow.down", color: Theme.line, size: 64)
                    }
                }
                .listRowBackground(Theme.bg)

                ForEach(library.playlists) { p in
                    NavigationLink(value: Route.playlist(p.id)) {
                        row(title: p.name, subtitle: "Playlist · \(p.tracks.count) songs") {
                            PlaylistCover(tracks: p.tracks, size: 64, color: Theme.tile(p.colorIndex), corner: 0)
                        }
                    }
                    .listRowBackground(Theme.bg)
                    .contextMenu {
                        Button {
                            renameText = p.name
                            renaming = p
                        } label: { Label("Rename", systemImage: "pencil") }
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
            PlaylistView(kind: .playlist(id))
        }
        .alert("New playlist", isPresented: $showNew) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { library.createPlaylist(newName) }
        }
        .alert("Rename playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let p = renaming { library.rename(p.id, to: renameText) }
            }
        }
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
