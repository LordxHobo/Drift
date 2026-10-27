import SwiftUI
import UIKit
import Observation

/// Overall look: Drift's own (Spotify-like) or Apple Music–like.
enum UIStyle: String, CaseIterable {
    case spotify, music

    var title: String {
        switch self {
        case .spotify: "Spotify"
        case .music: "Apple Music"
        }
    }
}

enum Appearance: String, CaseIterable {
    case dark, light, system

    var title: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "Device"
        }
    }

    var style: UIUserInterfaceStyle {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: .unspecified
        }
    }
}

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
    /// Current lyric line as a Live Activity (lock screen, Dynamic Island, CarPlay on iOS 26).
    /// Move on when a song ends in a long stretch of silence.
    var skipSilence: Bool { didSet { defaults.set(skipSilence, forKey: "skipSilence") } }
    var lyricsLiveActivity: Bool { didSet { defaults.set(lyricsLiveActivity, forKey: "lyricsLiveActivity") } }
    /// Skip sponsor reads, self-promotion and subscribe reminders in podcasts (SponsorBlock).
    var skipSponsors: Bool { didSet { defaults.set(skipSponsors, forKey: "skipSponsors") } }
    var podcastSpeed: Double { didSet { defaults.set(podcastSpeed, forKey: "podcastSpeed") } }
    /// Liquid Glass tab bar, mini player, drawer and player buttons (iOS 26+).
    var glassEffects: Bool { didSet { defaults.set(glassEffects, forKey: "glassEffects") } }
    /// Current lyric line in the lock screen / CarPlay Now Playing info (in place of the artist).
    var lyricsInNowPlaying: Bool {
        didSet {
            defaults.set(lyricsInNowPlaying, forKey: "lyricsInNowPlaying")
            Task { @MainActor in LyricsActivity.shared.settingChanged() }
        }
    }
    var uiStyle: UIStyle { didSet { defaults.set(uiStyle.rawValue, forKey: "uiStyle") } }
    /// Dark (default), light, or follow the iPhone's setting.
    var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: "appearance")
            applyAppearance()
        }
    }

    private init() {
        let d = UserDefaults.standard
        accentIndex = d.object(forKey: "accentIndex") as? Int ?? 0
        dataSaver = d.bool(forKey: "dataSaver")
        skipNonMusic = d.object(forKey: "skipNonMusic") as? Bool ?? true
        preferOfficialAudio = d.object(forKey: "preferOfficialAudio") as? Bool ?? true
        downloadOverCellular = d.bool(forKey: "downloadOverCellular")
        lyricsLiveActivity = d.object(forKey: "lyricsLiveActivity") as? Bool ?? true
        skipSilence = d.object(forKey: "skipSilence") as? Bool ?? true
        skipSponsors = d.object(forKey: "skipSponsors") as? Bool ?? true
        podcastSpeed = d.object(forKey: "podcastSpeed") as? Double ?? 1
        glassEffects = d.bool(forKey: "glassEffects")
        lyricsInNowPlaying = d.object(forKey: "lyricsInNowPlaying") as? Bool ?? true
        uiStyle = d.string(forKey: "uiStyle").flatMap(UIStyle.init(rawValue:)) ?? .spotify
        appearance = d.string(forKey: "appearance").flatMap(Appearance.init(rawValue:)) ?? .dark
    }

    var accentHex: UInt32 {
        if uiStyle == .music { return Theme.musicRed }
        return Theme.accents[min(max(accentIndex, 0), Theme.accents.count - 1)]
    }
    /// A little darker in light mode so it stays readable on white.
    var accent: Color {
        if uiStyle == .music { return Color(hex: Theme.musicRed) }
        let h = accentHex
        func dim(_ shift: UInt32) -> UInt32 { UInt32(Double((h >> shift) & 0xFF) * 0.78) << shift }
        return Theme.dynamic(dark: h, light: dim(16) | dim(8) | dim(0))
    }

    /// Sets the look on every window (more reliable than SwiftUI's preferredColorScheme when going back to "Device").
    func applyAppearance() {
        let style = appearance.style
        Task { @MainActor in Self.apply(style) }
    }

    @MainActor private static func apply(_ style: UIUserInterfaceStyle) {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for w in ws.windows { w.overrideUserInterfaceStyle = style }
        }
    }
}
