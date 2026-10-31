import SwiftUI

/// The queue: what's playing and what comes next. Tap a song to play it, hold and drag to move it,
/// swipe to remove it.
struct QueueSheet: View {
    @Environment(\.dismiss) private var dismiss
    private var player: Player { .shared }
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        NavigationStack {
            List {
                if let t = player.current {
                    Section {
                        row(t, current: true)
                            .listRowBackground(Theme.bg)
                    } header: {
                        header("Now playing")
                    }
                }

                let next = player.upNext
                Section {
                    if next.isEmpty {
                        Text("Nothing's next. Add songs with Play next or Add to queue in a song's menu.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                            .listRowBackground(Theme.bg)
                    }
                    ForEach(Array(next.enumerated()), id: \.offset) { offset, t in
                        Button {
                            player.jump(to: player.index + 1 + offset)
                        } label: {
                            row(t, current: false)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.bg)
                    }
                    .onMove { player.moveUpNext(from: $0, to: $1) }
                    .onDelete { player.removeUpNext(at: $0) }
                } header: {
                    HStack {
                        header(player.playingFrom.isEmpty ? "Next" : "Next from \(player.playingFrom)")
                        Spacer()
                        if !next.isEmpty {
                            Button("Clear") { player.clearUpNext() }
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(accent)
                                .textCase(nil)
                        }
                    }
                } footer: {
                    if next.count > 1 {
                        Text("Hold a song and drag to move it. Swipe left to remove it.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.bold)
                }
            }
        }
        .tint(accent)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .heavy))
            .foregroundStyle(Theme.text)
            .textCase(nil)
            .lineLimit(1)
    }

    private func row(_ t: Track, current: Bool) -> some View {
        HStack(spacing: 12) {
            ArtworkView(url: t.artwork(size: 120), size: 44, seed: t.id)
            VStack(alignment: .leading, spacing: 3) {
                Text(t.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(current ? accent : Theme.text)
                    .lineLimit(1)
                Text(t.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if current {
                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(current ? "" : "Plays this song")
    }
}
