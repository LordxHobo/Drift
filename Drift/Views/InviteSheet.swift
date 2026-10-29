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
                                UserAvatar(data: f.avatar, name: f.username, size: 38)
                                Text(f.username).font(.system(size: 15, weight: .semibold))
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

/// The invite popups (join or not, and why joining didn't work) and the invite sheet. Attached to the
/// main screen and the full-screen player, so they show whichever is on top.
struct JamInviteModifier: ViewModifier {
    @State private var invites = JamInvites.shared
    @State private var ui = UIState.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: $ui.inviteTrack) { track in
                InviteSheet(track: track)
            }
            .alert("Listen together?",
                   isPresented: Binding(get: { invites.incoming != nil }, set: { if !$0 { invites.incoming = nil } }),
                   presenting: invites.incoming) { invite in
                Button("Join") { Task { await invites.accept(invite) } }
                Button("Decline", role: .cancel) { invites.decline(invite) }
            } message: { invite in
                Text(invite.title.isEmpty
                     ? "\(invite.fromName) invited you to listen together."
                     : "\(invite.fromName) invited you to listen to “\(invite.title)” by \(invite.artist) together.")
            }
            .alert("Couldn't join", isPresented: Binding(get: { invites.failure != nil }, set: { if !$0 { invites.failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(invites.failure ?? "")
            }
    }
}

extension View {
    func jamInvites() -> some View { modifier(JamInviteModifier()) }
}
