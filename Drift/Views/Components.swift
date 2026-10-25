import SwiftUI

enum Route: Hashable {
    case liked
    case downloads
    case playlist(UUID)
    case settings
    case channel(PodcastChannel)
    case profile
    case friends
    case user(UserProfile)
    case sharedPlaylist(SharedPlaylist)
    case followList(followers: Bool)
    case artist(ArtistRef)
    case album(AlbumRef, artist: String)
    case discography(title: String, ref: BrowseRef?, albums: [AlbumRef], artist: String)
}

extension View {
    func withRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .settings: SettingsView()
            case .liked: PlaylistView(kind: .liked)
            case .downloads: PlaylistView(kind: .downloads)
            case .playlist(let id): PlaylistView(kind: .playlist(id))
            case .channel(let c): ChannelView(channel: c)
            case .profile: ProfileView()
            case .friends: FriendsView()
            case .user(let u): UserView(initial: u)
            case .sharedPlaylist(let p): SharedPlaylistView(playlist: p)
            case .followList(let followers): FollowListView(followers: followers)
            case .artist(let a): ArtistView(artist: a)
            case .album(let a, let artist): AlbumView(album: a, artist: artist)
            case .discography(let title, let ref, let albums, let artist):
                DiscographyView(title: title, ref: ref, initial: albums, artist: artist)
            }
        }
    }
}

// MARK: Artwork

struct ArtworkView: View {
    let url: URL?
    var size: CGFloat
    var corner: CGFloat = 4
    var seed: String = ""

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Theme.tile(seed: seed)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.32, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Cover of one of the user's playlists, following its cover settings.
struct PlaylistArt: View {
    let playlist: Playlist
    var size: CGFloat
    var corner: CGFloat = 4

    var body: some View {
        PlaylistCover(tracks: playlist.tracks, size: size, color: Theme.tile(playlist.colorIndex),
                      symbol: playlist.symbol, corner: corner,
                      forceTile: playlist.style == .color,
                      photo: Library.shared.coverImage(playlist))
    }
}

/// Cover for a playlist: a custom photo, a 2×2 mosaic of its first songs, or a colored tile.
struct PlaylistCover: View {
    let tracks: [Track]
    var size: CGFloat
    var color: Color
    var symbol: String = "music.note.list"
    var corner: CGFloat = 4
    var forceTile = false
    var photo: UIImage? = nil

    var body: some View {
        Group {
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill()
            } else if forceTile {
                ZStack {
                    color
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            } else if tracks.count >= 4 {
                let half = size / 2
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ArtworkView(url: tracks[0].artwork(size: 300), size: half, corner: 0, seed: tracks[0].id)
                        ArtworkView(url: tracks[1].artwork(size: 300), size: half, corner: 0, seed: tracks[1].id)
                    }
                    HStack(spacing: 0) {
                        ArtworkView(url: tracks[2].artwork(size: 300), size: half, corner: 0, seed: tracks[2].id)
                        ArtworkView(url: tracks[3].artwork(size: 300), size: half, corner: 0, seed: tracks[3].id)
                    }
                }
            } else if let first = tracks.first {
                ArtworkView(url: first.artwork(size: 600), size: size, corner: 0, seed: first.id)
            } else {
                ZStack {
                    color
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct SymbolTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat

    var body: some View {
        ZStack {
            color
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct HQBadge: View {
    var body: some View {
        Text("HQ")
            .font(.system(size: 9, weight: .heavy))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Theme.line, in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(Theme.text2)
    }
}

// MARK: Track row

struct TrackRow: View {
    let track: Track
    var onTap: () -> Void

    private var player: Player { .shared }
    private var library: Library { .shared }
    private var downloads: DownloadManager { .shared }
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        let isCurrent = player.current?.id == track.id
        HStack(spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    ArtworkView(url: track.artwork(size: 120), size: 44, seed: track.id)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(isCurrent ? accent : Theme.text)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if library.isDownloaded(track.id) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(accent)
                            } else if let p = downloads.progress[track.id] {
                                ProgressView(value: p)
                                    .progressViewStyle(.circular)
                                    .controlSize(.mini)
                                    .tint(accent)
                            }
                            HQBadge()
                            Text(track.artist)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(track.durationText)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !track.isEpisode {
                LikeButton(track: track, size: 17)
            }

            Menu {
                TrackMenuItems(track: track)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More options for \(track.title)")
        }
        .frame(minHeight: 60)
        .contextMenu { TrackMenuItems(track: track) }
    }
}

/// Heart that adds or removes a song from Liked songs in one tap.
struct LikeButton: View {
    let track: Track
    var size: CGFloat = 17
    var inactive: Color = Theme.muted
    private var library: Library { .shared }

    var body: some View {
        let liked = library.isLiked(track.id)
        Button {
            library.toggleLike(track)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(liked ? AppSettings.shared.accent : inactive)
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
                .symbolEffect(.bounce, value: liked)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(liked ? "Remove \(track.title) from Liked songs" : "Like \(track.title)")
    }
}

struct TrackMenuItems: View {
    let track: Track
    private var library: Library { .shared }

    var body: some View {
        Button {
            Player.shared.playNext(track)
        } label: { Label("Play next", systemImage: "text.insert") }

        Button {
            library.toggleLike(track)
        } label: {
            library.isLiked(track.id)
                ? Label("Remove from Liked songs", systemImage: "heart.slash")
                : Label("Like", systemImage: "heart")
        }

        Button {
            UIState.shared.addToPlaylist = track
        } label: { Label("Add to playlist", systemImage: "text.badge.plus") }

        if library.isDownloaded(track.id) {
            Button(role: .destructive) {
                library.removeDownload(track.id)
            } label: { Label("Remove download", systemImage: "trash") }
        } else {
            Button {
                DownloadManager.shared.download(track)
            } label: { Label("Download", systemImage: "arrow.down.circle") }
        }
    }
}

// MARK: Add to playlist sheet

struct AddToPlaylistSheet: View {
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var showNew = false
    @State private var newName = ""
    private var library: Library { .shared }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    newName = ""
                    showNew = true
                } label: {
                    HStack(spacing: 12) {
                        SymbolTile(symbol: "plus", color: Theme.surface2, size: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Text("New playlist").font(.system(size: 15, weight: .semibold))
                    }
                }
                .listRowBackground(Theme.bg)

                ForEach(library.playlists) { p in
                    Button {
                        library.add(track, to: p.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            PlaylistArt(playlist: p, size: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.system(size: 15, weight: .semibold))
                                Text("\(p.tracks.count) songs").font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            if p.tracks.contains(where: { $0.id == track.id }) {
                                Image(systemName: "checkmark").foregroundStyle(AppSettings.shared.accent)
                            }
                        }
                    }
                    .listRowBackground(Theme.bg)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .foregroundStyle(Theme.text)
            .navigationTitle("Add to playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .alert("New playlist", isPresented: $showNew) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let p = library.createPlaylist(newName)
                    library.add(track, to: p.id)
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
