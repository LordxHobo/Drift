import SwiftUI

struct LyricsView: View {
    var background: Color
    @Environment(\.dismiss) private var dismiss
    @State private var result: LyricsResult?
    @State private var loadedFor: String?
    private var player: Player { .shared }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            Color.black.opacity(0.15).ignoresSafeArea()

            VStack(spacing: 14) {
                header
                lyrics
                    .frame(maxHeight: .infinity)
                controls
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .foregroundStyle(Theme.text)
        .gesture(DragGesture().onEnded { v in
            if v.translation.height > 140 { dismiss() }
        })
        .task(id: player.current?.id) {
            guard let t = player.current else { return }
            if loadedFor != t.id { result = nil }
            let r = await LyricsService.shared.lyrics(for: t)
            if player.current?.id == t.id {
                result = r
                loadedFor = t.id
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .padding(.leading, -10)
            .accessibilityLabel("Back to player")
            VStack(alignment: .leading, spacing: 1) {
                Text(player.current?.title ?? "")
                    .font(.system(size: 15, weight: .heavy))
                    .lineLimit(1)
                Text(player.current?.artist ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            Spacer()
            if case .synced? = result {
                badge("SYNCED")
            }
        }
    }

    @ViewBuilder
    private var lyrics: some View {
        switch result {
        case nil:
            ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notFound?:
            VStack(spacing: 8) {
                Text("No lyrics found")
                    .font(.system(size: 22, weight: .heavy))
                Text("LRCLIB and Genius don't have this one.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .plain(let text, let source)?:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(text)
                        .font(.system(size: 22, weight: .bold))
                        .lineSpacing(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Lyrics from \(source) · not synced")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.vertical, 20)
            }
            .scrollIndicators(.hidden)
        case .synced(let lines, let source)?:
            SyncedLyrics(lines: lines, source: source)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            ScrubBar(progress: player.progress, onChange: { _ in }, onEnd: { p in
                player.seek(to: p * player.duration)
            })
            HStack {
                Text(formatTime(player.currentTime))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 44, alignment: .leading)
                Spacer()
                Button { player.previous() } label: {
                    Image(systemName: "backward.end.fill").font(.system(size: 24)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Previous")
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(background)
                        .frame(width: 56, height: 56)
                        .background(Theme.text, in: Circle())
                }
                .padding(.horizontal, 18)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.next() } label: {
                    Image(systemName: "forward.end.fill").font(.system(size: 24)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Next")
                Spacer()
                Text(formatTime(player.duration))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 44, alignment: .trailing)
            }
            .buttonStyle(.plain)
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy))
            .tracking(0.5)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct SyncedLyrics: View {
    let lines: [LyricLine]
    let source: String
    @State private var userScrolledAt: Date?
    private var player: Player { .shared }

    private var currentIndex: Int {
        let t = player.currentTime + 0.25
        var lo = 0, hi = lines.count - 1, ans = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= t { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }

    var body: some View {
        let current = currentIndex
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: 26, weight: .heavy))
                            .tracking(-0.4)
                            .foregroundStyle(color(i, current))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { player.seek(to: line.time) }
                            .id(i)
                            .animation(.easeOut(duration: 0.25), value: current)
                    }
                    Text("Lyrics from \(source)")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, 12)
                }
                .padding(.vertical, 160)
            }
            .scrollIndicators(.hidden)
            .simultaneousGesture(DragGesture().onChanged { _ in userScrolledAt = Date() })
            .onChange(of: current) { _, new in
                // Follow along unless the person scrolled in the last few seconds.
                if let at = userScrolledAt, Date().timeIntervalSince(at) < 4 { return }
                withAnimation(.easeInOut(duration: 0.45)) {
                    proxy.scrollTo(max(new, 0), anchor: UnitPoint(x: 0.5, y: 0.35))
                }
            }
            .onAppear {
                proxy.scrollTo(max(current, 0), anchor: UnitPoint(x: 0.5, y: 0.35))
            }
        }
    }

    private func color(_ i: Int, _ current: Int) -> Color {
        if i == current { return .white }
        if i < current { return .white.opacity(0.5) }
        return .white.opacity(0.72)
    }
}
