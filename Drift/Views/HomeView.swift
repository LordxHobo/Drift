import SwiftUI

struct HomeView: View {
    private var library: Library { .shared }
    private var player: Player { .shared }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text(greeting)
                        .font(.system(size: 26, weight: .heavy))
                        .tracking(-0.5)
                    Spacer()
                    NavigationLink(value: Route.settings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 20))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Settings")
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    NavigationLink(value: Route.liked) {
                        QuickTile(title: "Liked songs") {
                            SymbolTile(symbol: "heart.fill", color: Color(hex: 0x4338CA), size: 56)
                        }
                    }
                    NavigationLink(value: Route.downloads) {
                        QuickTile(title: "Downloaded") {
                            SymbolTile(symbol: "arrow.down", color: Theme.line, size: 56)
                        }
                    }
                    ForEach(library.playlists.prefix(4)) { p in
                        NavigationLink(value: Route.playlist(p.id)) {
                            QuickTile(title: p.name) {
                                PlaylistArt(playlist: p, size: 56, corner: 0)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)

                if library.recent.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nothing played yet")
                            .font(.system(size: 20, weight: .heavy))
                        Text("Find a song in Search and it will show up here.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.top, 12)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Jump back in")
                            .font(.system(size: 20, weight: .heavy))
                            .tracking(-0.3)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(Array(library.recent.prefix(15).enumerated()), id: \.element.id) { i, t in
                                    Button {
                                        player.play(Array(library.recent.prefix(15)), startAt: i, from: "Recently played")
                                    } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            ArtworkView(url: t.artwork(size: 400), size: 140, corner: 6, seed: t.id)
                                            Text(t.title)
                                                .font(.system(size: 13, weight: .bold))
                                                .lineLimit(1)
                                            Text(t.artist)
                                                .font(.system(size: 12))
                                                .foregroundStyle(Theme.muted)
                                                .lineLimit(1)
                                        }
                                        .frame(width: 140, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu { TrackMenuItems(track: t) }
                                }
                            }
                        }
                        .scrollClipDisabled()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct QuickTile<Art: View>: View {
    let title: String
    @ViewBuilder var art: () -> Art

    var body: some View {
        HStack(spacing: 10) {
            art()
                .frame(width: 56, height: 56)
                .clipped()
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 4)
        }
        .frame(height: 56)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
    }
}
