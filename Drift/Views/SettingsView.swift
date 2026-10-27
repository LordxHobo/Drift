import SwiftUI

struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var confirmDelete = false
    private var library: Library { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
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

                section("Ad-free listening") {
                    toggle("Skip non-music segments",
                           "Jumps past intros, outros and talking in music videos using community-marked timestamps (SponsorBlock).",
                           $settings.skipNonMusic)
                    toggle("Skip silence at the end",
                           "Moves to the next song when a song goes silent for several seconds in its second half (hidden tracks, long dead air).",
                           $settings.skipSilence)
                    toggle("Prefer official audio",
                           "Search returns album versions instead of music videos, and a music video plays as its album version when YouTube Music has one (no intros or cut endings).",
                           $settings.preferOfficialAudio)
                    Text("Audio is streamed directly, so YouTube ads never play.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }

                section("Podcasts") {
                    toggle("Skip sponsors",
                           "Skips sponsor reads, self-promotion and “like and subscribe” reminders that the SponsorBlock community has marked.",
                           $settings.skipSponsors)
                    Text("Episodes remember where you stopped. Speed is set from the player.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }

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

                section("Profile") {
                    NavigationLink(value: Route.profile) {
                        HStack {
                            Text(SocialStore.shared.me.map { "@\($0.username)" } ?? "Create a profile")
                                .font(.system(size: 15, weight: .semibold))
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                section("Lyrics") {
                    toggle("Lyrics on CarPlay & Lock Screen",
                           "Shows the current line as a Live Activity. On CarPlay it needs iOS 26; it starts when you play something with Drift open.",
                           $settings.lyricsLiveActivity)
                        .onChange(of: settings.lyricsLiveActivity) { _, _ in
                            LyricsActivity.shared.settingChanged()
                        }
                    row("Synced source", "LRCLIB")
                    row("Fallback (unsynced)", "Genius")
                }

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

                Text("Drift \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Theme.bg)
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .confirmationDialog("Remove all downloaded songs?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove all", role: .destructive) { library.removeAllDownloads() }
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
