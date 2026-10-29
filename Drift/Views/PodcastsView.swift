import SwiftUI

// MARK: Podcasts tab

struct PodcastsView: View {
    private var store: PodcastStore { .shared }
    private var player: Player { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Podcasts")
                    .font(Theme.titleFont)
                    .tracking(-0.5)

                if store.subscriptions.isEmpty && store.continueListening.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Follow your first podcast")
                            .font(.system(size: 20, weight: .heavy))
                        Text("Go to Search, switch to Podcasts and look up a show or channel (or paste a show's feed link). Tap Follow and new episodes show up here. You can also paste a YouTube link there to play any video.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                            .lineSpacing(2)
                    }
                }

                let resume = store.continueListening
                if !resume.isEmpty {
                    section("Continue listening") {
                        ForEach(resume, id: \.track.id) { p in
                            EpisodeRow(track: p.track) { player.play([p.track], from: p.track.artist) }
                        }
                    }
                }

                if !store.subscriptions.isEmpty {
                    section("Following") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(store.subscriptions) { c in
                                    NavigationLink(value: Route.channel(c)) {
                                        VStack(spacing: 8) {
                                            ChannelAvatar(name: c.name, url: c.avatarURL, size: 76, square: c.isFeed)
                                            Text(c.name)
                                                .font(.system(size: 12, weight: .semibold))
                                                .lineLimit(2)
                                                .multilineTextAlignment(.center)
                                                .frame(width: 84)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .scrollClipDisabled()
                    }

                    section("New episodes") {
                        let episodes = store.newEpisodes
                        if episodes.isEmpty {
                            if store.refreshing {
                                ProgressView().frame(maxWidth: .infinity).padding(.top, 12)
                            } else {
                                Text("No episodes yet. Pull down to refresh.")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                        LazyVStack(spacing: 0) {
                            ForEach(episodes) { t in
                                EpisodeRow(track: t) { player.play([t], from: t.artist) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await store.refresh(force: true) }
        .task {
            await store.refresh(force: false)
            // Get the first few ready so they start the moment they're tapped.
            player.prefetch(Array(store.continueListening.prefix(2).map(\.track)) + Array(store.newEpisodes.prefix(3)))
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 20, weight: .heavy))
                .tracking(-0.3)
            content()
        }
    }
}

// MARK: Channel page

struct ChannelView: View {
    let channel: PodcastChannel
    private var store: PodcastStore { .shared }
    private var player: Player { .shared }

    var body: some View {
        let episodes = store.feeds[channel.id] ?? []
        ScrollView {
            VStack(spacing: 14) {
                ChannelAvatar(name: channel.name, url: channel.avatarURL, size: 120, square: channel.isFeed)
                    .padding(.top, 8)
                Text(channel.name)
                    .font(.system(size: 24, weight: .heavy))
                    .multilineTextAlignment(.center)
                if let sub = channel.subtitle {
                    Text(sub).font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                FollowButton(channel: channel)

                VStack(alignment: .leading, spacing: 0) {
                    if episodes.isEmpty {
                        if store.loadingChannels.contains(channel.id) {
                            ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
                        } else {
                            Text("Couldn't load episodes. Pull down to try again.")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.muted)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 24)
                        }
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(episodes) { t in
                            EpisodeRow(track: t, showChannel: false) { player.play([t], from: channel.name) }
                        }
                    }
                }
                .padding(.top, 12)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .refreshable { await store.loadChannel(channel) }
        .task {
            await store.loadChannel(channel)
            player.prefetch(Array((store.feeds[channel.id] ?? []).prefix(2)))
        }
    }
}

// MARK: Building blocks

struct FollowButton: View {
    let channel: PodcastChannel
    var compact = false
    private var store: PodcastStore { .shared }

    var body: some View {
        let following = store.isFollowing(channel.id)
        Button {
            store.toggleFollow(channel)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Text(following ? "Following" : "Follow")
                .font(.system(size: compact ? 12 : 14, weight: .bold))
                .foregroundStyle(following ? Theme.text : Theme.onAccent)
                .padding(.horizontal, compact ? 12 : 20)
                .frame(minHeight: compact ? 30 : 38)
                .background(following ? Color.clear : AppSettings.shared.accent, in: Capsule())
                .overlay(Capsule().stroke(following ? Theme.muted : .clear, lineWidth: 1))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(following ? "Unfollow \(channel.name)" : "Follow \(channel.name)")
    }
}

struct ChannelAvatar: View {
    let name: String
    let url: URL?
    var size: CGFloat
    /// A show's square cover (shows from a feed) instead of a channel's round picture.
    var square = false

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Theme.tile(seed: name)
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.42, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(square ? AnyShape(RoundedRectangle(cornerRadius: size * 0.1, style: .continuous)) : AnyShape(Circle()))
        .accessibilityHidden(true)
    }
}

/// 16:9 video thumbnail (or a show's square cover, for episodes from its feed).
struct EpisodeArtwork: View {
    let url: URL?
    var width: CGFloat
    var corner: CGFloat = 6
    var square = false

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Theme.surface2
                    Image(systemName: "mic.fill")
                        .font(.system(size: width * 0.16))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .frame(width: width, height: square ? width : width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct EpisodeRow: View {
    let track: Track
    var showChannel = true
    var onTap: () -> Void

    private var store: PodcastStore { .shared }
    private var player: Player { .shared }
    private var library: Library { .shared }
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        let isCurrent = player.current?.id == track.id
        let finished = store.isFinished(track.id)
        HStack(alignment: .top, spacing: 12) {
            Button(action: onTap) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack(alignment: .bottom) {
                        let square = track.isFeedEpisode
                        EpisodeArtwork(url: track.artworkURL ?? track.artwork(size: 320), width: square ? 63 : 112, square: square)
                        if let f = store.fraction(track.id) {
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(.black.opacity(0.5))
                                    Rectangle().fill(accent).frame(width: g.size.width * f)
                                }
                            }
                            .frame(width: track.isFeedEpisode ? 55 : 104, height: 3)
                            .clipShape(Capsule())
                            .padding(.bottom, 4)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isCurrent ? accent : (finished ? Theme.muted : Theme.text))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(meta)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            if finished {
                                Label("Played", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.muted)
                            }
                            if library.isDownloaded(track.id) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(accent)
                                    .accessibilityLabel("Downloaded")
                            } else if let p = DownloadManager.shared.progress[track.id] {
                                ProgressView(value: p).progressViewStyle(.circular).controlSize(.mini).tint(accent)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                EpisodeMenuItems(track: track)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More options for \(track.title)")
        }
        .padding(.vertical, 8)
        .contextMenu { EpisodeMenuItems(track: track) }
    }

    private var meta: String {
        var parts: [String] = []
        if showChannel, !track.artist.isEmpty { parts.append(track.artist) }
        if let d = formatPublished(track.published) { parts.append(d) }
        if let left = store.remaining(track.id) {
            parts.append("\(formatLength(left)) left")
        } else if let d = track.duration {
            parts.append(formatLength(d))
        }
        return parts.joined(separator: " · ")
    }
}

struct EpisodeMenuItems: View {
    let track: Track
    private var store: PodcastStore { .shared }
    private var library: Library { .shared }

    var body: some View {
        Button {
            Player.shared.playNext(track)
        } label: { Label("Play next", systemImage: "text.insert") }

        if store.isFinished(track.id) || store.fraction(track.id) != nil {
            Button {
                store.markUnplayed(track.id)
            } label: { Label("Mark as unplayed", systemImage: "arrow.counterclockwise") }
        }
        if !store.isFinished(track.id) {
            Button {
                store.markFinished(track)
            } label: { Label("Mark as played", systemImage: "checkmark.circle") }
        }

        if library.isDownloaded(track.id) {
            Button(role: .destructive) {
                library.removeDownload(track.id)
            } label: { Label("Remove download", systemImage: "trash") }
        } else {
            Button {
                DownloadManager.shared.download(track)
            } label: { Label("Download", systemImage: "arrow.down.circle") }
        }

        Button {
            UIState.shared.addToPlaylist = track
        } label: { Label("Add to playlist", systemImage: "text.badge.plus") }

        if let c = store.channel(for: track) {
            Button {
                store.toggleFollow(c)
            } label: {
                store.isFollowing(c.id)
                    ? Label("Unfollow \(c.name)", systemImage: "person.badge.minus")
                    : Label("Follow \(c.name)", systemImage: "person.badge.plus")
            }
        }
    }
}
