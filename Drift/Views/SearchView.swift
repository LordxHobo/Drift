import SwiftUI

struct SearchView: View {
    enum Mode: String, Hashable {
        case songs, podcasts
    }

    @State private var query = ""
    @State private var mode: Mode = .songs
    @State private var results: [Track] = []
    @State private var topArtist: ArtistRef?
    @State private var channels: [PodcastChannel] = []
    @State private var episodes: [Track] = []
    @State private var loading = false
    @State private var error: String?
    @FocusState private var focused: Bool
    private var player: Player { .shared }
    private var settings: AppSettings { .shared }
    private var accent: Color { settings.accent }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasResults: Bool { mode == .songs ? !results.isEmpty : !(channels.isEmpty && episodes.isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Search")
                .font(.system(size: 26, weight: .heavy))
                .tracking(-0.5)
                .padding(.horizontal, 20)
                .padding(.top, 8)

            searchField

            HStack(spacing: 8) {
                modeChip("Songs", .songs)
                modeChip("Podcasts", .podcasts)
            }
            .padding(.horizontal, 20)

            Group {
                if loading && !hasResults {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if let error, !hasResults {
                    message(error)
                } else if !hasResults && trimmed.count >= 2 && !loading {
                    message("Nothing found for “\(query)”")
                } else if !hasResults {
                    message(prompt)
                } else if mode == .songs {
                    songList
                } else {
                    podcastList
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: "\(mode.rawValue)|\(settings.preferOfficialAudio)|\(query)") {
            await search()
        }
    }

    private var prompt: String {
        switch mode {
        case .songs:
            settings.preferOfficialAudio
                ? "Search songs, artists and albums from YouTube Music."
                : "Search songs and music videos from YouTube."
        case .podcasts:
            "Search podcasts and channels on YouTube, or paste a YouTube link to play any video."
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color(hex: 0x3F3F46))
            TextField("", text: $query,
                      prompt: Text(mode == .songs ? "What do you want to listen to?" : "Podcasts, channels or a YouTube link")
                        .foregroundStyle(Color(hex: 0x52525B)))
                .foregroundStyle(Color(hex: 0x18181B))
                .font(.system(size: 15, weight: .semibold))
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color(hex: 0x52525B))
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(Theme.searchField, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 20)
    }

    private func modeChip(_ title: String, _ m: Mode) -> some View {
        let selected = mode == m
        return Button {
            mode = m
        } label: {
            Text(title)
                .font(.system(size: 13, weight: selected ? .bold : .semibold))
                .foregroundStyle(selected ? Theme.onAccent : Theme.text)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background(selected ? accent : Theme.surface2, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var songList: some View {
        List {
            if let a = topArtist {
                NavigationLink(value: Route.artist(a)) {
                    HStack(spacing: 14) {
                        AsyncImage(url: resizedImage(a.thumbnail, size: 200)) { phase in
                            if let img = phase.image { img.resizable().scaledToFill() } else { Theme.tile(seed: a.name) }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(a.name).font(.system(size: 17, weight: .bold)).lineLimit(1)
                            Text("Artist").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .listRowBackground(Theme.bg)
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
            }
            ForEach(Array(results.enumerated()), id: \.element.id) { i, t in
                TrackRow(track: t) {
                    focused = false
                    player.play(results, startAt: i, from: "Search “\(query)”")
                }
                .listRowBackground(Theme.bg)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 12))
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
    }

    private var podcastList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !channels.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Channels").font(.system(size: 17, weight: .heavy))
                        ForEach(channels.prefix(4)) { c in
                            HStack(spacing: 12) {
                                NavigationLink(value: Route.channel(c)) {
                                    HStack(spacing: 12) {
                                        ChannelAvatar(name: c.name, url: c.avatarURL, size: 52)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(c.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                            if let s = c.subtitle {
                                                Text(s).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                FollowButton(channel: c, compact: true)
                            }
                        }
                    }
                }
                if !episodes.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Episodes").font(.system(size: 17, weight: .heavy)).padding(.bottom, 4)
                        LazyVStack(spacing: 0) {
                            ForEach(episodes) { t in
                                EpisodeRow(track: t) {
                                    focused = false
                                    player.play([t], from: t.artist)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(Theme.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, 40)
    }

    private func search() async {
        let q = trimmed
        guard q.count >= 2 else {
            results = []; channels = []; episodes = []; topArtist = nil
            error = nil
            return
        }
        // A pasted link plays straight away, no need to wait for typing to stop.
        let isLink = YouTubeSearch.videoID(fromLink: q) != nil
        if !isLink {
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
        }
        loading = true
        defer { loading = false }
        do {
            switch mode {
            case .songs:
                // Songs and artists at the same time; an artist whose name matches goes on top.
                async let artistsTask = try? Artists.search(q)
                let found = try await YTMusic.search(q, songsOnly: settings.preferOfficialAudio)
                let artists = await artistsTask ?? []
                guard !Task.isCancelled else { return }
                results = found
                topArtist = Artists.bestMatch(artists, for: q)
                player.prefetch(Array(found.prefix(2)))
            case .podcasts:
                if isLink {
                    let t = try await YouTubeSearch.resolve(link: q)
                    guard !Task.isCancelled else { return }
                    channels = []
                    episodes = t.map { [$0] } ?? []
                } else {
                    let found = try await YouTubeSearch.search(q)
                    guard !Task.isCancelled else { return }
                    channels = found.channels
                    episodes = found.episodes
                    player.prefetch(Array(found.episodes.prefix(2)))
                }
            }
            error = nil
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            self.error = "Search failed. Check your connection and try again."
        }
    }
}
