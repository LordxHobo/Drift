import SwiftUI

/// Drift's notifications: import reports and new releases from followed artists.
struct NotificationsView: View {
    @State private var confirmClear = false
    private var store: NotificationStore { .shared }
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        List {
            if store.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bell")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.muted)
                    Text("No notifications")
                        .font(.system(size: 17, weight: .bold))
                    Text("Songs that couldn't be found when importing a playlist, and new releases from artists you follow, show up here.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 50)
                .listRowBackground(Theme.bg)
                .listRowSeparator(.hidden)
            }
            ForEach(store.items) { n in
                NavigationLink(value: Route.notification(n.id)) {
                    row(n)
                }
                .listRowBackground(Theme.bg)
                .swipeActions {
                    Button(role: .destructive) { store.delete(n.id) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    if !n.missing.isEmpty {
                        Button { NotificationStore.copy(n.missing) } label: {
                            Label("Copy missing songs", systemImage: "doc.on.doc")
                        }
                    }
                    Button(role: .destructive) { store.delete(n.id) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .toolbar {
            if !store.items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { store.markAllRead() } label: { Label("Mark all as read", systemImage: "checkmark") }
                        Button(role: .destructive) { confirmClear = true } label: {
                            Label("Clear all", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .confirmationDialog("Clear all notifications?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear all", role: .destructive) { store.clearAll() }
        }
    }

    private func row(_ n: AppNotification) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: n.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(n.kind == .newReleases ? accent : Color(hex: 0xF5A524))
                .frame(width: 40, height: 40)
                .background(Theme.surface, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(n.title)
                        .font(.system(size: 15, weight: n.read ? .semibold : .bold))
                        .lineLimit(2)
                    Spacer(minLength: 6)
                    Text(Self.when(n.date))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                }
                Text(n.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
            if !n.read {
                Circle().fill(accent).frame(width: 8, height: 8).padding(.top, 6)
                    .accessibilityLabel("Unread")
            }
        }
        .padding(.vertical, 6)
    }

    static func when(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// One notification in full: every missing song (copyable) or every new release.
struct NotificationDetailView: View {
    let id: UUID
    @State private var copied = false
    @State private var searching = false
    @State private var searched = 0
    private var store: NotificationStore { .shared }
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        Group {
            if let n = store.item(id) {
                content(n)
            } else {
                Text("This notification was deleted.")
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .onAppear { store.markRead(id) }
    }

    /// Matches the missing songs again (now also against regular YouTube uploads) and adds what's found.
    private func searchAgain(_ n: AppNotification, playlist pid: UUID) {
        searching = true
        searched = 0
        let songs = n.missing
        Task {
            var results = [Track?](repeating: nil, count: songs.count)
            for start in stride(from: 0, to: songs.count, by: 4) {
                let range = start..<min(start + 4, songs.count)
                let batch = await withTaskGroup(of: (Int, Track?).self) { group in
                    for i in range {
                        let m = songs[i]
                        group.addTask {
                            (i, await SongMatcher.match(SpotifyTrack(title: m.title, artist: m.artist, duration: m.duration)))
                        }
                    }
                    var out: [(Int, Track?)] = []
                    for await r in group { out.append(r) }
                    return out
                }
                for (i, t) in batch { results[i] = t }
                searched = range.upperBound
            }
            let found = results.compactMap { $0 }
            let still = songs.indices.filter { results[$0] == nil }.map { songs[$0] }
            Library.shared.appendTracks(found, to: pid)
            NotificationStore.shared.updateMissing(n.id, still, found: found.count)
            searching = false
        }
    }

    private func content(_ n: AppNotification) -> some View {
        List {
            VStack(alignment: .leading, spacing: 8) {
                Text(n.title)
                    .font(.system(size: 22, weight: .heavy))
                    .tracking(-0.4)
                Text(n.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                Text(n.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)

                if !n.missing.isEmpty {
                    HStack(spacing: 10) {
                        Button {
                            NotificationStore.copy(n.missing)
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy all \(n.missing.count)",
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 16)
                                .frame(minHeight: 44)
                                .background(accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        ShareLink(item: n.missing.map(\.line).joined(separator: "\n")) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(Theme.surface, in: Circle())
                        }
                        .accessibilityLabel("Share the list")
                        if let pid = n.playlistID, Library.shared.playlist(pid) != nil {
                            NavigationLink(value: Route.playlist(pid)) {
                                Text("Open playlist")
                                    .font(.system(size: 14, weight: .bold))
                                    .padding(.horizontal, 16)
                                    .frame(minHeight: 44)
                                    .overlay(Capsule().stroke(Theme.muted, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 8)
                    if let pid = n.playlistID, Library.shared.playlist(pid) != nil {
                        Button {
                            searchAgain(n, playlist: pid)
                        } label: {
                            Label(searching ? "Looking… \(searched) of \(n.missing.count)" : "Look for these again, including YouTube uploads",
                                  systemImage: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(accent)
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(searching)
                    }
                    Text("Copied as “Artist - Title”, one per line, ready to paste into Notes. Long-press a song to copy just that one.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(.vertical, 8)
            .listRowBackground(Theme.bg)
            .listRowSeparator(.hidden)

            ForEach(Array(n.missing.enumerated()), id: \.offset) { i, song in
                HStack(spacing: 12) {
                    Text("\(i + 1)")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                        .frame(width: 32, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                        if !song.artist.isEmpty {
                            Text(song.artist).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                }
                .padding(.vertical, 2)
                .listRowBackground(Theme.bg)
                .contextMenu {
                    Button { NotificationStore.copy([song]) } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            }

            ForEach(n.releases) { r in
                NavigationLink(value: Route.album(r.album, artist: r.artistName)) {
                    HStack(spacing: 12) {
                        AsyncImage(url: resizedImage(r.album.thumbnail, size: 200)) { phase in
                            if let img = phase.image { img.resizable().scaledToFill() } else { Theme.tile(seed: r.album.id) }
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.album.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Text("\(r.artistName) · \(r.album.subtitle)")
                                .font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                }
                .listRowBackground(Theme.bg)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}
