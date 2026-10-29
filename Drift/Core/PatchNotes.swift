import Foundation

/// What's new: shown once after an update (the same notes as on the computer, from patchNotes.json).
enum PatchNotes {
    struct Note: Decodable, Hashable {
        let text: String
        let platforms: [String]?
    }

    struct Entry: Decodable, Identifiable, Hashable {
        let id: Int
        let date: String
        let title: String
        let notes: [Note]
    }

    private struct File: Decodable {
        let entries: [Entry]
    }

    private static let seenKey = "patchNotes.seen"

    private static let all: [Entry] = {
        guard let url = Bundle.main.url(forResource: "patchNotes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.entries
    }()

    /// This phone's notes, newest first.
    private static var forPhone: [Entry] {
        all.compactMap { e in
            let notes = e.notes.filter { $0.platforms == nil || $0.platforms!.contains("ios") }
            return notes.isEmpty ? nil : Entry(id: e.id, date: e.date, title: e.title, notes: notes)
        }
    }

    /// Notes not seen yet: everything newer than the last ones seen (just the latest, the first time).
    static func unseen() -> [Entry] {
        let entries = forPhone
        guard let seen = UserDefaults.standard.object(forKey: seenKey) as? Int else { return Array(entries.prefix(1)) }
        return entries.filter { $0.id > seen }
    }

    static func markSeen() {
        UserDefaults.standard.set(all.map(\.id).max() ?? 0, forKey: seenKey)
    }

    static func dateText(_ s: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: s) else { return s }
        return d.formatted(date: .long, time: .omitted)
    }
}
