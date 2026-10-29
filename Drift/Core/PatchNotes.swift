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
    private static let buildsKey = "patchNotes.builds"

    /// This app's build number (given by the build itself).
    static var currentBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }

    /// Which build each note came with: every build brings a new note, so the newest one is this build's.
    /// Remembered on the phone, since build numbers are only known once a build is made.
    private static func builds() -> [String: String] {
        var map = UserDefaults.standard.dictionary(forKey: buildsKey) as? [String: String] ?? [:]
        if let newest = all.first?.id, map[String(newest)] == nil {
            map[String(newest)] = currentBuild
            UserDefaults.standard.set(map, forKey: buildsKey)
        }
        return map
    }

    /// "Build 58", when known.
    static func build(of e: Entry) -> String? {
        builds()[String(e.id)].map { "Build \($0)" }
    }

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
        _ = builds()   // note which build this is
        let entries = forPhone
        guard let seen = UserDefaults.standard.object(forKey: seenKey) as? Int else { return Array(entries.prefix(1)) }
        return entries.filter { $0.id > seen }
    }

    /// Every note, newest first (tapping the version in Settings).
    static func everything() -> [Entry] { forPhone }

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
