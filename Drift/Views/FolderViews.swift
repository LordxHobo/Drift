import SwiftUI

/// "Move to folder" in a playlist's menu: the folders, a new one, or out of the one it's in.
struct MoveToFolderMenu: View {
    let playlist: Playlist
    /// Asks for a name for a new folder (the playlist goes into it).
    var newFolder: () -> Void
    private var library: Library { .shared }

    var body: some View {
        Menu {
            Button(action: newFolder) { Label("New folder", systemImage: "folder.badge.plus") }
            ForEach(library.folders) { f in
                Button {
                    library.move(playlist.id, toFolder: f.id)
                } label: {
                    if playlist.folder == f.id {
                        Label(f.name, systemImage: "checkmark")
                    } else {
                        Label(f.name, systemImage: "folder")
                    }
                }
            }
            if let f = playlist.folder.flatMap({ library.folder($0) }) {
                Button {
                    library.move(playlist.id, toFolder: nil)
                } label: { Label("Take out of \(f.name)", systemImage: "folder.badge.minus") }
            }
        } label: {
            Label("Move to folder", systemImage: "folder")
        }
    }
}

/// Naming a folder: a new one (with a playlist moved into it, or none) or a renamed one.
enum FolderRequest: Equatable {
    case new(moving: UUID?)
    case rename(UUID)
}

/// The name prompt for a `FolderRequest`.
struct FolderNameAlert: ViewModifier {
    @Binding var request: FolderRequest?
    @State private var name = ""

    private var isRename: Bool {
        if case .rename = request { return true }
        return false
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, r in
                if case .rename(let id) = r { name = Library.shared.folder(id)?.name ?? "" } else { name = "" }
            }
            .alert(isRename ? "Rename folder" : "New folder",
                   isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } })) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) { request = nil }
                Button(isRename ? "Rename" : "Create") { finish() }
            }
    }

    private func finish() {
        let library = Library.shared
        switch request {
        case .new(let moving):
            let f = library.createFolder(name)
            if let moving { library.move(moving, toFolder: f.id) }
        case .rename(let id):
            library.renameFolder(id, to: name)
        case nil:
            break
        }
        request = nil
    }
}

extension View {
    func folderNameAlert(_ request: Binding<FolderRequest?>) -> some View { modifier(FolderNameAlert(request: request)) }
}

/// A folder's row or card art.
struct FolderTile: View {
    var size: CGFloat
    var body: some View {
        SymbolTile(symbol: "folder.fill", color: Theme.surface2, size: size)
    }
}

/// The playlists in one folder.
struct FolderView: View {
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Playlist?
    @State private var confirmDelete = false
    @State private var folderRequest: FolderRequest?
    private var library: Library { .shared }

    var body: some View {
        let folder = library.folder(id)
        let items = library.playlists(in: id)
        List {
            if items.isEmpty {
                Text("This folder is empty. Add playlists with Move to folder in a playlist's menu (hold it in Your Library).")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
                    .listRowBackground(Theme.bg)
            }
            ForEach(items) { p in
                NavigationLink(value: Route.playlist(p.id)) {
                    HStack(spacing: 12) {
                        PlaylistArt(playlist: p, size: 56, corner: 0)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                            Text(p.isAlbum == true ? "Album · \(p.albumArtist ?? "")" : "Playlist · \(p.tracks.count) songs")
                                .font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowBackground(Theme.bg)
                .contextMenu {
                    Button { editing = p } label: { Label("Edit playlist", systemImage: "pencil") }
                    MoveToFolderMenu(playlist: p) { folderRequest = .new(moving: p.id) }
                }
                .swipeActions {
                    Button {
                        library.move(p.id, toFolder: nil)
                    } label: { Label("Take out", systemImage: "folder.badge.minus") }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(folder?.name ?? "Folder")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { folderRequest = .rename(id) } label: { Label("Rename folder", systemImage: "pencil") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete folder", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Folder options")
            }
        }
        .confirmationDialog("Delete \(folder?.name ?? "this folder")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete folder", role: .destructive) {
                library.deleteFolder(id)
                dismiss()
            }
        } message: {
            Text("Its playlists stay in Your Library.")
        }
        .sheet(item: $editing) { p in EditPlaylistView(playlist: p) }
        .folderNameAlert($folderRequest)
        .onChange(of: folder == nil) { _, gone in
            if gone { dismiss() }
        }
    }
}
