import SwiftUI
import WidgetKit

/// A lock screen circle with Drift's logo; tapping it opens Drift (like Spotify's).
struct DriftLauncherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DriftLauncher", provider: LauncherProvider()) { _ in
            LauncherView()
        }
        .configurationDisplayName("Drift")
        .description("Opens Drift.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct LauncherEntry: TimelineEntry {
    let date: Date
}

/// Nothing changes over time, so there's one entry and no refreshes.
struct LauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> LauncherEntry { LauncherEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (LauncherEntry) -> Void) {
        completion(LauncherEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LauncherEntry>) -> Void) {
        completion(Timeline(entries: [LauncherEntry(date: .now)], policy: .never))
    }
}

struct LauncherView: View {
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            DriftLogo()
                .padding(13)
        }
        .widgetAccentable()
        .containerBackground(for: .widget) { Color.clear }
        .accessibilityLabel("Open Drift")
    }
}

/// Drift's four bars, drawn to scale from the app icon so they stay sharp at any size.
struct DriftLogo: View {
    // Each bar's top and bottom within the logo, from 0 (top) to 1 (bottom).
    private let bars: [(top: CGFloat, bottom: CGFloat)] = [
        (50.0 / 519, 469.0 / 519),
        (120.0 / 519, 399.0 / 519),
        (0, 1),
        (80.0 / 519, 439.0 / 519),
    ]

    var body: some View {
        GeometryReader { geo in
            // The logo is 492 wide and 519 tall; bars are 96 wide with 36 between them.
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
    }
}
