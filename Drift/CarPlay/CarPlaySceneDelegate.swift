import CarPlay
import UIKit

/// CarPlay screens: Home (liked + recently played), Playlists and Downloads.
/// The car shows them in Apple's CarPlay style; playback uses the system Now Playing screen.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPTabBarTemplateDelegate {
    private var interface: CPInterfaceController?
    private let home = CPListTemplate(title: "Home", sections: [])
    private let playlists = CPListTemplate(title: "Playlists", sections: [])
    private let downloads = CPListTemplate(title: "Downloads", sections: [])
    private var imageCache: [URL: UIImage] = [:]

    nonisolated func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                              didConnect interfaceController: CPInterfaceController) {
        MainActor.assumeIsolated { connect(interfaceController) }
    }

    nonisolated func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                              didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        MainActor.assumeIsolated { interface = nil }
    }

    nonisolated func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        MainActor.assumeIsolated { refresh() }
    }

    private func connect(_ interfaceController: CPInterfaceController) {
        interface = interfaceController
        home.tabTitle = "Home"
        home.tabImage = UIImage(systemName: "house.fill")
        playlists.tabTitle = "Playlists"
        playlists.tabImage = UIImage(systemName: "music.note.list")
        downloads.tabTitle = "Downloads"
        downloads.tabImage = UIImage(systemName: "arrow.down.circle.fill")
        refresh()

        let tabs = CPTabBarTemplate(templates: [home, playlists, downloads])
        tabs.delegate = self
        interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
    }

    // MARK: Lists

    private var maxItems: Int { max(min(CPListTemplate.maximumItemCount, 100), 2) }

    private func refresh() {
        let lib = Library.shared

        let liked = CPListItem(text: "Liked songs", detailText: "\(lib.liked.count) songs",
                               image: symbolImage("heart.fill", UIColor(hex: 0x4338CA)))
        liked.accessoryType = .disclosureIndicator
        liked.handler = { [weak self] _, done in
            self?.pushTracks(title: "Liked songs", tracks: Library.shared.liked)
            done()
        }
        var homeSections = [CPListSection(items: [liked])]
        let recent = Array(lib.recent.prefix(maxItems - 1))
        if !recent.isEmpty {
            homeSections.append(CPListSection(items: trackItems(recent, source: "Recently played"),
                                              header: "Recently played", sectionIndexTitle: nil))
        }
        home.updateSections(homeSections)

        let playlistItems: [CPListItem] = lib.playlists.prefix(maxItems).map { p in
            let item = CPListItem(text: p.name, detailText: "\(p.tracks.count) songs",
                                  image: symbolImage("music.note.list", UIColor(hex: Theme.tiles[p.colorIndex % Theme.tiles.count])))
            item.accessoryType = .disclosureIndicator
            if let first = p.tracks.first { loadImage(first.artwork(size: 200), into: item) }
            let id = p.id
            item.handler = { [weak self] _, done in
                if let p = Library.shared.playlist(id) { self?.pushTracks(title: p.name, tracks: p.tracks) }
                done()
            }
            return item
        }
        playlists.updateSections([CPListSection(items: playlistItems)])
        playlists.emptyViewTitleVariants = ["No playlists yet"]
        playlists.emptyViewSubtitleVariants = ["Create playlists on your iPhone"]

        downloads.updateSections([CPListSection(items: trackItems(Array(lib.downloaded.prefix(maxItems)), source: "Downloaded"))])
        downloads.emptyViewTitleVariants = ["No downloads"]
        downloads.emptyViewSubtitleVariants = ["Download songs on your iPhone to play them offline"]
    }

    private func trackItems(_ tracks: [Track], source: String) -> [CPListItem] {
        let currentID = Player.shared.current?.id
        return tracks.enumerated().map { i, t in
            let item = CPListItem(text: t.title, detailText: t.artist, image: placeholder())
            item.isPlaying = t.id == currentID
            item.handler = { [weak self] _, done in
                Player.shared.play(tracks, startAt: i, from: source)
                self?.showNowPlaying()
                done()
            }
            loadImage(t.artwork(size: 200), into: item)
            return item
        }
    }

    private func pushTracks(title: String, tracks: [Track]) {
        let list = CPListTemplate(title: title, sections: [])
        var items: [CPListItem] = []
        if !tracks.isEmpty {
            let shuffle = CPListItem(text: "Shuffle play", detailText: "\(tracks.count) songs",
                                     image: UIImage(systemName: "shuffle"))
            shuffle.handler = { [weak self] _, done in
                Player.shared.shufflePlay(tracks, from: title)
                self?.showNowPlaying()
                done()
            }
            items.append(shuffle)
        }
        items += trackItems(Array(tracks.prefix(maxItems - 1)), source: title)
        list.updateSections([CPListSection(items: items)])
        list.emptyViewTitleVariants = ["No songs"]
        interface?.pushTemplate(list, animated: true, completion: nil)
    }

    private func showNowPlaying() {
        guard let interface else { return }
        let nowPlaying = CPNowPlayingTemplate.shared
        if interface.topTemplate !== nowPlaying {
            interface.pushTemplate(nowPlaying, animated: true, completion: nil)
        }
    }

    // MARK: Images

    private func placeholder() -> UIImage? {
        symbolImage("music.note", UIColor(hex: 0x26262D))
    }

    private func symbolImage(_ name: String, _ color: UIColor) -> UIImage? {
        let size = CGSize(width: 80, height: 80)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let config = UIImage.SymbolConfiguration(pointSize: 32, weight: .semibold)
            if let symbol = UIImage(systemName: name, withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                let r = CGRect(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2,
                               width: symbol.size.width, height: symbol.size.height)
                symbol.draw(in: r)
            }
        }
    }

    private func loadImage(_ url: URL?, into item: CPListItem) {
        guard let url else { return }
        if let cached = imageCache[url] {
            item.setImage(cached)
            return
        }
        Task { [weak self] in
            guard let result = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: result.0) else { return }
            self?.imageCache[url] = image
            item.setImage(image)
        }
    }
}
