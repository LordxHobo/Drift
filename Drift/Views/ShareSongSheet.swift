import SwiftUI

/// Share a song: a link, or a picture of it (cover, title and artist) for a story or a chat.
struct ShareSongSheet: View {
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var card: UIImage?
    @State private var copied = false
    private var accent: Color { AppSettings.shared.accent }

    /// Where the song can be opened by anyone (YouTube Music, YouTube, or the episode's file).
    static func link(for t: Track) -> URL {
        if let audio = t.audioURL { return audio }
        if t.isEpisode || t.upload == true { return URL(string: "https://www.youtube.com/watch?v=\(t.id)")! }
        return URL(string: "https://music.youtube.com/watch?v=\(t.id)")!
    }

    private var link: URL { Self.link(for: track) }
    private var caption: String { "\(track.title) by \(track.artist)" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Group {
                    if let card {
                        Image(uiImage: card)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
                            .accessibilityLabel("Picture of \(caption)")
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.surface)
                            .aspectRatio(9 / 16, contentMode: .fit)
                            .overlay(ProgressView())
                    }
                }
                .frame(maxHeight: .infinity)

                VStack(spacing: 10) {
                    if let card {
                        ShareLink(item: Image(uiImage: card), subject: Text(caption), message: Text(link.absoluteString),
                                  preview: SharePreview(caption, image: Image(uiImage: card))) {
                            wide("Share picture", icon: "photo", filled: true)
                        }
                    }
                    HStack(spacing: 10) {
                        ShareLink(item: link, subject: Text(caption), message: Text(caption)) {
                            wide("Share link", icon: "square.and.arrow.up", filled: false)
                        }
                        Button {
                            UIPasteboard.general.url = link
                            copied = true
                        } label: {
                            wide(copied ? "Copied" : "Copy link", icon: copied ? "checkmark" : "link", filled: false)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Theme.bg)
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.bold)
                }
            }
            .task { await makeCard() }
        }
        .tint(accent)
    }

    private func wide(_ title: String, icon: String, filled: Bool) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 15, weight: .bold))
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(filled ? Theme.onAccent : Theme.text)
            .background(filled ? accent : Theme.surface, in: Capsule())
            .contentShape(Capsule())
    }

    private func makeCard() async {
        let artURL = track.artwork(size: 800)
        var art: UIImage?
        if let artURL, let result = try? await URLSession.shared.data(from: artURL) { art = UIImage(data: result.0) }
        let color = await ArtworkPalette.color(for: track.artwork(size: 200)) ?? Theme.playerFallback
        let renderer = ImageRenderer(content: ShareCard(track: track, art: art, color: color))
        renderer.scale = 3
        card = renderer.uiImage
    }
}

/// The picture: 1080 × 1920 (a phone story), the cover in the middle on its own colour.
struct ShareCard: View {
    let track: Track
    let art: UIImage?
    let color: Color

    var body: some View {
        ZStack {
            LinearGradient(colors: [color, color.opacity(0.75), Color(hex: 0x0E0E10)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                Group {
                    if let art {
                        Image(uiImage: art).resizable().scaledToFill()
                    } else {
                        Theme.tile(seed: track.id)
                    }
                }
                .frame(width: 280, height: track.isEpisode && track.audioURL == nil ? 158 : 280)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 20, y: 12)
                Text(track.title)
                    .font(.system(size: 26, weight: .heavy))
                    .tracking(-0.4)
                    .lineLimit(3)
                    .padding(.top, 24)
                Text(track.artist)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .padding(.top, 4)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    DriftMark()
                        .frame(width: 20, height: 21)
                    Text("Drift")
                        .font(.system(size: 17, weight: .heavy))
                }
                .foregroundStyle(.white)
            }
            .frame(width: 280)
            .padding(.vertical, 40)
        }
        .foregroundStyle(.white)
        .frame(width: 360, height: 640)
        .environment(\.colorScheme, .dark)
    }
}

/// Drift's logo (the four bars of the app icon), in the current foreground colour.
struct DriftMark: View {
    private let bars: [(top: CGFloat, bottom: CGFloat)] = [
        (50.0 / 519, 469.0 / 519), (120.0 / 519, 399.0 / 519), (0, 1), (80.0 / 519, 439.0 / 519),
    ]

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / 492, geo.size.height / 519)
            let width = 492 * scale
            let height = 519 * scale
            let x0 = (geo.size.width - width) / 2
            let y0 = (geo.size.height - height) / 2
            ForEach(bars.indices, id: \.self) { i in
                let bar = bars[i]
                Capsule()
                    .frame(width: 96 * scale, height: (bar.bottom - bar.top) * height)
                    .position(x: x0 + (48 + CGFloat(i) * 132) * scale,
                              y: y0 + (bar.top + bar.bottom) / 2 * height)
            }
        }
        .accessibilityHidden(true)
    }
}
