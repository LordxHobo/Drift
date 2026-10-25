import Foundation
import Observation
import UIKit

/// A song that couldn't be found when importing.
struct MissingSong: Codable, Hashable {
    var title: String
    var artist: String

    var line: String { artist.isEmpty ? title : "\(artist) - \(title)" }
}

/// Something shown in Drift's notifications list.
struct AppNotification: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case importReport, newReleases
    }

    var id = UUID()
    var kind: Kind
    var date = Date()
    var title: String
    var detail: String
    var read = false
    /// Import report: the playlist it went into and the songs that weren't found.
    var playlistID: UUID?
    var missing: [MissingSong] = []
    /// New releases from followed artists.
    var releases: [NewRelease] = []

    var symbol: String {
        switch kind {
        case .importReport: "exclamationmark.triangle.fill"
        case .newReleases: "sparkles"
        }
    }
}

/// Drift's own notifications (import reports, new releases), saved on the phone.
@Observable @MainActor
final class NotificationStore {
    static let shared = NotificationStore()

    private(set) var items: [AppNotification] = []

    @ObservationIgnored private let url = URL.documentsDirectory.appending(path: "notifications.json")

    private init() {
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([AppNotification].self, from: data) {
            items = list
        }
    }

    var unreadCount: Int { items.filter { !$0.read }.count }

    func item(_ id: UUID) -> AppNotification? { items.first { $0.id == id } }

    func post(_ n: AppNotification) {
        items.insert(n, at: 0)
        if items.count > 100 { items.removeLast(items.count - 100) }
        save()
    }

    func markRead(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].read else { return }
        items[i].read = true
        save()
    }

    func markAllRead() {
        guard items.contains(where: { !$0.read }) else { return }
        for i in items.indices { items[i].read = true }
        save()
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func clearAll() {
        items.removeAll()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The songs as text, one per line ("Artist - Title"), ready to paste into Notes.
    static func copy(_ songs: [MissingSong], heading: String? = nil) {
        var lines = songs.map(\.line)
        if let heading { lines.insert(heading, at: 0) }
        UIPasteboard.general.string = lines.joined(separator: "\n")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
