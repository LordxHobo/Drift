import SwiftUI
import UIKit

struct ImportSpotifyView: View {
    /// Called with the new playlist so the library can open it.
    var onOpen: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var importer = SpotifyImporter()
    @State private var copied = false
    @FocusState private var focused: Bool
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch importer.phase {
                    case .idle, .failed:
                        input
                    case .reading:
                        progress(title: "Reading playlist…", detail: nil, value: nil)
                    case .matching:
                        progress(title: importer.listName,
                                 detail: "Finding songs · \(importer.processed) of \(importer.total)"
                                    + (importer.estimate.map { " · \($0)" } ?? ""),
                                 value: importer.total > 0 ? Double(importer.processed) / Double(importer.total) : nil)
                    case .done:
                        done
                    }
                }
                .padding(20)
            }
            .background(Theme.bg)
            .foregroundStyle(Theme.text)
            .navigationTitle("Import from Spotify")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(importer.phase == .done ? "Done" : "Close") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(importer.phase == .matching || importer.phase == .reading)
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Paste a link to a **public** Spotify playlist or album. You can make the playlist private again once the import is done.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .lineSpacing(2)

            HStack(spacing: 8) {
                TextField("", text: $link, prompt: Text("https://open.spotify.com/playlist/…").foregroundStyle(Color(hex: 0x71717A)))
                    .font(.system(size: 15))
                    .focused($focused)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .onSubmit(startImport)
                Button("Paste") {
                    if let s = UIPasteboard.general.string { link = s }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if case .failed(let message) = importer.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: 0xFF6B5B))
            }

            Button(action: startImport) {
                Text("Import")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(link.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 6) {
                Text("How to get the link")
                    .font(.system(size: 13, weight: .bold))
                Text("In Spotify, open the playlist, tap ⋯ → Share → Copy link. To make it public: ⋯ → Make public (switch it back to private afterwards).")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(2)
            }
            .padding(.top, 8)
        }
        .onAppear {
            if link.isEmpty, let s = UIPasteboard.general.string, s.contains("spotify") { link = s }
        }
    }

    private func progress(title: String, detail: String?, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 22, weight: .heavy))
            if let value {
                ProgressView(value: value).tint(accent)
            } else {
                ProgressView().tint(accent)
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.muted)
            }
            Text(importer.total > 150
                 ? "Each song is looked up on YouTube Music, which takes a few minutes for a playlist this size. Keep Drift open; the screen stays on, and songs are saved as they're found."
                 : "Each song is looked up on YouTube Music. Keep Drift open until it's done.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
        }
        .padding(.top, 20)
    }

    private var done: some View {
        let found = importer.total - importer.unmatched.count
        return VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(accent)
            Text("Imported “\(importer.listName)”")
                .font(.system(size: 22, weight: .heavy))
            Text("\(found) of \(importer.total) songs found. You can switch the Spotify playlist back to private now.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)

            if importer.hitLimit {
                Text("Only the first \(SpotifyReader.embedLimit) songs could be read this time. Try the import again in a moment to get the rest.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            } else if let all = importer.spotifyTotal, all > importer.total {
                Text("Spotify gave \(importer.total) of the playlist’s \(all) songs. Importing again may get the rest.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
            if importer.hitLimit || importer.spotifyTotal != nil {
                Button("Copy reading log") {
                    let url = URL.documentsDirectory.appending(path: "spotify-import.log")
                    UIPasteboard.general.string = (try? String(contentsOf: url, encoding: .utf8)) ?? "No log"
                }
                .font(.system(size: 13, weight: .semibold))
            }

            if let id = importer.playlistID {
                Button {
                    dismiss()
                    onOpen(id)
                } label: {
                    Text("Open playlist")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if !importer.unmatched.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Not found (\(importer.unmatched.count))")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.muted)
                        Spacer()
                        Button {
                            NotificationStore.copy(importer.unmatched.map { MissingSong(title: $0.title, artist: $0.artist) })
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy list", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(accent)
                                .frame(minHeight: 44)
                        }
                    }
                    ForEach(Array(importer.unmatched.enumerated()), id: \.offset) { _, t in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).font(.system(size: 14, weight: .semibold))
                            Text(t.artist).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                    }
                    Text("Copies “Artist - Title”, one per line, for your Notes app. This list is also saved in Notifications (the bell on Home). Search for these yourself and add them with ⋯ → Add to playlist.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.top, 8)
            }
        }
    }

    private func startImport() {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        focused = false
        importer.start(link: trimmed)
    }
}
