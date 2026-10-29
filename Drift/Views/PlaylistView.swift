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
    /// How the list is sorted (nil = your own order), remembered per list.
    @State private var sort: SongSort?
    @State private var showSortSheet = false
    /// The Collaborators sheet.
    @State private var showCollab = false
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
        let all = ordered(tracks)
        let playOrder = all.map(\.track)
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
                HStack(spacing: 10) {
                    filterField
                    if sortable && !Theme.isMusic { sortButton }
                }
                    .listRowBackground(Theme.bg)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 8, trailing: 20))
            }

            let shown = filtered(all)
            if !query.isEmpty && shown.isEmpty {
                Text("No songs or artists matching “\(query)”")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                    .listRowBackground(Theme.bg)
                    .listRowSeparator(.hidden)
            }

            // Tapping a song plays the whole list (in the order shown) from that song, filtered or not.
            ForEach(shown) { item in
                TrackRow(track: item.track) {
                    filterFocused = false
                    let start = all.firstIndex { $0.index == item.index } ?? 0
                    player.play(playOrder, startAt: start, from: title)
                }
                .listRowBackground(Theme.bg)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 12))
                .listRowSeparator(Theme.isMusic ? .visible : .hidden)
                .listRowSeparatorTint(Theme.line)
            }
            .onDelete { offsets in
                delete(IndexSet(offsets.map { shown[$0].index }))
            }
            // Dragging to reorder only in your own order (not filtered or sorted).
            .onMove(perform: query.isEmpty && activeSort == nil ? move : nil)
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
            if Theme.isMusic, sortable {
                ToolbarItem(placement: .topBarTrailing) { sortMenu }
            }
            if Theme.isMusic, kind != .downloads {
                ToolbarItem(placement: .topBarTrailing) { downloadButton(tracks) }
            }
            if case .playlist(let id) = kind, library.playlist(id)?.isAlbum != true {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCollab = true } label: {
                        Image(systemName: library.playlist(id)?.collab != nil ? "person.2.fill" : "person.badge.plus")
                    }
                    .accessibilityLabel(library.playlist(id)?.collab != nil ? "Collaborators" : "Make collaborative")
                }
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
        .sheet(isPresented: $showCollab) {
            if case .playlist(let id) = kind { CollabSheet(playlistID: id) }
        }
        .sheet(isPresented: $showSortSheet) {
            SortSheet(sort: activeSort) { setSort($0) }
                .presentationDetents([.medium])
        }
        .onAppear { sort = SongSort.saved(for: listKey) }
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
            if let c = p.collab { return "Collaborative · \(c.names(me: SocialStore.shared.me?.id))" }
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
                    if isPlayingThis { player.togglePlay() } else { player.play(playOrder(tracks), from: title) }
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
                if case .playlist(let id) = kind, let c = library.playlist(id)?.collab {
                    Button { showCollab = true } label: {
                        Label("Collaborative · \(c.names(me: SocialStore.shared.me?.id))", systemImage: "person.2.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
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
                        player.play(playOrder(tracks), from: title)
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

    private func filtered(_ all: [Item]) -> [Item] {
        guard !query.isEmpty else { return all }
        return all.filter { item in
            item.track.title.localizedStandardContains(query)
                || item.track.artist.localizedStandardContains(query)
                || (item.track.album?.localizedStandardContains(query) ?? false)
        }
    }

    // MARK: Sorting

    /// Which saved sort belongs to this list.
    private var listKey: String {
        switch kind {
        case .liked: "liked"
        case .downloads: "downloads"
        case .playlist(let id): id.uuidString
        }
    }

    /// Albums keep their track order; playlists, Liked songs and downloads can be sorted.
    private var sortable: Bool {
        if case .playlist(let id) = kind, library.playlist(id)?.isAlbum == true { return false }
        return true
    }

    private var activeSort: SongSort? { sortable ? sort : nil }

    private func setSort(_ s: SongSort?) {
        sort = s
        SongSort.save(s, for: listKey)
    }

    /// Every song with its place in the full list, in the order shown.
    private func ordered(_ tracks: [Track]) -> [Item] {
        let items = tracks.enumerated().map { Item(index: $0.offset, track: $0.element) }
        guard let s = activeSort else { return items }
        return s.order(tracks, places: items.map(\.index), newestFirst: kind == .liked).map { items[$0] }
    }

    private func playOrder(_ tracks: [Track]) -> [Track] { ordered(tracks).map(\.track) }

    /// Drift style: "Sort" next to the filter, like Spotify; opens the sort sheet.
    private var sortButton: some View {
        Button { showSortSheet = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 13, weight: .bold))
                Text(activeSort?.key.label ?? "Sort")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(activeSort == nil ? Theme.text : accent)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(activeSort.map { "Sorted by \($0.key.label), \($0.directionLabel). Change sort" } ?? "Sort")
    }

    /// Apple Music style: a Sort By menu in the top bar, like Apple Music.
    private var sortMenu: some View {
        let key = Binding<SongSort.Key?>(
            get: { activeSort?.key },
            set: { k in setSort(k.map { SongSort.first($0) }) }
        )
        let ascending = Binding<Bool>(
            get: { activeSort?.ascending ?? true },
            set: { a in
                guard var s = activeSort else { return }
                s.ascending = a
                setSort(s)
            }
        )
        return Menu {
            Section("Sort By") {
                Picker("Sort By", selection: key) {
                    Text("Playlist Order").tag(SongSort.Key?.none)
                    ForEach(SongSort.Key.allCases, id: \.self) { k in
                        Text(k == .added ? "Recently Added" : k.label).tag(Optional(k))
                    }
                }
                .pickerStyle(.inline)
            }
            if let s = activeSort {
                Section("Order") {
                    Picker("Order", selection: ascending) {
                        Text(s.key == .added ? "Oldest First" : "Ascending").tag(true)
                        Text(s.key == .added ? "Newest First" : "Descending").tag(false)
                    }
                    .pickerStyle(.inline)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel(activeSort.map { "Sorted by \($0.key.label), \($0.directionLabel)" } ?? "Sort")
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

/// Drift style: "Sort by", like Spotify. Tap an option to sort by it; tap the chosen one again to reverse it.
private struct SortSheet: View {
    let sort: SongSort?
    let onPick: (SongSort?) -> Void
    @Environment(\.dismiss) private var dismiss
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        NavigationStack {
            List {
                row("Custom order", selected: sort == nil, arrow: nil) { onPick(nil) }
                ForEach(SongSort.Key.allCases, id: \.self) { k in
                    let on = sort?.key == k
                    row(k.label, selected: on, arrow: on ? sort?.ascending : nil) {
                        if let s = sort, s.key == k {
                            onPick(SongSort(key: k, ascending: !s.ascending))
                        } else {
                            onPick(SongSort.first(k))
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.surface)
            .navigationTitle("Sort by")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Text("Tap the one that's on again to reverse it.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .padding(.bottom, 8)
            }
        }
    }

    private func row(_ label: String, selected: Bool, arrow: Bool?, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack {
                Text(label)
                    .font(.system(size: 16, weight: selected ? .bold : .regular))
                    .foregroundStyle(selected ? accent : Theme.text)
                Spacer()
                if let arrow {
                    Text(directionText(label, ascending: arrow))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                    Image(systemName: arrow ? "arrow.up" : "arrow.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(accent)
                } else if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(accent)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.surface)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func directionText(_ label: String, ascending: Bool) -> String {
        label == SongSort.Key.added.label ? (ascending ? "Oldest first" : "Newest first") : (ascending ? "A–Z" : "Z–A")
    }
}
