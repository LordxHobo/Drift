import SwiftUI

// MARK: Artist page

struct ArtistView: View {
    let artist: ArtistRef
    @State private var page: ArtistPage?
    @State private var failed = false
    private var player: Player { .shared }
    private var store: ArtistStore { .shared }
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if let page {
                    newReleaseRow(page)
                    if !page.topSongs.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            sectionTitle("Popular")
                            ForEach(Array(page.topSongs.prefix(10).enumerated()), id: \.element.id) { i, t in
                                TrackRow(track: t) {
                                    player.play(page.topSongs, startAt: i, from: page.name)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    AlbumShelf(title: "Albums", albums: page.albums, more: page.albumsMore, artist: page.name)
                    AlbumShelf(title: "Singles & EPs", albums: page.singles, more: page.singlesMore, artist: page.name)
                } else if failed {
                    Text("Couldn't load this artist. Pull down to try again.")
                        .font(.system(size: 14)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity).padding(.top, 20)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .refreshable { await load() }
        .task { if page == nil { await load() } }
    }

    private var header: some View {
        let name = page?.name ?? artist.name
        let image = resizedImage(page?.thumbnail ?? artist.thumbnail, size: 900)
        return ZStack(alignment: .bottomLeading) {
            AsyncImage(url: image) { phase in
                if let img = phase.image {
                    img.resizable().scaledToFill()
                } else {
                    Theme.tile(seed: name)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 320)
            .clipped()
            .overlay(LinearGradient(colors: [.clear, Theme.bg.opacity(0.6), Theme.bg],
                                    startPoint: .center, endPoint: .bottom))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text(name)
                    .font(.system(size: 40, weight: .heavy))
                    .tracking(-1)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                if let sub = page?.subtitle {
                    Text(sub).font(.system(size: 13)).foregroundStyle(Theme.text2)
                }
                HStack(spacing: 4) {
                    followButton
                    Spacer()
                    if let songs = page?.topSongs, !songs.isEmpty {
                        Button { player.shufflePlay(songs, from: name) } label: {
                            Image(systemName: "shuffle")
                                .font(.system(size: 20, weight: .semibold))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Shuffle \(name)")
                        Button { player.play(songs, from: name) } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(Theme.onAccent)
                                .frame(width: 56, height: 56)
                                .background(accent, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play \(name)")
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var followButton: some View {
        let following = store.isFollowing(artist.id)
        return Button {
            if following { store.unfollow(artist.id) } else { store.follow(artist, page: page) }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Text(following ? "Following" : "Follow")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 16)
                .frame(minHeight: 32)
                .overlay(Capsule().stroke(following ? accent : Theme.muted, lineWidth: 1))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(following ? "Unfollow \(page?.name ?? artist.name)" : "Follow \(page?.name ?? artist.name)")
    }

    /// Releases found since you followed the artist; otherwise their most recent one.
    @ViewBuilder private func newReleaseRow(_ page: ArtistPage) -> some View {
        let fresh = store.newReleases(of: artist.id).map(\.album)
        let releases = fresh.isEmpty ? latest(page).map { [$0] } ?? [] : fresh
        if !releases.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle(fresh.isEmpty ? "Latest release" : (fresh.count == 1 ? "New release" : "New releases"))
                ForEach(releases, id: \.id) { a in
                    NavigationLink(value: Route.album(a, artist: page.name)) {
                        HStack(spacing: 14) {
                            AsyncImage(url: resizedImage(a.thumbnail, size: 300)) { phase in
                                if let img = phase.image { img.resizable().scaledToFill() } else { Theme.tile(seed: a.id) }
                            }
                            .frame(width: 84, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                if !fresh.isEmpty {
                                    Text("NEW")
                                        .font(.system(size: 10, weight: .heavy))
                                        .tracking(0.8)
                                        .foregroundStyle(accent)
                                }
                                Text(a.title).font(.system(size: 16, weight: .bold)).lineLimit(2)
                                Text(a.subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.muted)
                        }
                        .padding(10)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    /// The newest of the first album and first single (both lists are newest first).
    private func latest(_ page: ArtistPage) -> AlbumRef? {
        switch (page.albums.first, page.singles.first) {
        case let (a?, s?): return (a.year ?? "") > (s.year ?? "") ? a : s
        case let (a?, nil): return a
        case let (nil, s?): return s
        default: return nil
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.system(size: 20, weight: .heavy)).tracking(-0.3).padding(.bottom, 4)
    }

    private func load() async {
        do {
            let loaded = try await Artists.page(artist)
            page = loaded
            failed = false
            store.update(artist.id, with: loaded)
            if let songs = page?.topSongs { player.prefetch(Array(songs.prefix(2))) }
        } catch {
            if page == nil { failed = true }
        }
    }
}

/// A row of album covers with an optional "See all".
struct AlbumShelf: View {
    let title: String
    let albums: [AlbumRef]
    let more: BrowseRef?
    let artist: String

    var body: some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title).font(.system(size: 20, weight: .heavy)).tracking(-0.3)
                    Spacer()
                    NavigationLink(value: Route.discography(title: title, ref: more, albums: albums, artist: artist)) {
                        Text("See all")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.muted)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(albums, id: \.id) { a in
                            NavigationLink(value: Route.album(a, artist: artist)) {
                                AlbumCard(album: a, size: 150)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }
}

struct AlbumCard: View {
    let album: AlbumRef
    var size: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: resizedImage(album.thumbnail, size: 400)) { phase in
                if let img = phase.image { img.resizable().scaledToFill() } else { Theme.tile(seed: album.id) }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
            Text(album.title)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(album.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
        .frame(width: size, alignment: .leading)
    }
}

// MARK: Full discography

struct DiscographyView: View {
    let title: String
    let ref: BrowseRef?
    let initial: [AlbumRef]
    let artist: String
    @State private var albums: [AlbumRef] = []

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .top),
                                GridItem(.flexible(), spacing: 14, alignment: .top)], spacing: 20) {
                ForEach(albums, id: \.id) { a in
                    NavigationLink(value: Route.album(a, artist: artist)) {
                        GeometryReader { g in
                            AlbumCard(album: a, size: g.size.width)
                        }
                        .aspectRatio(0.72, contentMode: .fit)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .task {
            if albums.isEmpty { albums = initial }
            if let ref, let all = try? await Artists.discography(ref), !all.isEmpty {
                // Newest first.
                albums = all.sorted { ($0.year ?? "") > ($1.year ?? "") }
            }
        }
    }
}

// MARK: Album page

struct AlbumView: View {
    let album: AlbumRef
    let artist: String
    @State private var page: AlbumPage?
    @State private var failed = false
    @State private var saved = false
    private var player: Player { .shared }
    private var library: Library { .shared }
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        let tracks = page?.tracks ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AsyncImage(url: resizedImage(page?.thumbnail ?? album.thumbnail, size: 700)) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() } else { Theme.tile(seed: album.id) }
                }
                .frame(width: 230, height: 230)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 12)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(page?.title ?? album.title)
                        .font(.system(size: 24, weight: .heavy))
                        .tracking(-0.4)
                    Text(page?.artist ?? artist)
                        .font(.system(size: 14, weight: .bold))
                    Text(subtitle(tracks))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                    DownloadStatusLine(tracks: tracks)
                }

                HStack(spacing: 4) {
                    Button {
                        downloadOrRemove(tracks)
                    } label: {
                        Image(systemName: allDownloaded(tracks) ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .font(.system(size: 26))
                            .foregroundStyle(allDownloaded(tracks) ? accent : Theme.text2)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(allDownloaded(tracks) ? "Remove downloads" : "Download album")
                    Button {
                        guard let page else { return }
                        library.createPlaylist(page.title, tracks: page.tracks)
                        saved = true
                    } label: {
                        Image(systemName: saved ? "checkmark.circle.fill" : "plus.circle")
                            .font(.system(size: 26))
                            .foregroundStyle(saved ? accent : Theme.text2)
                            .frame(width: 44, height: 44)
                    }
                    .disabled(saved || tracks.isEmpty)
                    .accessibilityLabel(saved ? "Saved to your library" : "Save to your library")
                    Spacer()
                    Button { player.shufflePlay(tracks, from: page?.title ?? album.title) } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Shuffle album")
                    Button { player.play(tracks, from: page?.title ?? album.title) } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.onAccent)
                            .frame(width: 56, height: 56)
                            .background(accent, in: Circle())
                    }
                    .accessibilityLabel("Play album")
                }
                .buttonStyle(.plain)
                .disabled(tracks.isEmpty)

                if page == nil {
                    if failed {
                        Text("Couldn't load this album.").foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }

                VStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                        AlbumTrackRow(number: i + 1, track: t, albumArtist: page?.artist ?? artist) {
                            player.play(tracks, startAt: i, from: page?.title ?? album.title)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .task {
            guard page == nil else { return }
            do {
                page = try await Artists.album(album, artistName: artist)
                if let t = page?.tracks { player.prefetch(Array(t.prefix(2))) }
            } catch {
                failed = true
            }
        }
    }

    private func subtitle(_ tracks: [Track]) -> String {
        var parts = [page?.subtitle ?? album.subtitle]
        if !tracks.isEmpty {
            parts.append("\(tracks.count) songs")
            if tracks.allSatisfy({ $0.duration != nil }) { parts.append(formatTotal(tracks)) }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func allDownloaded(_ tracks: [Track]) -> Bool {
        !tracks.isEmpty && tracks.allSatisfy { library.isDownloaded($0.id) }
    }

    private func downloadOrRemove(_ tracks: [Track]) {
        if allDownloaded(tracks) {
            tracks.forEach { library.removeDownload($0.id) }
        } else {
            DownloadManager.shared.download(tracks, name: page?.title ?? album.title)
        }
    }
}

struct AlbumTrackRow: View {
    let number: Int
    let track: Track
    let albumArtist: String
    var onTap: () -> Void
    private var player: Player { .shared }

    var body: some View {
        let isCurrent = player.current?.id == track.id
        HStack(spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 14) {
                    Text("\(number)")
                        .font(.system(size: 14).monospacedDigit())
                        .foregroundStyle(isCurrent ? AppSettings.shared.accent : Theme.muted)
                        .frame(width: 24, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(isCurrent ? AppSettings.shared.accent : Theme.text)
                            .lineLimit(1)
                        if !track.artist.isEmpty && track.artist != albumArtist {
                            Text(track.artist).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    if Library.shared.isDownloaded(track.id) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(AppSettings.shared.accent)
                    }
                    Text(track.durationText).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            LikeButton(track: track, size: 16)
            Menu { TrackMenuItems(track: track) } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 28, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More options for \(track.title)")
        }
        .contextMenu { TrackMenuItems(track: track) }
    }
}
