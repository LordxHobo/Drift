import Foundation
import Observation
import UIKit

/// New versions, through SideStore: every build is published with a SideStore source (build.yml). Drift
/// looks at that source on launch and, when a newer build is out, offers to open SideStore (which adds
/// the source the first time, then installs the update with one tap; the library stays).
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    static let sourceURL = "https://github.com/LordxHobo/Drift/releases/download/sidestore/source.json"

    struct Update: Equatable {
        let version: String
        let build: Int
        let notes: String
    }

    /// A newer build than this one, if there is one.
    private(set) var available: Update?
    /// Shown on launch until "Later" (per build).
    var prompt = false
    private(set) var checking = false
    private(set) var lastCheck: Date?

    private let laterKey = "update.later"
    private let checkedKey = "update.checkedAt"

    private struct Source: Decodable {
        struct App: Decodable {
            struct Version: Decodable {
                let version: String
                let buildVersion: String?
                let localizedDescription: String?
            }
            let versions: [Version]
        }
        let apps: [App]
    }

    private var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    /// Looks for a newer build. `manual`: from Settings (always looks, and asks even if put off).
    func check(manual: Bool = false) async {
        guard !checking else { return }
        let defaults = UserDefaults.standard
        // On launch at most every 3 hours.
        if !manual, available == nil,
           Date().timeIntervalSince1970 - defaults.double(forKey: checkedKey) < 3 * 3600 { return }
        checking = true
        defer { checking = false }
        guard let url = URL(string: Self.sourceURL),
              let result = try? await URLSession.shared.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let source = try? JSONDecoder().decode(Source.self, from: result.0),
              let newest = source.apps.first?.versions.first,
              let build = Int(newest.buildVersion ?? "")
        else { return }
        lastCheck = Date()
        defaults.set(Date().timeIntervalSince1970, forKey: checkedKey)
        if build > currentBuild {
            available = Update(version: newest.version, build: build, notes: newest.localizedDescription ?? "")
            prompt = manual || defaults.integer(forKey: laterKey) != build
        } else {
            available = nil
        }
    }

    /// Opens SideStore at Drift's source (added the first time), where the update installs with one tap.
    func openSideStore() {
        prompt = false
        let encoded = Self.sourceURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? Self.sourceURL
        if let url = URL(string: "sidestore://source?url=\(encoded)") {
            UIApplication.shared.open(url)
        }
    }

    /// "Later": don't ask again for this build (Settings still offers it).
    func later() {
        if let b = available?.build { UserDefaults.standard.set(b, forKey: laterKey) }
        prompt = false
    }
}
