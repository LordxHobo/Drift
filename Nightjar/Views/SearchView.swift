import SwiftUI

struct SearchView: View {
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var loading = false
    @State private var error: String?
    @FocusState private var focused: Bool
    private var player: Player { .shared }
    private var settings: AppSettings { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Search")
                .font(.system(size: 26, weight: .heavy))
                .tracking(-0.5)
                .padding(.horizontal, 20)
                .padding(.top, 8)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color(hex: 0x3F3F46))
                TextField("", text: $query, prompt: Text("What do you want to listen to?").foregroundStyle(Color(hex: 0x52525B)))
                    .foregroundStyle(Color(hex: 0x18181B))
                    .font(.system(size: 15, weight: .semibold))
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !query.isEmpty {
                    Button {
                        query = ""
                        results = []
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color(hex: 0x52525B))
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(Color(hex: 0xF4F4F5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 20)

            Group {
                if loading && results.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if let error, results.isEmpty {
                    message(error)
                } else if results.isEmpty && query.trimmingCharacters(in: .whitespaces).count >= 2 && !loading {
                    message("No songs found for “\(query)”")
                } else if results.isEmpty {
                    message(settings.preferOfficialAudio
                            ? "Search songs, artists and albums from YouTube Music."
                            : "Search songs and music videos from YouTube.")
                } else {
                    List {
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
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: query + (settings.preferOfficialAudio ? "#songs" : "#all")) {
            await search()
        }
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
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else {
            results = []
            error = nil
            return
        }
        do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
        loading = true
        defer { loading = false }
        do {
            let found = try await YTMusic.search(q, songsOnly: settings.preferOfficialAudio)
            guard !Task.isCancelled else { return }
            results = found
            self.error = nil
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            self.error = "Search failed. Check your connection and try again."
        }
    }
}
