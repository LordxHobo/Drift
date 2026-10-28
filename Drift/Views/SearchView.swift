import SwiftUI
import Observation

/// Recent searches, kept on the phone (separately for songs, YouTube and podcasts).
@Observable @MainActor
final class SearchHistory {
    static let shared = SearchHistory()

    struct Entry: Codable, Hashable {
        var text: String
        var podcasts: Bool
        var youtube: Bool? = nil

        /// "songs", "youtube" or "podcasts".
        var mode: String { youtube == true ? "youtube" : (podcasts ? "podcasts" : "songs") }
    }

    private(set) var entries: [Entry] = []
    @ObservationIgnored private let key = "search.history"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = list
        }
    }

    func items(_ mode: String) -> [Entry] { entries.filter { $0.mode == mode } }

    func add(_ text: String, mode: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return }
        // Same search again moves to the top.
        entries.removeAll { $0.mode == mode && $0.text.lowercased() == t.lowercased() }
        entries.insert(Entry(text: t, podcasts: mode == "podcasts", youtube: mode == "youtube" ? true : nil), at: 0)
        if entries.count > 60 { entries.removeLast(entries.count - 60) }
        save()
    }

    func remove(_ e: Entry) {
        entries.removeAll { $0 == e }
        save()
    }

    func clear(_ mode: String) {
        entries.removeAll { $0.mode == mode }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: key) }
    }
}

struct SearchView: View {
    enum Mode: String, Hashable {
        case songs, youtube, podcasts
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
    private var history: SearchHistory { .shared }
    private var historyItems: [SearchHistory.Entry] { history.items(mode.rawValue) }
    private var showingHistory: Bool { trimmed.isEmpty && !historyItems.isEmpty }
    private var accent: Color { settings.accent }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasResults: Bool { mode == .podcasts ? !(channels.isEmpty && episodes.isEmpty) : !results.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Search")
                .font(Theme.titleFont)
                .tracking(-0.5)
                .padding(.horizontal, 20)
                .padding(.top, 8)

            searchField

            HStack(spacing: 8) {
                modeChip("Songs", .songs)
                modeChip("YouTube", .youtube)
                modeChip("Podcasts", .podcasts)
                Spacer()
                if showingHistory {
                    Button("Clear all") { history.clear(mode.rawValue) }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 34)
                        .overlay(Capsule().stroke(Theme.muted, lineWidth: 1))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)

            Group {
                if showingHistory {
                    historyList
                } else if loading && !hasResults {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if let error, !hasResults {
                    message(error)
                } else if !hasResults && trimmed.count >= 2 && !loading {
                    message("Nothing found for “\(query)”")
                } else if !hasResults {
                    message(prompt)
                } else if mode != .podcasts {
                    songList
                } else {
                    podcastList
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        // Opening an artist or channel from the results keeps the search in Recent searches.
        .onDisappear { if hasResults { remember() } }
        .task(id: "\(mode.rawValue)|\(settings.preferOfficialAudio)|\(settings.preferExplicit)|\(query)") {
            await search()
        }
    }

    private var prompt: String {
        switch mode {
        case .songs:
            settings.preferOfficialAudio
                ? "Search songs, artists and albums from YouTube Music."
                : "Search songs and music videos from YouTube."
        case .youtube:
            "Search all of YouTube for anything that isn't on YouTube Music (fan uploads, live sets, mixes), or paste a YouTube link. Only the audio plays."
        case .podcasts:
            "Search podcasts and channels on YouTube, or paste a YouTube link to play any video."
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.isMusic ? Theme.muted : Color(hex: 0x3F3F46))
            TextField("", text: $query,
                      prompt: Text(mode == .songs ? "What do you want to listen to?"
                                   : mode == .youtube ? "Search YouTube or paste a link" : "Podcasts, channels or a YouTube link")
                        .foregroundStyle(Theme.isMusic ? Theme.muted : Color(hex: 0x52525B)))
                .foregroundStyle(Theme.searchText)
                .font(.system(size: 15, weight: .semibold))
                .focused($focused)
                .submitLabel(.search)
                .onSubmit { remember() }
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.isMusic ? Theme.muted : Color(hex: 0x52525B))
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
            guard mode != m else { return }
            results = []
            topArtist = nil
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
                    remember()
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
                                    remember()
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

    private func remember() {
        // Pasted links aren't worth keeping.
        guard YouTubeSearch.videoID(fromLink: trimmed) == nil else { return }
        history.add(trimmed, mode: mode.rawValue)
    }

    private var historyList: some View {
        List {
            Text("Recent searches")
                .font(.system(size: 17, weight: .heavy))
                .listRowBackground(Theme.bg)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 12))
            ForEach(historyItems, id: \.self) { e in
                HStack(spacing: 12) {
                    Button {
                        query = e.text
                        history.add(e.text, mode: e.mode)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.muted)
                                .frame(width: 24)
                            Text(e.text)
                                .font(.system(size: 15, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        history.remove(e)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove “\(e.text)” from recent searches")
                }
                .listRowBackground(Theme.bg)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 8))
                .swipeActions {
                    Button(role: .destructive) { history.remove(e) } label: { Label("Remove", systemImage: "trash") }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
            case .youtube:
                // Any YouTube video, played as a song (audio only, kept as it is).
                let found: [Track]
                if isLink {
                    found = (try await YouTubeSearch.resolve(link: q)).map { [$0] } ?? []
                } else {
                    found = try await YouTubeSearch.search(q).episodes
                }
                guard !Task.isCancelled else { return }
                results = found.map { v in
                    var t = v
                    t.podcast = nil
                    t.upload = true
                    return t
                }
                topArtist = nil
                player.prefetch(Array(results.prefix(2)))
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
