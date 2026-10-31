import SwiftUI

/// Settings › Equalizer: on or off, a preset, and the 10 bands (this phone only).
struct EqualizerView: View {
    @State private var settings = AppSettings.shared
    private var accent: Color { settings.accent }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Toggle(isOn: $settings.eqEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Equalizer").font(.system(size: 17, weight: .bold))
                        Text("Shape the sound of everything you play on this iPhone. Not used with AirPlay, where the speaker plays the sound.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                    }
                }
                .tint(accent)

                VStack(alignment: .leading, spacing: 10) {
                    Text("PRESETS")
                        .font(.system(size: 13, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.muted)
                    let current = Equalizer.presetName(settings.eqGains)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(Equalizer.presets) { p in
                            Button {
                                settings.eqGains = p.gains
                                if !settings.eqEnabled && p.name != "Flat" { settings.eqEnabled = true }
                            } label: {
                                Text(p.name)
                                    .font(.system(size: 13, weight: .bold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .frame(maxWidth: .infinity, minHeight: 38)
                                    .foregroundStyle(current == p.name ? Theme.onAccent : Theme.text)
                                    .background(current == p.name ? accent : Theme.surface, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(current == p.name ? .isSelected : [])
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("BANDS")
                            .font(.system(size: 13, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(Theme.muted)
                        Spacer()
                        Text(Equalizer.presetName(settings.eqGains))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                    }
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(Equalizer.bands.indices, id: \.self) { i in
                            BandSlider(index: i, gain: Binding(
                                get: { settings.eqGains[i] },
                                set: { v in
                                    var g = settings.eqGains
                                    g[i] = (v * 2).rounded() / 2
                                    settings.eqGains = g
                                    if !settings.eqEnabled { settings.eqEnabled = true }
                                }), accent: accent)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 250)
                    .opacity(settings.eqEnabled ? 1 : 0.5)
                    Text("+12 dB at the top, −12 dB at the bottom. Drift lowers the volume a little when you boost, so loud songs don't distort.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }

                Button {
                    settings.eqGains = Equalizer.presets[0].gains
                } label: {
                    Text("Reset to flat")
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Theme.surface, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Equalizer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
    }
}

/// One band: a vertical slider with its gain above and frequency below.
private struct BandSlider: View {
    let index: Int
    @Binding var gain: Double
    let accent: Color

    var body: some View {
        VStack(spacing: 6) {
            Text(gain > 0 ? "+\(format(gain))" : format(gain))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            GeometryReader { geo in
                Slider(value: $gain, in: Equalizer.range)
                    .tint(accent)
                    .frame(width: geo.size.height)
                    .rotationEffect(.degrees(-90))
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            Text(Equalizer.label(Equalizer.bands[index]))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Equalizer.label(Equalizer.bands[index])) hertz")
        .accessibilityValue("\(format(gain)) decibels")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: gain = min(12, gain + 1)
            case .decrement: gain = max(-12, gain - 1)
            @unknown default: break
            }
        }
    }

    private func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
