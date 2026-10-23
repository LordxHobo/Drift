import SwiftUI
import Observation

@Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let defaults = UserDefaults.standard

    var accentIndex: Int { didSet { defaults.set(accentIndex, forKey: "accentIndex") } }
    /// Lowest-bitrate stream instead of the best one.
    var dataSaver: Bool { didSet { defaults.set(dataSaver, forKey: "dataSaver") } }
    /// Skip intros/outros/talking marked by the SponsorBlock community.
    var skipNonMusic: Bool { didSet { defaults.set(skipNonMusic, forKey: "skipNonMusic") } }
    /// Search YouTube Music "songs" (album audio) instead of all results incl. music videos.
    var preferOfficialAudio: Bool { didSet { defaults.set(preferOfficialAudio, forKey: "preferOfficialAudio") } }
    var downloadOverCellular: Bool { didSet { defaults.set(downloadOverCellular, forKey: "downloadOverCellular") } }

    private init() {
        let d = UserDefaults.standard
        accentIndex = d.object(forKey: "accentIndex") as? Int ?? 0
        dataSaver = d.bool(forKey: "dataSaver")
        skipNonMusic = d.object(forKey: "skipNonMusic") as? Bool ?? true
        preferOfficialAudio = d.object(forKey: "preferOfficialAudio") as? Bool ?? true
        downloadOverCellular = d.bool(forKey: "downloadOverCellular")
    }

    var accentHex: UInt32 {
        Theme.accents[min(max(accentIndex, 0), Theme.accents.count - 1)]
    }
    var accent: Color { Color(hex: accentHex) }
}
