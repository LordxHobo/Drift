import SwiftUI

/// Share one of your playlists with friends (they can add, remove and move songs too), change who's
/// in it, leave one, or stop sharing.
struct CollabSheet: View {
    let playlistID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []
    @State private var busy = false
    @State private var error: String?
    private var library: Library { .shared }
    private var social: SocialStore { .shared }
    private var accent: Color { AppSettings.shared.accent }

    private var playlist: Playlist? { library.playlist(playlistID) }
    private var me: String? { social.me?.id }
    private var isOwner: Bool { playlist?.collab == nil || playlist?.collab?.owner == me }

    /// People to pick from: who you follow, plus anyone already in it.
    private var people: [UserProfile] {
        var list = social.following
        for m in playlist?.collab?.members ?? [] where m != me && !list.contains(where: { $0.id == m }) {
            list.append(UserProfile(id: m, username: playlist?.collab?.names[m] ?? "Someone", avatar: nil))
        }
        return list
    }

    var body: some View {
        NavigationStack {
            List {
                if let p = playlist {
                    Section {
                        Text(p.collab != nil
                             ? "“\(p.name)” is shared with \(p.collab!.names(me: me)). Everyone in it can add, remove and move songs."
                             : "Invite friends to “\(p.name)”. They can add, remove and move songs too, and see each change.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.text2)
                            .listRowBackground(Theme.bg)
                    }
                    if social.me == nil {
                        Text("Set up your Drift profile first (tap your picture on Home), so friends can find you.")
                            .foregroundStyle(Theme.muted)
                            .listRowBackground(Theme.bg)
                    } else if isOwner {
                        Section(people.isEmpty ? "" : "Friends") {
                            if people.isEmpty {
                                Text("Follow your friends first, then invite them here.")
                                    .foregroundStyle(Theme.muted)
                                    .listRowBackground(Theme.bg)
                            }
                            ForEach(people) { f in
                                Button {
                                    if picked.contains(f.id) { picked.remove(f.id) } else { picked.insert(f.id) }
                                } label: {
                                    HStack(spacing: 12) {
                                        UserAvatar(data: f.avatar, name: f.name, size: 34)
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
                        }
                    } else if let c = p.collab {
                        Section("In this playlist") {
                            ForEach(c.members, id: \.self) { m in
                                HStack(spacing: 12) {
                                    UserAvatar(data: nil, name: c.names[m] ?? "?", size: 34)
                                    Text(m == me ? "You" : c.names[m] ?? "Someone").font(.system(size: 15, weight: .semibold))
                                    Spacer()
                                    if m == c.owner {
                                        Text("OWNER").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.muted)
                                    }
                                }
                                .listRowBackground(Theme.bg)
                            }
                        }
                    }
                    if p.collab != nil {
                        Section {
                            Button(role: .destructive) {
                                let owner = isOwner
                                run {
                                    if owner {
                                        try await CollabSync.shared.stop(p.id)
                                    } else {
                                        try await CollabSync.shared.leave(p.id)
                                    }
                                }
                            } label: {
                                Text(isOwner ? "Stop sharing" : "Leave playlist")
                                    .frame(maxWidth: .infinity)
                            }
                            .disabled(busy)
                            .listRowBackground(Theme.surface)
                        } footer: {
                            Text(isOwner ? "It becomes your own playlist again and goes from everyone else's library."
                                         : "It goes from your library. The others keep it.")
                        }
                    }
                    if let error {
                        Text(error).foregroundStyle(Color(hex: 0xFF6B5B)).listRowBackground(Theme.bg)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle(playlist?.collab != nil ? "Collaborators" : "Make collaborative")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(isOwner ? "Cancel" : "Done") { dismiss() } }
                if isOwner, social.me != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(playlist?.collab != nil ? "Save" : "Share") {
                            let chosen = people.filter { picked.contains($0.id) }
                            run { try await CollabSync.shared.share(playlistID, with: chosen) }
                        }
                        .fontWeight(.bold)
                        .disabled(busy || (playlist?.collab == nil && picked.isEmpty))
                    }
                }
            }
            .onAppear {
                picked = Set(playlist?.collab?.members.filter { $0 != me } ?? [])
                Task { await social.refreshFollowing() }
            }
        }
        .tint(accent)
    }

    private func run(_ task: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do {
                try await task()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
