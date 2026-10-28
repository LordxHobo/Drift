import SwiftUI

/// Pick a different version of a song: any version on YouTube Music (clean or explicit), or any
/// YouTube video (e.g. when an import chose the wrong upload). The song keeps its place, and the
/// version picked plays exactly as it is.
struct ReplaceSongSheet: View {
    enum Source: String, Hashable {
        case music, youtube
    }

    let request: ReplaceRequest
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var source: Source
    @State private var results: [Track] = []
    @State private var more: String?
    @State private var loadingMore = false
    @State private var loading = false
    @State private var failed = false
    private var player: Player { .shared }
    private var accent: Color { AppSettings.shared.accent }

    init(request: ReplaceRequest) {
        self.request = request
        let artist = LyricsService.mainArtist(request.track.artist)
        _query = State(initialValue: "\(artist) \(request.track.title)".trimmingCharacters(in: .whitespaces))
        _source = State(initialValue: request.track.upload == true ? .youtube : .music)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        ArtworkView(url: request.track.artwork(size: 120), size: 44, seed: request.track.id)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(request.track.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                if request.track.explicit == true { ExplicitMark() }
                            }
                            Text("\(request.track.artist) · \(request.track.durationText)")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                    .listRowBackground(Theme.surface)
                } header: {
                    Text("Now in your playlist")
                } footer: {
                    Text("Tap ▶ to listen to a version first, then Use to swap it in. The song keeps its place, and the version you pick plays exactly as it is.")
                }

                Section {
                    Picker("Where to look", selection: $source) {
                        Text("YouTube Music").tag(Source.music)
                        Text("YouTube").tag(Source.youtube)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Theme.bg)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))

                    if loading && results.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).listRowBackground(Theme.bg)
                    } else if failed && results.isEmpty {
                        Text("Search failed. Check your connection.").foregroundStyle(Theme.muted).listRowBackground(Theme.bg)
                    } else if results.isEmpty && !loading {
                        Text("Nothing found").foregroundStyle(Theme.muted).listRowBackground(Theme.bg)
                    }
                    ForEach(results) { v in
                        row(v)
                            .listRowBackground(Theme.bg)
                    }
                    if source == .youtube && more != nil && !results.isEmpty {
                        // Loads the next page when it comes into view (a new row each time, so it fires again).
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .id("more-\(results.count)")
                            .onAppear { Task { await loadMore() } }
                            .listRowBackground(Theme.bg)
                    }
                } header: {
                    Text(source == .music ? "Versions on YouTube Music" : "Videos on YouTube")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle("Replace song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task(id: "\(source.rawValue)|\(query)") { await search() }
        }
        .tint(accent)
    }

    private func row(_ v: Track) -> some View {
        let isCurrent = v.id == request.track.id
        let previewing = player.current?.id == v.id && player.isPlaying
        return HStack(spacing: 12) {
            Button {
                if previewing {
                    player.pause()
                } else {
                    player.play([picked(v)], from: "Replace song")
                }
            } label: {
                ZStack {
                    if source == .youtube {
                        AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(v.id)/mqdefault.jpg")) { phase in
                            if let img = phase.image { img.resizable().scaledToFill() } else { Theme.surface2 }
                        }
                        .frame(width: 88, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    } else {
                        ArtworkView(url: v.artwork(size: 120), size: 50, seed: v.id)
                    }
                    Image(systemName: previewing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(previewing ? "Pause preview" : "Listen to \(v.title)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(v.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    if v.explicit == true { ExplicitMark() }
                }
                Text([v.artist, v.album ?? "", v.durationText].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            if isCurrent {
                Text("Current").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
            } else {
                Button("Use") { use(v) }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 32)
                    .background(accent, in: Capsule())
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    /// The song as it would be saved: a YouTube Music version as it is; a YouTube video keeps the
    /// song's own name and artist (upload titles are messy) and takes the video's audio, length and picture.
    private func picked(_ v: Track) -> Track {
        var t: Track
        if source == .music {
            t = v
        } else {
            t = request.track
            t.id = v.id
            t.duration = v.duration
            t.artworkURL = URL(string: "https://i.ytimg.com/vi/\(v.id)/hqdefault.jpg")
            t.upload = true
            t.album = nil
            t.explicit = nil
        }
        t.podcast = nil
        t.chosen = true
        return t
    }

    private func use(_ v: Track) {
        Library.shared.replace(request.track, with: picked(v), in: request.place)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { results = []; more = nil; return }
        do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
        loading = true
        defer { loading = false }
        do {
            if source == .music {
                let found = try await YTMusic.versions(q)
                guard !Task.isCancelled else { return }
                results = found
                more = nil
            } else {
                let page = try await YouTubeSearch.videos(q)
                guard !Task.isCancelled else { return }
                results = page.videos
                more = page.more
            }
            failed = false
        } catch is CancellationError {
        } catch {
            failed = true
        }
    }

    /// The next page of YouTube videos.
    private func loadMore() async {
        guard source == .youtube, let token = more, !loadingMore else { return }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await YouTubeSearch.videos(q, more: token),
              q == query.trimmingCharacters(in: .whitespacesAndNewlines), source == .youtube else { return }
        let seen = Set(results.map(\.id))
        let fresh = page.videos.filter { !seen.contains($0.id) }
        results += fresh
        more = fresh.isEmpty ? nil : page.more
    }
}
