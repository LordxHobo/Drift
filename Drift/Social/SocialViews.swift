import PhotosUI
import SwiftUI

// MARK: Building blocks

struct UserAvatar: View {
    let data: Data?
    let name: String
    var size: CGFloat

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Theme.tile(seed: name)
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.42, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

struct UserFollowButton: View {
    let user: UserProfile
    private var social: SocialStore { .shared }

    var body: some View {
        let following = social.isFollowing(user.id)
        Button {
            Task {
                if following { await social.unfollow(user.id) } else { await social.follow(user) }
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Text(following ? "Following" : "Follow")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(following ? Theme.text : Theme.onAccent)
                .padding(.horizontal, 14)
                .frame(minHeight: 32)
                .background(following ? Color.clear : AppSettings.shared.accent, in: Capsule())
                .overlay(Capsule().stroke(following ? Theme.muted : .clear, lineWidth: 1))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(following ? "Unfollow \(user.username)" : "Follow \(user.username)")
    }
}

/// A person with what they're playing (or last played).
struct FriendRow: View {
    let user: UserProfile
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                UserAvatar(data: user.avatar, name: user.username, size: 52)
                if user.isListeningNow {
                    Image(systemName: "waveform")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 20, height: 20)
                        .background(accent, in: Circle())
                        .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(user.username).font(.system(size: 15, weight: .bold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let when = user.activityText {
                        Text(when)
                            .font(.system(size: 11, weight: user.isListeningNow ? .bold : .regular))
                            .foregroundStyle(user.isListeningNow ? accent : Theme.muted)
                    }
                }
                if let t = user.nowPlaying {
                    Text("\(t.title) · \(t.artist)")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                } else {
                    Text(user.shareActivity ? "Nothing played yet" : "Listening activity is hidden")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            if let code = user.jam, JamSession.shared.state?.code != code {
                JamJoinButton(code: code, name: user.username)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

// MARK: First launch

struct OnboardingView: View {
    enum Check: Equatable {
        case idle, checking, available, taken, invalid(String), offline
    }

    @State private var name = ""
    @State private var photo: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var cropping: CropRequest?
    @State private var check: Check = .idle
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool
    private var social: SocialStore { .shared }
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 8) {
                    Text("Create your profile")
                        .font(.system(size: 28, weight: .heavy))
                        .tracking(-0.5)
                    Text("Friends can follow you and see what you're listening to. No email or password needed.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 48)

                PhotosPicker(selection: $pickerItem, matching: .images) {
                    ZStack(alignment: .bottomTrailing) {
                        if let photo {
                            Image(uiImage: photo).resizable().scaledToFill()
                                .frame(width: 120, height: 120).clipShape(Circle())
                        } else {
                            UserAvatar(data: nil, name: name.isEmpty ? "?" : name, size: 120)
                        }
                        Image(systemName: "camera.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.onAccent)
                            .frame(width: 34, height: 34)
                            .background(accent, in: Circle())
                            .overlay(Circle().stroke(Theme.bg, lineWidth: 3))
                    }
                }
                .accessibilityLabel(photo == nil ? "Add a profile photo" : "Change profile photo")

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        Text("@").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.muted)
                        TextField("", text: $name, prompt: Text("username").foregroundStyle(Color(hex: 0x71717A)))
                            .font(.system(size: 17, weight: .semibold))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused)
                            .submitLabel(.done)
                            .onSubmit(save)
                        statusIcon
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text(statusText)
                        .font(.system(size: 12))
                        .foregroundStyle(statusColor)
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: 0xFF6B5B))
                }

                Button(action: save) {
                    Group {
                        if saving { ProgressView().tint(Theme.onAccent) } else { Text("Continue") }
                    }
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(check != .available || saving)
                .opacity(check == .available ? 1 : 0.5)

                Button("Not now") { social.skipOnboarding() }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .onChange(of: name) { _, new in
            let c = SocialStore.cleaned(new)
            if c != new { name = c }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    cropping = CropRequest(image: img)
                }
                pickerItem = nil
            }
        }
        .fullScreenCover(item: $cropping) { r in
            ImageCropper(image: r.image, circle: true,
                         onDone: { photo = $0; cropping = nil },
                         onCancel: { cropping = nil })
        }
        .task(id: name) { await runCheck() }
    }

    private var statusText: String {
        switch check {
        case .idle: SocialStore.usernameRule
        case .checking: "Checking…"
        case .available: "@\(name) is available"
        case .taken: "@\(name) is taken"
        case .invalid(let why): why
        case .offline: "Couldn't check right now. Check your connection."
        }
    }

    private var statusColor: Color {
        switch check {
        case .available: accent
        case .taken, .invalid: Color(hex: 0xFF6B5B)
        default: Theme.muted
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch check {
        case .checking: ProgressView().controlSize(.small)
        case .available: Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
        case .taken, .invalid: Image(systemName: "xmark.circle.fill").foregroundStyle(Color(hex: 0xFF6B5B))
        default: EmptyView()
        }
    }

    private func runCheck() async {
        error = nil
        guard !name.isEmpty else { check = .idle; return }
        if let why = SocialStore.validate(name) { check = .invalid(why); return }
        check = .checking
        do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
        switch await social.isAvailable(name) {
        case true?: check = .available
        case false?: check = .taken
        case nil: check = .offline
        }
    }

    private func save() {
        guard check == .available, !saving else { return }
        saving = true
        focused = false
        Task {
            do {
                try await social.createProfile(username: name, photo: photo)
            } catch SocialError.usernameTaken {
                check = .taken
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}

// MARK: Your profile

struct ProfileView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var cropping: CropRequest?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var error: String?
    @State private var busy = false
    private var social: SocialStore { .shared }
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        ScrollView {
            if let me = social.me {
                VStack(spacing: 22) {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        ZStack(alignment: .bottomTrailing) {
                            UserAvatar(data: me.avatar, name: me.username, size: 120)
                            Image(systemName: "camera.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.onAccent)
                                .frame(width: 32, height: 32)
                                .background(accent, in: Circle())
                                .overlay(Circle().stroke(Theme.bg, lineWidth: 3))
                        }
                    }
                    .accessibilityLabel("Change profile photo")
                    .padding(.top, 12)

                    Text("@\(me.username)").font(.system(size: 24, weight: .heavy))

                    HStack(spacing: 28) {
                        NavigationLink(value: Route.followList(followers: true)) {
                            countLabel(social.followers.count, "Followers")
                        }
                        NavigationLink(value: Route.followList(followers: false)) {
                            countLabel(me.following.count, "Following")
                        }
                    }
                    .buttonStyle(.plain)

                    if let error {
                        Text(error).font(.system(size: 13)).foregroundStyle(Color(hex: 0xFF6B5B))
                    }

                    VStack(spacing: 4) {
                        Toggle(isOn: Binding(get: { me.shareActivity },
                                             set: { on in Task { await social.setShareActivity(on) } })) {
                            label("Share my listening activity", "People who follow you see what you're playing.")
                        }
                        Toggle(isOn: Binding(get: { social.privateSession }, set: { social.privateSession = $0 })) {
                            label("Private session", "Hide what you play until Drift restarts.")
                        }
                        Toggle(isOn: Binding(get: { me.acceptsInvites },
                                             set: { on in Task { await social.setAllowInvites(on) } })) {
                            label("Listen Together invites", "Friends who follow you back can invite you to listen together.")
                        }
                    }
                    .tint(accent)

                    VStack(spacing: 0) {
                        Button {
                            newName = me.username
                            renaming = true
                        } label: {
                            row("Change username", "at")
                        }
                        Button {
                            Task { try? await social.setPhoto(nil) }
                        } label: {
                            row("Remove photo", "person.crop.circle.badge.minus")
                        }
                        .disabled(me.avatar == nil)
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            row("Delete profile", "trash", destructive: true)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            } else {
                VStack(spacing: 14) {
                    Text("No profile yet").font(.system(size: 20, weight: .heavy))
                    Text("Create one to follow friends and see what they're listening to.")
                        .font(.system(size: 14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    Button("Create profile") { social.showOnboarding = true }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 22)
                        .frame(minHeight: 46)
                        .background(accent, in: Capsule())
                }
                .frame(maxWidth: .infinity)
                .padding(32)
                .padding(.top, 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .task { await social.loadFollowers() }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    cropping = CropRequest(image: img)
                }
                pickerItem = nil
            }
        }
        .fullScreenCover(item: $cropping) { r in
            ImageCropper(image: r.image, circle: true, onDone: { img in
                cropping = nil
                Task {
                    do { try await social.setPhoto(img) } catch { self.error = error.localizedDescription }
                }
            }, onCancel: { cropping = nil })
        }
        .alert("Change username", isPresented: $renaming) {
            TextField("username", text: $newName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Save") { rename() }
        } message: {
            Text(SocialStore.usernameRule)
        }
        .confirmationDialog("Delete your profile?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete profile", role: .destructive) {
                Task {
                    do { try await social.deleteProfile() } catch { self.error = error.localizedDescription }
                }
            }
        } message: {
            Text("Your username, photo and followers are removed. Your music library stays on this iPhone.")
        }
    }

    private func rename() {
        let name = SocialStore.cleaned(newName)
        if let why = SocialStore.validate(name) { error = why; return }
        Task {
            if await social.isAvailable(name) == false { error = "@\(name) is taken"; return }
            do { try await social.changeUsername(name); error = nil } catch { self.error = error.localizedDescription }
        }
    }

    private func countLabel(_ n: Int, _ title: String) -> some View {
        VStack(spacing: 2) {
            Text("\(n)").font(.system(size: 18, weight: .heavy))
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .frame(minWidth: 80, minHeight: 44)
    }

    private func label(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 6)
    }

    private func row(_ title: String, _ icon: String, destructive: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 24)
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .foregroundStyle(destructive ? Color(hex: 0xFF6B5B) : Theme.text)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }
}

// MARK: Friends

struct FriendsView: View {
    @State private var query = ""
    @State private var results: [UserProfile] = []
    @State private var searching = false
    private var social: SocialStore { .shared }
    private var player: Player { .shared }

    var body: some View {
        List {
            if social.me == nil {
                VStack(spacing: 12) {
                    Text("Create a profile to follow friends.")
                        .font(.system(size: 15, weight: .semibold))
                    Button("Create profile") { social.showOnboarding = true }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 42)
                        .background(AppSettings.shared.accent, in: Capsule())
                        .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .listRowBackground(Theme.bg)
            } else if !query.isEmpty {
                Section {
                    if searching && results.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).listRowBackground(Theme.bg)
                    } else if results.isEmpty {
                        Text("No one called “\(query)”")
                            .foregroundStyle(Theme.muted)
                            .listRowBackground(Theme.bg)
                    }
                    ForEach(results) { u in
                        HStack {
                            NavigationLink(value: Route.user(u)) {
                                HStack(spacing: 12) {
                                    UserAvatar(data: u.avatar, name: u.username, size: 44)
                                    Text(u.username).font(.system(size: 15, weight: .semibold))
                                }
                            }
                            UserFollowButton(user: u)
                        }
                        .listRowBackground(Theme.bg)
                    }
                }
            } else {
                if social.following.isEmpty {
                    Text(social.loadingFriends ? "Loading…" : "Search for friends by username to follow them.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .listRowBackground(Theme.bg)
                }
                ForEach(social.following) { u in
                    NavigationLink(value: Route.user(u)) {
                        FriendRow(user: u)
                    }
                    .listRowBackground(Theme.bg)
                    .contextMenu {
                        if let t = u.nowPlaying {
                            Button { player.play([t], from: "\(u.username)'s activity") } label: {
                                Label("Play \(t.title)", systemImage: "play.fill")
                            }
                        }
                        Button(role: .destructive) { Task { await social.unfollow(u.id) } } label: {
                            Label("Unfollow", systemImage: "person.badge.minus")
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { Task { await social.unfollow(u.id) } } label: {
                            Label("Unfollow", systemImage: "person.badge.minus")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find people by username")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .navigationTitle("Friends")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .refreshable { await social.refreshFollowing() }
        .task(id: query) {
            guard !query.isEmpty else { results = []; return }
            searching = true
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            results = await social.search(query)
            searching = false
        }
        .task {
            // Keep the list fresh while it's open.
            while !Task.isCancelled {
                await social.refreshFollowing()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }
}

// MARK: Someone's profile (or your own, as others see it)

struct UserView: View {
    let initial: UserProfile
    @State private var user: UserProfile?
    @State private var followerCount: Int?
    @State private var shared: [SharedPlaylist] = []
    @State private var playlistsLoaded = false
    @State private var playlistsFailed = false
    private var social: SocialStore { .shared }
    private var player: Player { .shared }
    private var library: Library { .shared }
    private var accent: Color { AppSettings.shared.accent }

    private var isMe: Bool { initial.id == social.me?.id }

    var body: some View {
        let u = isMe ? (social.me ?? initial) : (user ?? initial)
        ScrollView {
            VStack(spacing: 16) {
                UserAvatar(data: u.avatar, name: u.username, size: 120).padding(.top, 12)
                Text("@\(u.username)").font(.system(size: 24, weight: .heavy))
                HStack(spacing: 28) {
                    count(followerCount, "Followers")
                    count(u.following.count, "Following")
                }
                if isMe {
                    NavigationLink(value: Route.profile) {
                        Text("Edit profile")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 32)
                            .overlay(Capsule().stroke(Theme.muted, lineWidth: 1))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    UserFollowButton(user: u)
                }

                if let t = u.nowPlaying {
                    Button {
                        player.play([t], from: "\(u.username)'s activity")
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkView(url: t.artworkURL ?? t.artwork(size: 200), size: 56, corner: 6, seed: t.id)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(u.isListeningNow ? "LISTENING NOW" : "LAST PLAYED")
                                    .font(.system(size: 10, weight: .heavy))
                                    .tracking(0.8)
                                    .foregroundStyle(u.isListeningNow ? accent : Theme.muted)
                                Text(t.title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                                Text(t.artist).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "play.circle.fill").font(.system(size: 32))
                                .foregroundStyle(accent)
                        }
                        .padding(12)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play \(t.title) by \(t.artist)")
                } else if !u.shareActivity {
                    Text("@\(u.username) keeps their listening activity private.")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                }

                playlistsSection(u)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        if !isMe {
            user = await social.user(initial.id) ?? user ?? initial
            do {
                shared = try await SharedPlaylist.list(of: user ?? initial)
                playlistsFailed = false
            } catch {
                playlistsFailed = true
            }
            playlistsLoaded = true
        }
        followerCount = await SocialStore.followers(of: initial.id).count
    }

    @ViewBuilder private func playlistsSection(_ u: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Playlists")
                .font(.system(size: 20, weight: .heavy))
                .tracking(-0.3)
                .padding(.bottom, 6)
            if isMe {
                let mine = library.playlists.filter(\.isShared)
                if mine.isEmpty {
                    note("None of your playlists are on your profile. Turn on “Show on my profile” when editing a playlist.")
                }
                ForEach(mine) { p in
                    NavigationLink(value: Route.playlist(p.id)) {
                        playlistRow(name: p.name, subtitle: songsText(p.tracks.count)) {
                            PlaylistArt(playlist: p, size: 56)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else if !playlistsLoaded {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
            } else if playlistsFailed && shared.isEmpty {
                note("Couldn't load playlists.")
            } else if shared.isEmpty {
                note("@\(u.username) has no public playlists.")
            } else {
                ForEach(shared) { p in
                    NavigationLink(value: Route.sharedPlaylist(p)) {
                        playlistRow(name: p.name, subtitle: p.subtitle) {
                            SharedPlaylistCover(playlist: p, size: 56, corner: 4)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private func playlistRow<Art: View>(name: String, subtitle: String, @ViewBuilder art: () -> Art) -> some View {
        HStack(spacing: 12) {
            art()
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func songsText(_ n: Int) -> String { "\(n) \(n == 1 ? "song" : "songs")" }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.muted)
            .padding(.vertical, 6)
    }

    private func count(_ n: Int?, _ title: String) -> some View {
        VStack(spacing: 2) {
            Text(n.map(String.init) ?? "–").font(.system(size: 18, weight: .heavy))
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .frame(minWidth: 80)
    }
}

struct SharedPlaylistCover: View {
    let playlist: SharedPlaylist
    var size: CGFloat
    var corner: CGFloat = 4

    var body: some View {
        PlaylistCover(tracks: playlist.preview, size: size, color: Theme.tile(playlist.colorIndex),
                      symbol: playlist.symbol, corner: corner, forceTile: playlist.style == .color,
                      photo: playlist.style == .photo ? playlist.cover.flatMap(UIImage.init(data:)) : nil)
    }
}

/// A friend's public playlist.
struct SharedPlaylistView: View {
    let playlist: SharedPlaylist
    @State private var tracks: [Track]?
    @State private var failed = false
    @State private var saved = false
    private var player: Player { .shared }
    private var library: Library { .shared }
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        let list = tracks ?? []
        let source = "\(playlist.name) · @\(playlist.ownerName)"
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SharedPlaylistCover(playlist: playlist, size: 230, corner: 6)
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 12)
                    .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.name)
                        .font(.system(size: 24, weight: .heavy))
                        .tracking(-0.4)
                    Text("@\(playlist.ownerName)")
                        .font(.system(size: 14, weight: .bold))
                    Text(playlist.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                    DownloadStatusLine(tracks: list)
                }

                HStack(spacing: 4) {
                    Button {
                        if allDownloaded(list) {
                            list.forEach { library.removeDownload($0.id) }
                        } else {
                            DownloadManager.shared.download(list, name: playlist.name)
                        }
                    } label: {
                        Image(systemName: allDownloaded(list) ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .font(.system(size: 26))
                            .foregroundStyle(allDownloaded(list) ? accent : Theme.text2)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(allDownloaded(list) ? "Remove downloads" : "Download playlist")
                    Button {
                        library.createPlaylist(playlist.name, tracks: list)
                        saved = true
                    } label: {
                        Image(systemName: saved ? "checkmark.circle.fill" : "plus.circle")
                            .font(.system(size: 26))
                            .foregroundStyle(saved ? accent : Theme.text2)
                            .frame(width: 44, height: 44)
                    }
                    .disabled(saved || list.isEmpty)
                    .accessibilityLabel(saved ? "Saved to your library" : "Save a copy to your library")
                    Spacer()
                    Button { player.shufflePlay(list, from: source) } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Shuffle playlist")
                    Button { player.play(list, from: source) } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.onAccent)
                            .frame(width: 56, height: 56)
                            .background(accent, in: Circle())
                    }
                    .accessibilityLabel("Play playlist")
                }
                .buttonStyle(.plain)
                .disabled(list.isEmpty)

                if tracks == nil {
                    if failed {
                        Text("Couldn't load this playlist.").foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                } else if list.isEmpty {
                    Text("This playlist is empty.").foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
                }

                LazyVStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, t in
                        TrackRow(track: t) { player.play(list, startAt: i, from: source) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .task {
            guard tracks == nil else { return }
            do {
                let loaded = try await playlist.tracks()
                tracks = loaded
                player.prefetch(Array(loaded.prefix(2)))
            } catch {
                failed = true
            }
        }
    }

    private func allDownloaded(_ list: [Track]) -> Bool {
        !list.isEmpty && list.allSatisfy { library.isDownloaded($0.id) }
    }
}

/// Your followers or the people you follow.
struct FollowListView: View {
    let followers: Bool
    @State private var users: [UserProfile] = []
    @State private var loaded = false
    private var social: SocialStore { .shared }

    var body: some View {
        List {
            if loaded && users.isEmpty {
                Text(followers ? "No followers yet" : "Not following anyone yet")
                    .foregroundStyle(Theme.muted)
                    .listRowBackground(Theme.bg)
            }
            ForEach(users) { u in
                HStack {
                    NavigationLink(value: Route.user(u)) {
                        HStack(spacing: 12) {
                            UserAvatar(data: u.avatar, name: u.username, size: 44)
                            Text(u.username).font(.system(size: 15, weight: .semibold))
                        }
                    }
                    UserFollowButton(user: u)
                }
                .listRowBackground(Theme.bg)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(followers ? "Followers" : "Following")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .task {
            if followers {
                await social.loadFollowers()
                users = social.followers
            } else if let me = social.me {
                users = await social.users(me.following)
            }
            loaded = true
        }
    }
}
