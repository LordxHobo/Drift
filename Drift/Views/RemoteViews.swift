import SwiftUI

/// Pick where the music plays: this iPhone, or another device signed in to your Drift profile.
struct DevicesSheet: View {
    @Environment(\.dismiss) private var dismiss
    private var remote: RemoteControl { .shared }
    private var player: Player { .shared }
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        if remote.target != nil { remote.playHere() }
                        dismiss()
                    } label: {
                        row(symbol: "iphone", name: "This iPhone",
                            detail: remote.target == nil ? (player.current.map { "\($0.title) · \($0.artist)" } ?? "Playing here") : "Play here instead",
                            selected: remote.target == nil, available: true)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Theme.bg)

                    ForEach(remote.devices) { d in
                        Button {
                            remote.connect(d.id)
                            dismiss()
                        } label: {
                            row(symbol: d.symbol, name: d.name, detail: detail(d), selected: remote.target == d.id, available: d.online)
                        }
                        .buttonStyle(.plain)
                        .disabled(!d.online)
                        .listRowBackground(Theme.bg)
                    }
                } footer: {
                    Text(SocialStore.shared.me == nil
                         ? "Create a Drift profile and link your computer (Settings › Computer) to play there from here."
                         : remote.devices.isEmpty
                            ? "Your computer shows up here while Drift is open on it. Link it in Settings › Computer if you haven't yet."
                            : "Devices show up while Drift is open on them. Commands take about a second, and the first one a few seconds while the device wakes up.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Play on")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.bold) }
            }
            .onAppear { remote.pickerOpen = true }
            .onDisappear { remote.pickerOpen = false }
        }
        .tint(accent)
        .presentationDetents([.medium, .large])
    }

    private func detail(_ d: RemoteDevice) -> String {
        guard d.online else { return "Not available. Open Drift on it." }
        if let t = d.track { return "\(d.playing ? "Playing" : "Paused") · \(t.title) · \(t.artist)" }
        return "Available"
    }

    private func row(symbol: String, name: String, detail: String, selected: Bool, available: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .frame(width: 34)
                .foregroundStyle(selected ? accent : Theme.text)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 16, weight: .semibold)).foregroundStyle(selected ? accent : Theme.text)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if selected {
                Image(systemName: "checkmark").foregroundStyle(accent).font(.system(size: 15, weight: .bold))
            }
        }
        .frame(minHeight: 56)
        .opacity(available ? 1 : 0.5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The devices button (player, mini player): lit while playing on another device.
struct DevicesButton: View {
    var size: CGFloat = 17
    @State private var show = false
    private var remote: RemoteControl { .shared }

    var body: some View {
        Button { show = true } label: {
            Image(systemName: remote.target != nil ? "hifispeaker.and.homepod.fill" : "hifispeaker.and.homepod")
                .font(.system(size: size))
                .foregroundStyle(remote.target != nil ? AppSettings.shared.accent : Theme.text)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(remote.targetDevice.map { "Playing on \($0.name). Choose a device" } ?? "Choose a device to play on")
        .sheet(isPresented: $show) { DevicesSheet() }
    }
}

/// The mini player while controlling another device.
struct RemoteMiniPlayer: View {
    var open: () -> Void
    private var remote: RemoteControl { .shared }
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        let d = remote.targetDevice
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    if let t = d?.track {
                        ArtworkView(url: t.artwork(size: 120), size: 44, corner: 5, seed: t.id)
                    } else {
                        SymbolTile(symbol: d?.symbol ?? "laptopcomputer", color: Theme.surface2, size: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d?.track?.title ?? "Nothing playing")
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Image(systemName: d?.symbol ?? "laptopcomputer").font(.system(size: 10))
                            Text(d.map { $0.online ? "Playing on \($0.name)" : "Can't reach \($0.name)" } ?? "Connecting…")
                                .lineLimit(1)
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open remote player")

            DevicesButton(size: 18)

            Button {
                remote.send(RemoteCommand(type: "toggle"))
            } label: {
                Image(systemName: d?.playing == true ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(d?.track == nil)
            .accessibilityLabel(d?.playing == true ? "Pause" : "Play")
        }
        .padding(8)
        .driftGlass(in: DriftGlass.isOn ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: 10, style: .continuous)),
                    clear: false, tint: Theme.miniPlayer.opacity(0.55), interactive: true,
                    fallback: Theme.miniPlayer)
    }
}

/// The player while controlling another device: what it plays, and its controls.
struct RemotePlayerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scrub: Double?
    @State private var volume: Double?
    private var remote: RemoteControl { .shared }
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            content(remote.targetDevice)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(LinearGradient(colors: [Theme.playerFallback, Color(hex: 0x121214)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onChange(of: remote.target) { _, t in if t == nil { dismiss() } }
    }

    @ViewBuilder
    private func content(_ d: RemoteDevice?) -> some View {
        VStack(spacing: 20) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close")
                Spacer()
                VStack(spacing: 1) {
                    Text("PLAYING ON").font(.system(size: 11, weight: .medium)).tracking(1).foregroundStyle(Color(hex: 0xD4D4D8))
                    Text(d?.name ?? "Another device").font(.system(size: 13, weight: .bold)).lineLimit(1)
                }
                Spacer()
                DevicesButton(size: 19)
            }

            if let d, !d.online {
                Text("Can't reach \(d.name). Make sure Drift is open on it and it's online.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: 0xFFB4A8))
                    .multilineTextAlignment(.center)
            } else if let e = remote.lastError {
                Text(e).font(.system(size: 13)).foregroundStyle(Color(hex: 0xFFB4A8))
            }

            GeometryReader { g in
                let side = min(g.size.width, g.size.height)
                Group {
                    if let t = d?.track {
                        ArtworkView(url: t.artwork(size: 800), size: side, corner: 8, seed: t.id)
                    } else {
                        SymbolTile(symbol: d?.symbol ?? "laptopcomputer", color: Theme.surface2, size: side)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .shadow(color: .black.opacity(0.45), radius: 25, y: 16)
                .frame(width: g.size.width, height: g.size.height)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(d?.track?.title ?? "Nothing playing")
                    .font(.system(size: 22, weight: .heavy))
                    .lineLimit(1)
                Text(d?.track?.artist ?? "Pick something to play, and it plays there.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: 0xD4D4D8))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            let duration = d?.duration ?? 0
            let position = d?.positionNow() ?? 0
            VStack(spacing: 6) {
                ScrubBar(progress: scrub ?? (duration > 0 ? min(position / duration, 1) : 0), markers: [],
                         onChange: { scrub = $0 }, onEnd: { p in
                    var c = RemoteCommand(type: "seek")
                    c.position = p * duration
                    remote.send(c)
                    scrub = nil
                })
                HStack {
                    Text(formatTime((scrub.map { $0 * duration }) ?? position))
                    Spacer()
                    Text(duration > 0 ? formatTime(duration) : "--:--")
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Color(hex: 0xD4D4D8))
            }

            HStack {
                Button {
                    var c = RemoteCommand(type: "shuffle")
                    c.on = !(d?.shuffle ?? false)
                    remote.send(c)
                } label: {
                    Image(systemName: "shuffle").font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(d?.shuffle == true ? accent : Color(hex: 0xD4D4D8)).frame(width: 44, height: 44)
                }
                .accessibilityLabel(d?.shuffle == true ? "Shuffle on" : "Shuffle off")
                Spacer()
                Button { remote.send(RemoteCommand(type: "previous")) } label: {
                    Image(systemName: "backward.end.fill").font(.system(size: 28)).frame(width: 52, height: 52)
                }
                .accessibilityLabel("Previous")
                Spacer()
                Button { remote.send(RemoteCommand(type: "toggle")) } label: {
                    ZStack {
                        Circle().fill(.white)
                        Image(systemName: d?.playing == true ? "pause.fill" : "play.fill")
                            .font(.system(size: 28)).foregroundStyle(.black)
                    }
                    .frame(width: 72, height: 72)
                }
                .accessibilityLabel(d?.playing == true ? "Pause" : "Play")
                Spacer()
                Button { remote.send(RemoteCommand(type: "next")) } label: {
                    Image(systemName: "forward.end.fill").font(.system(size: 28)).frame(width: 52, height: 52)
                }
                .accessibilityLabel("Next")
                Spacer()
                Button {
                    var c = RemoteCommand(type: "repeat")
                    c.mode = d?.repeatMode == "off" ? "all" : d?.repeatMode == "all" ? "one" : "off"
                    remote.send(c)
                } label: {
                    Image(systemName: d?.repeatMode == "one" ? "repeat.1" : "repeat").font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(d?.repeatMode == "off" || d == nil ? Color(hex: 0xD4D4D8) : accent).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Repeat")
            }
            .buttonStyle(.plain)
            .disabled(d == nil || d?.online == false)

            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").font(.system(size: 12))
                Slider(value: Binding(get: { volume ?? d?.volume ?? 1 }, set: { volume = $0 }), in: 0...1, onEditingChanged: { editing in
                    if !editing, let v = volume {
                        var c = RemoteCommand(type: "volume")
                        c.value = v
                        remote.send(c)
                        volume = nil
                    }
                })
                .tint(.white)
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 12))
            }
            .foregroundStyle(Color(hex: 0xD4D4D8))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Volume on \(d?.name ?? "the other device")")

            Button {
                remote.playHere()
                dismiss()
            } label: {
                Label("Play on this iPhone", systemImage: "iphone")
                    .font(.system(size: 15, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}
