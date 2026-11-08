import SwiftUI

/// "Send to a friend" from a song's menu: pick friends (only those who follow you back and accept songs),
/// add a note if you like, and the song lands in their inbox (Friends → Inbox) on every device.
struct SendSongSheet: View {
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []
    @State private var note = ""
    @State private var busy = false
    @State private var error: String?
    private var social: SocialStore { .shared }
    private var inbox: SongInbox { .shared }
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
                }

                Section {
                    let friends = inbox.sendable
                    if social.me == nil {
                        Text("Set up your profile in Friends first, so friends can find you.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                            .listRowBackground(Theme.bg)
                    } else if friends.isEmpty {
                        Text(social.following.isEmpty
                             ? "Follow your friends first, then send them songs here."
                             : "None of the people you follow can get songs from you yet. They need to follow you back.")
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
                    Text("Only friends who follow you back and accept songs are shown.")
                }

                Section {
                    TextField("Add a note (optional)", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                        .onChange(of: note) { _, v in
                            if v.count > SongInbox.maxNote { note = String(v.prefix(SongInbox.maxNote)) }
                        }
                        .listRowBackground(Theme.bg)
                } footer: {
                    if note.count > SongInbox.maxNote - 40 {
                        Text("\(SongInbox.maxNote - note.count) characters left")
                    }
                }

                if let error {
                    Text(error).foregroundStyle(Color(hex: 0xFF6B5B)).listRowBackground(Theme.bg)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Send to a friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Send") { send() }
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
        let chosen = inbox.sendable.filter { picked.contains($0.id) }
        busy = true
        error = nil
        Task {
            do {
                try await inbox.send(track, to: chosen, note: note)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
