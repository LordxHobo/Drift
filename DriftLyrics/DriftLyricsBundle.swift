import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DriftLyricsBundle: WidgetBundle {
    var body: some Widget {
        LyricsLiveActivity()
    }
}

private let green = Color(.sRGB, red: 0x1E / 255, green: 0xD7 / 255, blue: 0x60 / 255, opacity: 1)
private let muted = Color(.sRGB, red: 0xA1 / 255, green: 0xA1 / 255, blue: 0xAA / 255, opacity: 1)
private let background = Color(.sRGB, red: 0x0E / 255, green: 0x0E / 255, blue: 0x10 / 255, opacity: 1)

struct LyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            LyricsActivityView(state: context.state)
                .activityBackgroundTint(background)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "waveform")
                        .foregroundStyle(green)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(mainText(context.state))
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .contentTransition(.opacity)
                }
            } compactLeading: {
                Image(systemName: "waveform").foregroundStyle(green)
            } compactTrailing: {
                Text(context.state.line.isEmpty ? "♪" : context.state.line)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 90)
            } minimal: {
                Image(systemName: "waveform").foregroundStyle(green)
            }
        }
        // CarPlay (iOS 26) and the Apple Watch Smart Stack use the small layout.
        .supplementalActivityFamilies([.small])
    }
}

private func mainText(_ s: LyricsActivityAttributes.ContentState) -> String {
    if !s.line.isEmpty { return s.line }
    switch s.lyricsKind {
    case "synced": return "♪"
    case "unsynced": return "Lyrics aren't synced for this song"
    default: return s.artist
    }
}

struct LyricsActivityView: View {
    let state: LyricsActivityAttributes.ContentState
    @Environment(\.activityFamily) private var family

    var body: some View {
        switch family {
        case .small:
            // CarPlay / Watch: big, glanceable current line only.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                        .font(.caption2)
                        .foregroundStyle(green)
                    Text(state.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                }
                Text(mainText(state))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(10)
        default:
            // Lock screen.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                        .font(.caption)
                        .foregroundStyle(green)
                    Text("\(state.title) · \(state.artist)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                }
                Text(mainText(state))
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .contentTransition(.opacity)
                if !state.nextLine.isEmpty {
                    Text(state.nextLine)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }
}
