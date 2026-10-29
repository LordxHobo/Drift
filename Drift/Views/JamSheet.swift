import SwiftUI

/// Listen Together: start a session, join one (a friend's, or with a code), see who's in it, leave.
struct JamSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var copied = false
    private var jam: JamSession { .shared }
    private var social: SocialStore { .shared }
    private var accent: Color { AppSettings.shared.accent }
    private var me: String? { social.me?.id }

    private var friendsInSessions: [UserProfile] {
        social.following.filter { $0.jam != nil && $0.jam != jam.state?.code }
    }

    var body: some View {
        NavigationStack {
            List {
                if social.me == nil {
                    Text("Set up your Drift profile first (tap your picture on Home), so friends can find you.")
                        .foregroundStyle(Theme.muted)
                        .listRowBackground(Theme.bg)
                } else if let s = jam.state {
                    Section {
                        Text("Everyone hears the same songs at the same time, each on their own device. Anyone can pick songs, play, pause, skip and change what's next.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.text2)
                            .listRowBackground(Theme.bg)
                    }
                    Section {
                        HStack {
                            Text(s.code)
                                .font(.system(size: 30, weight: .heavy, design: .monospaced))
                                .tracking(4)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = s.code
                                copied = true
                            } label: {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 18))
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Copy code")
                        }
                        .listRowBackground(Theme.surface)
                    } footer: {
                        Text("Friends can join from their Friends list, or with this code.")
                    }
                    Section("Listening") {
                        ForEach(s.members, id: \.self) { m in
                            HStack(spacing: 12) {
                                UserAvatar(data: m == me ? social.me?.avatar : social.following.first(where: { $0.id == m })?.avatar,
                                           name: s.names[m] ?? "?", size: 34)
                                Text(m == me ? "You" : s.names[m] ?? "Someone").font(.system(size: 15, weight: .semibold))
                                Spacer()
                                if m == s.host {
                                    Text("HOST").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.muted)
                                }
                            }
                            .listRowBackground(Theme.bg)
                        }
                    }
                    Section {
                        Button(role: .destructive) {
                            run { await jam.leave() }
                        } label: {
                            Text(jam.isHost ? "End for everyone" : "Leave").frame(maxWidth: .infinity)
                        }
                        .disabled(busy)
                        .listRowBackground(Theme.surface)
                    }
                } else {
                    Section {
                        Text("Listen to the same songs at the same time as your friends, each on your own phone or computer. Anyone in it can pick songs, play, pause and skip.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.text2)
                            .listRowBackground(Theme.bg)
                        if jam.endedNotice {
                            Text("The last session ended.")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.muted)
                                .listRowBackground(Theme.bg)
                        }
                    }
                    Section {
                        Button {
                            run { try await jam.start() }
                        } label: {
                            Label("Start a session", systemImage: "person.2.fill")
                                .font(.system(size: 16, weight: .bold))
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(busy)
                        .listRowBackground(Theme.surface)
                    }
                    Section("Join with a code") {
                        HStack {
                            TextField("e.g. K7QM4X", text: $code)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                                .onSubmit(joinCode)
                            Button("Join", action: joinCode)
                                .buttonStyle(.borderless)
                                .fontWeight(.bold)
                                .disabled(busy || code.filter { $0.isLetter || $0.isNumber }.count < 6)
                        }
                        .listRowBackground(Theme.surface)
                    }
                    Section("Friends listening together") {
                        if friendsInSessions.isEmpty {
                            Text("None of your friends are in a session right now.")
                                .foregroundStyle(Theme.muted)
                                .listRowBackground(Theme.bg)
                        }
                        ForEach(friendsInSessions) { f in
                            HStack(spacing: 12) {
                                UserAvatar(data: f.avatar, name: f.username, size: 34)
                                Text(f.username).font(.system(size: 15, weight: .semibold))
                                Spacer()
                                Button("Join") {
                                    if let c = f.jam { run { try await jam.join(c) } }
                                }
                                .buttonStyle(.borderless)
                                .fontWeight(.bold)
                                .disabled(busy)
                            }
                            .listRowBackground(Theme.bg)
                        }
                    }
                }
                if busy {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Theme.bg)
                }
                if let error {
                    Text(error).foregroundStyle(Color(hex: 0xFF6B5B)).listRowBackground(Theme.bg)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Listen Together")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.bold) }
            }
            .onAppear {
                Task { await social.refreshFollowing() }
            }
        }
        .tint(accent)
    }

    private func joinCode() {
        let c = code
        guard c.filter({ $0.isLetter || $0.isNumber }).count >= 6 else { return }
        run { try await jam.join(c) }
    }

    private func run(_ task: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do {
                try await task()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

/// "Join" next to a friend who's listening together (Friends list).
struct JamJoinButton: View {
    let code: String
    let name: String
    @State private var busy = false
    @State private var error: String?
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        Button {
            busy = true
            Task {
                do {
                    try await JamSession.shared.join(code)
                } catch {
                    self.error = error.localizedDescription
                }
                busy = false
            }
        } label: {
            Group {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Join", systemImage: "person.2.fill")
                        .font(.system(size: 13, weight: .bold))
                }
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(accent, in: Capsule())
        }
        .buttonStyle(.borderless)
        .disabled(busy)
        .accessibilityLabel("Listen together with \(name)")
        .alert("Couldn't join", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }
}
