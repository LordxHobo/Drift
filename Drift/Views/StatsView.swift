import Charts
import SwiftUI

/// Listening stats: how much you listened, to what, and when (every device you use Drift on).
struct StatsView: View {
    enum Span: String, CaseIterable, Identifiable {
        case month = "4 weeks", halfYear = "6 months", year = "This year", all = "All time"
        var id: String { rawValue }
    }

    @State private var span: Span = .month
    @State private var all: [PlayRecord] = []
    @State private var devices = 1
    @State private var loaded = false
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        let s = StatsSummary(plays: all, span: span)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Picker("Period", selection: $span) {
                    ForEach(Span.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if !loaded {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 40)
                } else if s.plays.isEmpty {
                    empty
                } else {
                    totals(s)
                    chart(s)
                    topArtists(s)
                    topSongs(s)
                    Text(footnote)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Listening stats")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        let r = await PlayHistory.shared.everything()
        all = r.plays
        devices = r.devices
        loaded = true
    }

    private var footnote: String {
        let since = all.map(\.at).min().map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) }
        var parts = ["Songs count once you've listened for 30 seconds."]
        if let since { parts.append("Counting since \(since).") }
        if devices > 1 { parts.append("Adds up \(devices) devices.") }
        else if SocialStore.shared.me == nil { parts.append("With a Drift profile, your computer's listening is added too.") }
        return parts.joined(separator: " ")
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 36))
                .foregroundStyle(Theme.muted)
            Text(all.isEmpty ? "Nothing yet" : "Nothing in this period")
                .font(.system(size: 18, weight: .bold))
            Text(all.isEmpty
                 ? "Play some music. Songs show up here once you've listened for 30 seconds."
                 : "Pick a longer period to see more.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }

    private func totals(_ s: StatsSummary) -> some View {
        HStack(alignment: .top, spacing: 0) {
            stat(s.minutes.formatted(), "minutes")
            stat(s.plays.count.formatted(), s.plays.count == 1 ? "play" : "plays")
            stat(s.artistCount.formatted(), s.artistCount == 1 ? "artist" : "artists")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 30, weight: .heavy).monospacedDigit())
                .tracking(-0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chart(_ s: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Minutes \(s.bucketName)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted)
            Chart(s.buckets) { b in
                BarMark(x: .value("When", b.start, unit: s.unit), y: .value("Minutes", b.minutes))
                    .foregroundStyle(accent)
                    .cornerRadius(2)
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(Theme.line.opacity(0.5))
                    AxisValueLabel().foregroundStyle(Theme.muted)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: s.axisFormat).foregroundStyle(Theme.muted)
                }
            }
            .frame(height: 150)
        }
    }

    private func topArtists(_ s: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top artists").font(.system(size: 20, weight: .heavy))
            ForEach(Array(s.topArtists.enumerated()), id: \.offset) { i, a in
                HStack(spacing: 12) {
                    Text("\(i + 1)")
                        .font(.system(size: 14, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                        .frame(width: 22, alignment: .trailing)
                    ArtworkView(url: a.art.flatMap { URL(string: $0) }, size: 44, corner: 22, seed: a.name)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text("\(a.minutes.formatted()) min · \(a.plays) \(a.plays == 1 ? "play" : "plays")")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func topSongs(_ s: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Top songs").font(.system(size: 20, weight: .heavy))
                Spacer()
                Button {
                    Player.shared.play(s.topSongs.map(\.track), from: "Your top songs")
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 34)
                        .background(accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            ForEach(Array(s.topSongs.enumerated()), id: \.offset) { i, song in
                Button {
                    Player.shared.play(s.topSongs.map(\.track), startAt: i, from: "Your top songs")
                } label: {
                    HStack(spacing: 12) {
                        Text("\(i + 1)")
                            .font(.system(size: 14, weight: .bold).monospacedDigit())
                            .foregroundStyle(Theme.muted)
                            .frame(width: 22, alignment: .trailing)
                        ArtworkView(url: song.track.artworkURL, size: 44, seed: song.track.id)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.track.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Text(song.track.artist).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text("\(song.plays) \(song.plays == 1 ? "play" : "plays")")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { TrackMenuItems(track: song.track) }
            }
        }
    }
}

/// The numbers for one period.
struct StatsSummary {
    struct Bucket: Identifiable {
        let start: Date
        var minutes: Double
        var id: Date { start }
    }
    struct Artist {
        let name: String
        var minutes: Int
        var plays: Int
        var art: String?
    }
    struct Song {
        let track: Track
        var plays: Int
        var secs: Double
    }

    let plays: [PlayRecord]
    let minutes: Int
    let artistCount: Int
    let buckets: [Bucket]
    let unit: Calendar.Component
    let bucketName: String
    let axisFormat: Date.FormatStyle
    let topArtists: [Artist]
    let topSongs: [Song]

    init(plays all: [PlayRecord], span: StatsView.Span) {
        let cal = Calendar.current
        let now = Date()
        let from: Date
        switch span {
        case .month: from = cal.date(byAdding: .day, value: -27, to: cal.startOfDay(for: now)) ?? now
        case .halfYear: from = cal.date(byAdding: .month, value: -6, to: now) ?? now
        case .year: from = cal.date(from: cal.dateComponents([.year], from: now)) ?? now
        case .all: from = .distantPast
        }
        // The same play can't count twice: one per song and start time.
        var seen = Set<String>()
        let list = all.filter { $0.at >= from.timeIntervalSince1970 && seen.insert("\($0.id)|\(Int($0.at.rounded()))").inserted }
        plays = list
        minutes = Int((list.reduce(0) { $0 + $1.secs } / 60).rounded())
        artistCount = Set(list.map { Self.mainArtist($0.artist) }).count

        // Minutes per day (4 weeks), week (6 months) or month (this year, all time).
        switch span {
        case .month:
            unit = .day; bucketName = "per day"; axisFormat = .dateTime.day().month(.abbreviated)
        case .halfYear:
            unit = .weekOfYear; bucketName = "per week"; axisFormat = .dateTime.day().month(.abbreviated)
        case .year, .all:
            unit = .month; bucketName = "per month"; axisFormat = .dateTime.month(.abbreviated)
        }
        let first = span == .all ? (list.map(\.at).min().map { Date(timeIntervalSince1970: $0) } ?? now) : from
        var start = cal.dateInterval(of: unit, for: first)?.start ?? first
        var buckets: [Bucket] = []
        while start <= now, buckets.count < 400 {
            buckets.append(Bucket(start: start, minutes: 0))
            guard let next = cal.date(byAdding: unit, value: 1, to: start) else { break }
            start = next
        }
        for p in list {
            let d = Date(timeIntervalSince1970: p.at)
            if let i = buckets.lastIndex(where: { $0.start <= d }) { buckets[i].minutes += p.secs / 60 }
        }
        self.buckets = buckets

        var artists: [String: Artist] = [:]
        var songs: [String: Song] = [:]
        for p in list {
            let name = Self.mainArtist(p.artist)
            var a = artists[name] ?? Artist(name: name, minutes: 0, plays: 0, art: nil)
            a.plays += 1
            a.minutes += Int(p.secs)
            if a.art == nil { a.art = p.art }
            artists[name] = a
            let art = p.art.flatMap { URL(string: $0) }
            var s = songs[p.id] ?? Song(track: Track(id: p.id, title: p.title, artist: p.artist, artworkURL: art), plays: 0, secs: 0)
            s.plays += 1
            s.secs += p.secs
            songs[p.id] = s
        }
        topArtists = artists.values
            .sorted { $0.minutes != $1.minutes ? $0.minutes > $1.minutes : $0.name < $1.name }
            .prefix(10)
            .map { (x: Artist) -> Artist in
                var a = x
                a.minutes = Int((Double(x.minutes) / 60).rounded())   // seconds → minutes
                return a
            }
        topSongs = Array(songs.values
            .sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.secs > $1.secs }
            .prefix(10))
    }

    /// "Artist feat. Someone" and "A, B & C" count for the first artist.
    static func mainArtist(_ s: String) -> String {
        var cut = s.endIndex
        for sep in [" feat. ", " ft. ", " featuring ", ", ", " & ", " x ", " · "] {
            if let r = s.range(of: sep, options: .caseInsensitive), r.lowerBound < cut { cut = r.lowerBound }
        }
        let name = s[..<cut].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? s : name
    }
}
