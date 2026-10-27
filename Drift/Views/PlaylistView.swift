import SwiftUI

struct PlaylistView: View {
    enum Kind: Hashable {
        case liked, downloads, playlist(UUID)
    }

    let kind: Kind
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var headerColor: Color = Color(hex: 0x1A2B21)
    @State private var editing: Playlist?
    @State private var filter = ""
    @FocusState private var filterFocused: Bool
    private var library: Library { .shared }
    private var player: Player { .shared }
    private var downloads: DownloadManager { .shared }
    private var accent: Color { AppSettings.shared.accent }

    private var title: String {
        switch kind {
        case .liked: "Liked songs"
        case .downloads: "Downloaded"
        case .playlist(let id): library.playlist(id)?.name ?? "Playlist"
        }
    }

    private var tracks: [Track] {
        switch kind {
        case .liked: library.liked
        case .downloads: library.downloaded
        case .playlist(let id): library.playlist(id)?.tracks ?? []
        }
    }

    private var tileColor: Color {
        switch kind {
        case .liked: Color(hex: 0x4338CA)
        case .downloads: Theme.line
        case .playlist(let id): Theme.tile(library.playlist(id)?.colorIndex ?? 0)
        }
    }

    private var symbol: String {
        switch kind {
        case .liked: "heart.fill"
        case .downloads: "arrow.down"
        case .playlist: "music.note.list"
        }
    }

    var body: some View {
        let tracks = self.tracks
        List {
            header(tracks)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            if tracks.isEmpty {
                Text(emptyText)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
                    .listRowBackground(Theme.bg)
                    .listRowSeparator(.hidden)
            }

            if !tracks.isEmpty {
                filterField
                    .listRowBackground(Theme.bg)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 8, trailing: 20))
            }

            let shown = filtered(tracks)
            if !query.isEmpty && shown.isEmpty {
                Text("No songs or artists matching “\(query)”")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                    .listRowBackground(Theme.bg)
                    .listRowSeparator(.hidden)
            }

            // Tapping a song plays the whole list from that song, filtered or not.
            ForEach(shown) { item in
                TrackRow(track: item.track) {
                    filterFocused = false
                    player.play(tracks, startAt: item.index, from: title)
                }
                .listRowBackground(Theme.bg)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 12))
                .listRowSeparator(Theme.isMusic ? .visible : .hidden)
                .listRowSeparatorTint(Theme.line)
            }
            .onDelete { offsets in
                delete(IndexSet(offsets.map { shown[$0].index }))
            }
            .onMove(perform: query.isEmpty ? move : nil)
        }
        .scrollDismissesKeyboard(.immediately)
        .environment(\.songPlace, songPlace)
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(title).font(.system(size: 15, weight: .bold))
            }
            if Theme.isMusic, kind != .downloads {
                ToolbarItem(placement: .topBarTrailing) { downloadButton(tracks) }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if case .playlist(let id) = kind {
                    Button {
                        editing = library.playlist(id)
                    } label: {
                        Text("Edit").font(.system(size: 15, weight: .semibold))
                    }
                    .accessibilityLabel("Edit playlist")
                }
            }
        }
        .sheet(item: $editing) { p in
            EditPlaylistView(playlist: p)
        }
        .onChange(of: library.playlists.count) { _, _ in
            // Playlist deleted from the edit sheet: go back to the library.
            if case .playlist(let id) = kind, library.playlist(id) == nil { dismiss() }
        }
        .task(id: tracks.first?.id) {
            player.prefetch(Array(tracks.prefix(2)))
            if let first = tracks.first, let c = await ArtworkPalette.color(for: first.artwork(size: 200)) {
                headerColor = c
            } else {
                headerColor = tileColor.opacity(0.45)
            }
        }
    }

    private var emptyText: String {
        switch kind {
        case .liked: "Songs you like will appear here. Tap ⋯ on any song and choose Like."
        case .downloads: "Download songs or whole playlists to play them without a connection."
        case .playlist: "Add songs from Search with ⋯ → Add to playlist."
        }
    }

    @ViewBuilder private func header(_ tracks: [Track]) -> some View {
        if Theme.isMusic { musicHeader(tracks) } else { spotifyHeader(tracks) }
    }

    /// Download all / remove downloads (in the top bar in the Apple Music style).
    private func downloadButton(_ tracks: [Track]) -> some View {
        let allDownloaded = !tracks.isEmpty && tracks.allSatisfy { library.isDownloaded($0.id) }
        let downloading = tracks.contains { downloads.isActive($0.id) }
        return Button {
            if allDownloaded {
                tracks.forEach { library.removeDownload($0.id) }
            } else {
                downloads.download(tracks, name: title)
            }
        } label: {
            if downloading {
                ProgressView()
            } else {
                Image(systemName: allDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle")
            }
        }
        .disabled(tracks.isEmpty)
        .accessibilityLabel(allDownloaded ? "Remove downloads" : "Download all")
    }

    /// Who the list is by, in red under the title (Apple Music style).
    private var byline: String? {
        switch kind {
        case .playlist(let id):
            guard let p = library.playlist(id) else { return nil }
            if p.isAlbum == true { return p.albumArtist ?? "Album" }
            return SocialStore.shared.me?.username ?? "Playlist"
        case .liked: return SocialStore.shared.me?.username
        case .downloads: return nil
        }
    }

    private func musicHeader(_ tracks: [Track]) -> some View {
        let downloadedCount = tracks.filter { library.isDownloaded($0.id) }.count
        return VStack(spacing: 4) {
            Group {
                if case .playlist(let id) = kind, let p = library.playlist(id) {
                    PlaylistArt(playlist: p, size: 250, corner: 10)
                } else {
                    PlaylistCover(tracks: tracks, size: 250, color: tileColor, symbol: symbol, corner: 10)
                }
            }
            .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
            .padding(.top, 8)
            .padding(.bottom, 12)

            Text(title)
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
            if let byline {
                Text(byline)
                    .font(.system(size: 17))
                    .foregroundStyle(accent)
            }
            Text(subtitle(tracks, downloadedCount))
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .padding(.top, 2)
            DownloadStatusLine(tracks: kind == .downloads ? [] : tracks)

            HStack(spacing: 12) {
                pill("Play", "play.fill") {
                    if isPlayingThis { player.togglePlay() } else { player.play(tracks, from: title) }
                }
                pill("Shuffle", "shuffle") { player.shufflePlay(tracks, from: title) }
            }
            .disabled(tracks.isEmpty)
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func pill(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func spotifyHeader(_ tracks: [Track]) -> some View {
        let downloadedCount = tracks.filter { library.isDownloaded($0.id) }.count
        let allDownloaded = !tracks.isEmpty && downloadedCount == tracks.count
        let downloading = tracks.contains { downloads.isActive($0.id) }

        return VStack(alignment: .leading, spacing: 16) {
            Group {
                if case .playlist(let id) = kind, let p = library.playlist(id) {
                    PlaylistArt(playlist: p, size: 200, corner: 6)
                } else {
                    PlaylistCover(tracks: tracks, size: 200, color: tileColor, symbol: symbol, corner: 6)
                }
            }
                .shadow(color: .black.opacity(0.5), radius: 20, y: 12)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 26, weight: .heavy))
                    .tracking(-0.5)
                Text(subtitle(tracks, downloadedCount))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text2)
                DownloadStatusLine(tracks: kind == .downloads ? [] : tracks)
            }

            HStack(spacing: 4) {
                if kind != .downloads {
                    Button {
                        if allDownloaded {
                            tracks.forEach { library.removeDownload($0.id) }
                        } else {
                            downloads.download(tracks, name: title)
                        }
                    } label: {
                        Group {
                            if downloading {
                                ProgressView().tint(accent)
                            } else {
                                Image(systemName: allDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle")
                                    .font(.system(size: 26))
                                    .foregroundStyle(allDownloaded ? accent : Theme.text2)
                            }
                        }
                        .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(tracks.isEmpty)
                    .accessibilityLabel(allDownloaded ? "Remove downloads" : "Download all")
                }
                Spacer()
                Button {
                    player.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(player.shuffle ? accent : Theme.text2)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.shuffle ? "Shuffle on" : "Shuffle off")

                Button {
                    if isPlayingThis {
                        player.togglePlay()
                    } else if player.shuffle {
                        player.shufflePlay(tracks, from: title)
                    } else {
                        player.play(tracks, from: title)
                    }
                } label: {
                    Image(systemName: isPlayingThis && player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 56, height: 56)
                        .background(accent, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(tracks.isEmpty)
                .accessibilityLabel(isPlayingThis && player.isPlaying ? "Pause" : "Play")
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .background(
            LinearGradient(colors: [colorScheme == .light ? headerColor.opacity(0.35) : headerColor, Theme.bg],
                           startPoint: .top, endPoint: .bottom)
                .padding(.top, -400)
        )
    }

    private var isPlayingThis: Bool {
        player.playingFrom == title && tracks.contains { $0.id == player.current?.id }
    }

    private func subtitle(_ tracks: [Track], _ downloaded: Int) -> String {
        var s = "\(tracks.count) songs"
        if !tracks.isEmpty { s += " · \(formatTotal(tracks))" }
        if kind != .downloads, downloaded > 0 { s += " · \(downloaded) downloaded" }
        return s
    }

    private var songPlace: SongPlace? {
        switch kind {
        case .liked: .liked
        case .playlist(let id): .playlist(id)
        case .downloads: nil
        }
    }

    private var query: String { filter.trimmingCharacters(in: .whitespaces) }

    /// Songs matching the filter (title, artist or album), with their place in the full list.
    private struct Item: Identifiable {
        let index: Int
        let track: Track
        var id: String { track.id }
    }

    private func filtered(_ tracks: [Track]) -> [Item] {
        let all = tracks.enumerated().map { Item(index: $0.offset, track: $0.element) }
        guard !query.isEmpty else { return all }
        return all.filter { item in
            item.track.title.localizedStandardContains(query)
                || item.track.artist.localizedStandardContains(query)
                || (item.track.album?.localizedStandardContains(query) ?? false)
        }
    }

    private var filterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.muted)
            TextField("", text: $filter, prompt: Text("Find in \(kind == .downloads ? "downloads" : "playlist")")
                .foregroundStyle(Theme.muted))
                .font(.system(size: 14, weight: .medium))
                .focused($filterFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !filter.isEmpty {
                Button {
                    filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
                        .frame(width: 32, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func delete(_ offsets: IndexSet) {
        switch kind {
        case .liked: library.removeLiked(at: offsets)
        case .downloads:
            let ids = offsets.map { library.downloaded[$0].id }
            ids.forEach { library.removeDownload($0) }
        case .playlist(let id): library.removeTracks(at: offsets, from: id)
        }
    }

    private func move(_ from: IndexSet, _ to: Int) {
        switch kind {
        case .liked: library.moveLiked(from: from, to: to)
        case .downloads: break
        case .playlist(let id): library.moveTracks(from: from, to: to, in: id)
        }
    }
}
