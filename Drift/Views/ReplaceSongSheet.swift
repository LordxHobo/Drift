import SwiftUI

/// Pick a different YouTube video for a song (e.g. when an import chose the wrong upload).
/// The song keeps its name and its place in the playlist.
struct ReplaceSongSheet: View {
    let request: ReplaceRequest
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var results: [Track] = []
    @State private var loading = false
    @State private var failed = false
    private var player: Player { .shared }
    private var accent: Color { AppSettings.shared.accent }

    init(request: ReplaceRequest) {
        self.request = request
        let artist = LyricsService.mainArtist(request.track.artist)
        _query = State(initialValue: "\(artist) \(request.track.title)".trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        ArtworkView(url: request.track.artwork(size: 120), size: 44, seed: request.track.id)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(request.track.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Text("\(request.track.artist) · \(request.track.durationText)")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                    .listRowBackground(Theme.surface)
                } header: {
                    Text("Now in your playlist")
                } footer: {
                    Text("Tap ▶ to listen to a version first, then Use to swap it in. The song keeps its name and its place.")
                }

                Section {
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
                } header: {
                    Text("Versions on YouTube")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search YouTube")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle("Replace song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task(id: query) { await search() }
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
                    var song = v
                    song.podcast = nil
                    song.upload = true
                    player.play([song], from: "Replace song")
                }
            } label: {
                ZStack {
                    AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(v.id)/mqdefault.jpg")) { phase in
                        if let img = phase.image { img.resizable().scaledToFill() } else { Theme.surface2 }
                    }
                    .frame(width: 88, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Image(systemName: previewing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(previewing ? "Pause preview" : "Listen to \(v.title)")

            VStack(alignment: .leading, spacing: 2) {
                Text(v.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                Text([v.artist, v.durationText].filter { !$0.isEmpty }.joined(separator: " · "))
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

    private func use(_ v: Track) {
        // Keep the song's own name and artist; take the video's audio, length and picture.
        var t = request.track
        t.id = v.id
        t.duration = v.duration
        t.artworkURL = URL(string: "https://i.ytimg.com/vi/\(v.id)/hqdefault.jpg")
        t.upload = true
        t.podcast = nil
        t.album = nil
        t.chosen = true
        Library.shared.replace(request.track, with: t, in: request.place)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { results = []; return }
        do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
        loading = true
        defer { loading = false }
        do {
            let found = try await YouTubeSearch.search(q).episodes
            guard !Task.isCancelled else { return }
            results = found
            failed = false
        } catch is CancellationError {
        } catch {
            failed = true
        }
    }
}
