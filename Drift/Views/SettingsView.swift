import SwiftUI

/// The pages Settings is split into (the main Settings page lists them).
enum SettingsCategory: String, Hashable, CaseIterable {
    case account, playback, podcasts, lyrics, storage, look

    var title: String {
        switch self {
        case .account: "Profile & devices"
        case .playback: "Playback"
        case .podcasts: "Podcasts"
        case .lyrics: "Lyrics"
        case .storage: "Storage"
        case .look: "Look"
        }
    }

    var symbol: String {
        switch self {
        case .account: "person.crop.circle"
        case .playback: "music.note"
        case .podcasts: "mic.fill"
        case .lyrics: "quote.bubble.fill"
        case .storage: "arrow.down.circle.fill"
        case .look: "paintbrush.fill"
        }
    }

    var color: Color {
        switch self {
        case .account: Color(hex: 0x8E8E93)
        case .playback: Color(hex: 0x1ED760)
        case .podcasts: Color(hex: 0x8B7CFF)
        case .lyrics: Color(hex: 0xF5A524)
        case .storage: Color(hex: 0x2DD4BF)
        case .look: Color(hex: 0xFF6B5B)
        }
    }
}

struct SettingsView: View {
    /// nil = the main Settings page with the list of categories.
    var category: SettingsCategory? = nil
    @State private var settings = AppSettings.shared
    @State private var confirmDelete = false
    @State private var linkComputer = false
    /// Songs and bytes in the song cache.
    @State private var cacheUsage: (songs: Int, bytes: Int64)?
    /// What's new, opened by tapping the version.
    @State private var patchNotes: [PatchNotes.Entry] = []
    private var library: Library { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                switch category {
                case nil: home
                case .account: account
                case .playback: playback
                case .podcasts: podcasts
                case .lyrics: lyrics
                case .storage: storage
                case .look: look
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Theme.bg)
        .navigationTitle(category?.title ?? "Settings")
        .navigationBarTitleDisplayMode(category == nil && Theme.isMusic ? .large : .inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .sheet(isPresented: $linkComputer) { LinkComputerSheet() }
        .confirmationDialog("Remove all downloaded songs?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove all", role: .destructive) { library.removeAllDownloads() }
        }
    }

    // MARK: Main page

    @ViewBuilder private var home: some View {
        NavigationLink(value: Route.settingsCategory(.account)) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(settings.accent)
                    if let me = SocialStore.shared.me {
                        Text(String(me.name.prefix(1)).uppercased())
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Theme.onAccent)
                    } else {
                        Image(systemName: "person.fill").foregroundStyle(Theme.onAccent)
                    }
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(SocialStore.shared.me?.name ?? "Create a profile")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(SocialStore.shared.me.map { "@\($0.username) · Profile, linked computer" } ?? "Sync your library and link a computer")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        group([.playback, .podcasts, .lyrics])
        group([.storage, .look])

        // Updates arrive through SideStore (Drift's source there).
        let updates = UpdateChecker.shared
        Button {
            if updates.available != nil { updates.openSideStore() }
            else { Task { await updates.check(manual: true) } }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.app.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(settings.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(updates.available.map { "Update to \($0.version)" } ?? "Check for updates")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(updates.checking ? "Checking…"
                         : updates.available != nil ? "Opens SideStore"
                         : updates.lastCheck != nil ? "Drift is up to date" : "Through SideStore")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if updates.checking { ProgressView() }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 58)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        // Tap for what's new.
        Button {
            patchNotes = PatchNotes.everything()
        } label: {
            VStack(spacing: 3) {
                Text("Drift \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                Text("What's new").underline()
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: Binding(get: { !patchNotes.isEmpty }, set: { if !$0 { patchNotes = [] } })) {
            PatchNotesSheet(entries: patchNotes)
        }
        .task { cacheUsage = await PlayCache.shared.usage() }
    }

    private func subtitle(_ c: SettingsCategory) -> String {
        switch c {
        case .account: return ""
        case .playback: return "Quality, equalizer, ad-free listening"
        case .podcasts: return "Sponsors, video"
        case .lyrics: return "CarPlay, Lock Screen"
        case .storage:
            let downloads = "Downloads \(library.downloaded.count) songs"
            guard let c = cacheUsage, c.bytes > 0 else { return downloads }
            return downloads + " · Song cache " + ByteCountFormatter.string(fromByteCount: c.bytes, countStyle: .file)
        case .look: return settings.uiStyle == .music ? "Style, appearance, app icon" : "Style, appearance, accent color"
        }
    }

    private func group(_ items: [SettingsCategory]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element) { i, c in
                NavigationLink(value: Route.settingsCategory(c)) {
                    HStack(spacing: 12) {
                        Image(systemName: c.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(c.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                            Text(subtitle(c)).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 58)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(subtitle(c))
                if i < items.count - 1 {
                    Rectangle().fill(Theme.line.opacity(0.5)).frame(height: 0.5).padding(.leading, 56)
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Pages

    @ViewBuilder private var playback: some View {
        section("Audio quality") {
            HStack(spacing: 4) {
                qualityButton("Best", selected: !settings.dataSaver) { settings.dataSaver = false }
                qualityButton("Data saver", selected: settings.dataSaver) { settings.dataSaver = true }
            }
            .padding(4)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(settings.dataSaver
                 ? "Lowest-bitrate stream (around 50–70 kbps). Good for long drives on mobile data. Downloads always use the best quality."
                 : "The highest-bitrate stream your iPhone can play natively: AAC, usually 128 kbps, higher when YouTube offers it. True lossless isn't available from YouTube.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .lineSpacing(2)
        }

        section("Equalizer") {
            NavigationLink(value: Route.equalizer) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Equalizer").font(.system(size: 15, weight: .semibold))
                        Text(settings.eqEnabled ? Equalizer.presetName(settings.eqGains) : "Off")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        section("Ad-free listening") {
            toggle("Skip non-music segments",
                   "Jumps past intros, outros and talking in music videos using community-marked timestamps (SponsorBlock).",
                   $settings.skipNonMusic)
            toggle("Skip silence at the end",
                   "Moves to the next song when a song ends in 15 seconds or more of dead air (hidden tracks, minutes of silence).",
                   $settings.skipSilence)
            toggle("Prefer official audio",
                   "Search returns album versions instead of music videos, and a music video plays as its album version when YouTube Music has one (no intros or cut endings).",
                   $settings.preferOfficialAudio)
            toggle("Prefer explicit versions",
                   "When a song has a clean (censored) and an explicit version, always play the explicit one, the way the artist made it.",
                   $settings.preferExplicit)
            Text("Audio is streamed directly, so YouTube ads never play.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
        }
    }

    @ViewBuilder private var podcasts: some View {
        section("Podcasts") {
            toggle("Skip sponsors",
                   "Skips sponsor reads, self-promotion and “like and subscribe” reminders that the SponsorBlock community has marked.",
                   $settings.skipSponsors)
            toggle("Show video",
                   "Episodes show their video in the player (the sound stays the same). Uses more data, only while the player is open.",
                   $settings.podcastVideo)
            if settings.podcastVideo {
                HStack {
                    Text("Video quality").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Picker("Video quality", selection: $settings.videoQuality) {
                        Text("360p").tag(360)
                        Text("480p").tag(480)
                        Text("720p").tag(720)
                        Text("1080p").tag(1080)
                        Text("Best").tag(4320)
                    }
                    .pickerStyle(.menu)
                    .tint(settings.accent)
                }
            }
            Text("Episodes remember where you stopped. Speed is set from the player.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
        }
    }

    @ViewBuilder private var lyrics: some View {
        section("Lyrics") {
            toggle("Lyrics on CarPlay & Lock Screen",
                   "Shows the current line as a Live Activity. On CarPlay it needs iOS 26; it starts when you play something with Drift open.",
                   $settings.lyricsLiveActivity)
                .onChange(of: settings.lyricsLiveActivity) { _, _ in
                    LyricsActivity.shared.settingChanged()
                }
            toggle("Lyrics in Now Playing",
                   "Shows the current line on the lock screen player and CarPlay's Now Playing screen, where the artist normally is. Keeps working with Drift in the background.",
                   $settings.lyricsInNowPlaying)
            row("Synced source", "LRCLIB")
            row("Fallback (unsynced)", "Genius")
        }
    }

    @ViewBuilder private var storage: some View {
        section("Downloads") {
            toggle("Download over mobile data", "When off, downloads wait for Wi-Fi.", $settings.downloadOverCellular)
            HStack {
                Text("Storage used").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(library.downloaded.count) songs · \(ByteCountFormatter.string(fromByteCount: library.downloadsSize, countStyle: .file))")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.vertical, 6)
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Text("Remove all downloads")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xFF6B5B))
                    .frame(height: 44)
            }
            .disabled(library.downloaded.isEmpty)
        }

        section("Song cache") {
            Text("Songs you've played are kept on your iPhone, so they start right away next time and use no data. The ones played longest ago make room for new ones.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .padding(.bottom, 4)
            HStack {
                Text("Keep up to").font(.system(size: 15, weight: .semibold))
                Spacer()
                Picker("Keep up to", selection: $settings.songCacheMB) {
                    Text("Off").tag(0)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1024)
                    Text("2 GB").tag(2048)
                    Text("5 GB").tag(5120)
                }
                .pickerStyle(.menu)
                .tint(Theme.muted)
            }
            HStack {
                Text("Used").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(cacheUsage.map { "\($0.songs) songs · \(ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file))" } ?? "–")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.vertical, 6)
            Button(role: .destructive) {
                Task {
                    await PlayCache.shared.clear()
                    cacheUsage = await PlayCache.shared.usage()
                }
            } label: {
                Text("Clear song cache")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xFF6B5B))
                    .frame(height: 44)
            }
            .disabled((cacheUsage?.songs ?? 0) == 0)
        }
        .task(id: settings.songCacheMB) { cacheUsage = await PlayCache.shared.usage() }
    }

    @ViewBuilder private var account: some View {
        section("Profile") {
            NavigationLink(value: Route.profile) {
                HStack {
                    Text(SocialStore.shared.me.map { "\($0.name) (@\($0.username))" } ?? "Create a profile")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        section("Computer") {
            Button {
                linkComputer = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Link a computer").font(.system(size: 15, weight: .semibold))
                        Text("Use your library in Drift for Windows, Mac or Linux. Type the code the computer shows.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var look: some View {
        section("Style") {
            HStack(spacing: 4) {
                ForEach(UIStyle.allCases, id: \.self) { st in
                    qualityButton(st.title, selected: settings.uiStyle == st) { settings.uiStyle = st }
                }
            }
            .padding(4)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(settings.uiStyle == .music
                 ? "Looks like Apple Music: white or black pages, red accents, big titles."
                 : "Drift's own look, like Spotify.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
        }

        if settings.uiStyle == .music {
            section("App icon") {
                HStack(spacing: 18) {
                    ForEach(MusicIcon.allCases, id: \.self) { icon in
                        Button { settings.musicIcon = icon } label: {
                            VStack(spacing: 8) {
                                AppIconPreview(icon: icon, size: 64)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 64 * 0.225, style: .continuous)
                                            .stroke(settings.musicIcon == icon ? settings.accent : Theme.line,
                                                    lineWidth: settings.musicIcon == icon ? 3 : 1)
                                            .padding(-4)
                                    )
                                Text(icon.title)
                                    .font(.system(size: 13, weight: settings.musicIcon == icon ? .bold : .regular))
                                    .foregroundStyle(settings.musicIcon == icon ? settings.accent : Theme.text2)
                            }
                            .padding(4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(icon.title) icon")
                        .accessibilityAddTraits(settings.musicIcon == icon ? .isSelected : [])
                    }
                    Spacer()
                }
                Text("The icon on your home screen. iOS shows a short message when it changes.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
        }

        section("Appearance") {
            HStack(spacing: 4) {
                ForEach(Appearance.allCases, id: \.self) { a in
                    qualityButton(a.title, selected: settings.appearance == a) { settings.appearance = a }
                }
            }
            .padding(4)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("Device follows your iPhone's light or dark setting. The player always stays dark.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            toggle("Glass effects",
                   DriftGlass.isSupported
                       ? "Apple's Liquid Glass look: a floating glass tab bar and mini player, a glass drawer and glass buttons in the player."
                       : "Apple's Liquid Glass look. Needs iOS 26 or newer.",
                   $settings.glassEffects)
                .disabled(!DriftGlass.isSupported)
                .padding(.top, 6)
        }

        if settings.uiStyle == .spotify {
        section("Accent color") {
            HStack(spacing: 10) {
                ForEach(Theme.accents.indices, id: \.self) { i in
                    Button {
                        settings.accentIndex = i
                    } label: {
                        Circle()
                            .fill(Color(hex: Theme.accents[i]))
                            .frame(width: 36, height: 36)
                            .overlay(Circle().stroke(Theme.text, lineWidth: settings.accentIndex == i ? 3 : 0).padding(-4))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(Theme.accentNames[i])
                    .accessibilityAddTraits(settings.accentIndex == i ? .isSelected : [])
                }
            }
        }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 13, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.muted)
            content()
        }
    }

    private func qualityButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(selected ? Theme.onAccent : Theme.text2)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? settings.accent : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func toggle(_ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(1)
            }
        }
        .tint(settings.accent)
        .padding(.vertical, 6)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
            Text(value).font(.system(size: 14)).foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 6)
    }
}
