import SwiftUI

/// "Invite to listen together" from a song's menu: pick friends (only those who follow you back and
/// accept invites), and Drift plays the song in a Listen Together session and invites them to it.
struct InviteSheet: View {
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []
    @State private var busy = false
    @State private var error: String?
    private var social: SocialStore { .shared }
    private var invites: JamInvites { .shared }
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        ArtworkView(url: track.artwork(size: 120), size: 48, corner: 6, seed: track.id)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Text(track.artist).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                    .listRowBackground(Theme.bg)
                } footer: {
                    Text("Drift plays this song for you all at the same time, each on your own device.")
                }

                Section {
                    let friends = invites.invitable
                    if friends.isEmpty {
                        Text(social.following.isEmpty
                             ? "Follow your friends first, then invite them here."
                             : "None of the people you follow can be invited yet. They need to follow you back and have invites turned on.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                            .listRowBackground(Theme.bg)
                    }
                    ForEach(friends) { f in
                        Button {
                            if picked.contains(f.id) { picked.remove(f.id) } else { picked.insert(f.id) }
                        } label: {
                            HStack(spacing: 12) {
                                UserAvatar(data: f.avatar, name: f.name, size: 38)
                                Text(f.name).font(.system(size: 15, weight: .semibold))
                                Spacer()
                                Image(systemName: picked.contains(f.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 22))
                                    .foregroundStyle(picked.contains(f.id) ? accent : Theme.muted)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.bg)
                    }
                } header: {
                    Text("Friends")
                } footer: {
                    Text("Only friends who follow you back and allow invites are shown.")
                }

                if let error {
                    Text(error).foregroundStyle(Color(hex: 0xFF6B5B)).listRowBackground(Theme.bg)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Invite to listen together")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Invite") { send() }
                            .fontWeight(.bold)
                            .disabled(picked.isEmpty)
                    }
                }
            }
            .task { await social.refreshFollowing() }
        }
        .tint(accent)
    }

    private func send() {
        let chosen = invites.invitable.filter { picked.contains($0.id) }
        busy = true
        error = nil
        Task {
            do {
                try await invites.invite(chosen, to: track)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

/// Sheets any song menu can open (Add to playlist, Replace with another version, Invite to listen
/// together). Attached to the main screen and to the full-screen player: whichever is on top shows them,
/// so they open right away over the player too. Incoming invites show in their own layer (InviteOverlay).
struct SongSheetsModifier: ViewModifier {
    /// Attached to the full-screen player (the main screen leaves them to it while it's open).
    let inPlayer: Bool
    @State private var ui = UIState.shared

    private func binding<T>(_ value: ReferenceWritableKeyPath<UIState, T?>) -> Binding<T?> {
        Binding(get: { ui.showPlayer == inPlayer ? ui[keyPath: value] : nil },
                set: { if ui.showPlayer == inPlayer { ui[keyPath: value] = $0 } })
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: binding(\.addToPlaylist)) { track in
                AddToPlaylistSheet(track: track)
            }
            .sheet(item: binding(\.replacing)) { r in
                ReplaceSongSheet(request: r)
            }
            .sheet(item: binding(\.inviteTrack)) { track in
                InviteSheet(track: track)
            }
    }
}

extension View {
    func songSheets(inPlayer: Bool = false) -> some View { modifier(SongSheetsModifier(inPlayer: inPlayer)) }
}
