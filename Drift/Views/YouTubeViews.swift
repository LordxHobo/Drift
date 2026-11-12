import SwiftUI
import WebKit

extension Color {
    /// The YouTube viewer's color (Drift's own accent stays for music).
    static let ytRed = Color(red: 1, green: 0, blue: 0.2)
}

/// Plays a video (then the ones after it, like YouTube's autoplay).
@MainActor func playVideo(_ v: YTVideo, after: [YTVideo] = []) {
    let list = [v] + after.filter { $0.id != v.id && !$0.live }
    Player.shared.play(list.map(\.track), startAt: 0, from: v.channel.isEmpty ? "YouTube" : v.channel)
}

private func timeText(_ s: Double) -> String {
    let t = Int(max(0, s))
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}

// MARK: The switch and signing in

/// In the drawer: music or the YouTube viewer (signing in the first time).
struct YTDrawerToggle: View {
    var close: () -> Void
    private var yt: YTViewer { .shared }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.ytRed, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("YouTube viewer").font(.system(size: 15, weight: .bold))
                Text(yt.signedIn ? "Swap Drift to videos" : "Sign in to watch videos")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
            Toggle("YouTube viewer", isOn: Binding(get: { yt.on }, set: { on in
                yt.turn(on)
                if on == yt.on { close() }
            }))
            .labelsHidden()
            .tint(.ytRed)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Google's own sign-in page, presented as Safari (Google refuses apps' web views) with passkeys hidden
/// (or it asks for a security key first). Done once YouTube's cookies are there.
struct YTSignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var web = false

    var body: some View {
        NavigationStack {
            Group {
                if web {
                    YTSignInWeb { dismiss() }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.white)
                                .frame(width: 60, height: 60)
                                .background(Color.ytRed, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            Text("Sign in to watch YouTube").font(.system(size: 24, weight: .heavy))
                            Text("The viewer uses your own YouTube account, so YouTube sees a signed-in viewer, and your subscriptions, Watch later and history come with it.")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.text2)
                            Label("Use an account you don't mind Drift using. Each phone or computer signs in on its own.", systemImage: "info.circle")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.muted)
                                .padding(12)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                            Button { web = true } label: {
                                Text("Sign in with Google")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.black)
                                    .frame(maxWidth: .infinity, minHeight: 52)
                                    .background(.white, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            Button("Not now") { dismiss() }
                                .frame(maxWidth: .infinity)
                                .foregroundStyle(Theme.muted)
                        }
                        .padding(22)
                    }
                }
            }
            .background(Theme.bg)
            .navigationTitle(web ? "Sign in" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

private struct YTSignInWeb: UIViewRepresentable {
    var done: () -> Void

    static let hideScript = """
    (() => {
      try { Object.defineProperty(window, 'PublicKeyCredential', { value: undefined, configurable: true }) } catch (e) {}
      try {
        const refuse = () => Promise.reject(new DOMException('Not supported here', 'NotSupportedError'))
        if (navigator.credentials) {
          Object.defineProperty(navigator.credentials, 'get', { value: refuse, configurable: true })
          Object.defineProperty(navigator.credentials, 'create', { value: refuse, configurable: true })
        }
      } catch (e) {}
    })()
    """

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: Self.hideScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = YTViewer.signInUA
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2F")!))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let done: () -> Void
        private var finished = false
        init(done: @escaping () -> Void) { self.done = done }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !finished, let host = webView.url?.host, host.hasSuffix("youtube.com") else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                Task { @MainActor in
                    guard !self.finished, YTViewer.shared.signedIn(with: cookies) else { return }
                    self.finished = true
                    YTViewer.shared.turn(true)
                    self.done()
                }
            }
        }
    }
}

// MARK: Pieces

private struct VideoCard: View {
    let video: YTVideo
    let list: [YTVideo]

    var body: some View {
        NavigationLink(value: Route.ytWatch(video.id)) {
            VStack(alignment: .leading, spacing: 10) {
                Thumb(video: video)
                VStack(alignment: .leading, spacing: 3) {
                    Text(video.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text([video.channel, video.views, video.published].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
            }
            .padding(.bottom, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded { playVideo(video, after: Array(list.drop { $0.id != video.id }.dropFirst())) })
    }
}

private struct Thumb: View {
    let video: YTVideo
    var corner: CGFloat = 0

    var body: some View {
        Theme.surface
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                AsyncImage(url: video.thumbnail) { img in img.resizable().scaledToFill() } placeholder: { Color.clear }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if video.live || video.duration != nil {
                    Text(video.live ? "LIVE" : timeText(video.duration ?? 0))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(video.live ? Color.ytRed : .black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
            }
    }
}

private struct SmallVideoRow: View {
    let video: YTVideo
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Thumb(video: video, corner: 8).frame(width: 150)
            VStack(alignment: .leading, spacing: 3) {
                Text(video.title).font(.system(size: 13, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                Text(video.channel).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                Text([video.views, video.published].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

private struct Round: View {
    let url: URL?
    let size: CGFloat
    var body: some View {
        AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { Theme.surface2 }
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}

/// Loads something from YouTube: the value, why it failed, and a way to try again.
@MainActor @Observable
private final class YTLoad<T> {
    var value: T?
    var error: String?
    private let load: () async throws -> T
    init(_ load: @escaping () async throws -> T) { self.load = load }
    func run() async {
        error = nil
        do { value = try await load() } catch { self.error = error.localizedDescription }
    }
}

private struct VideoListView<Header: View>: View {
    let title: String
    let videos: [YTVideo]?
    let error: String?
    let empty: String
    var reload: () async -> Void
    @ViewBuilder var header: Header

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                if let videos {
                    if videos.isEmpty {
                        Text(empty).foregroundStyle(Theme.muted).padding(20)
                    }
                    ForEach(videos) { VideoCard(video: $0, list: videos) }
                } else if let error {
                    VStack(spacing: 10) {
                        Text(error).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                        Button("Try again") { Task { await reload() } }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(30)
                }
            }
        }
        .refreshable { await reload() }
        .navigationTitle(title)
        .background(Theme.bg)
    }
}

// MARK: Tabs

struct YTHomeView: View {
    @State private var load = YTLoad { try await YTViewer.shared.feed(.subscriptions) }
    @State private var chip = 0
    private var ui: UIState { .shared }

    var body: some View {
        let list = load.value?.filter { v in chip == 1 ? (v.duration ?? 0) >= 1200 : chip == 2 ? v.live : true }
        VideoListView(title: "Home", videos: list, error: load.error, empty: "Nothing new from your subscriptions.", reload: load.run) {
            HStack(spacing: 8) {
                ForEach(Array(["All", "20 min+", "Live"].enumerated()), id: \.offset) { i, label in
                    Button { chip = i } label: {
                        Text(label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(chip == i ? Color.black : Theme.text)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(chip == i ? Theme.text : Theme.surface2, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { ui.showDrawer = true } label: {
                    Round(url: YTViewer.shared.account?.avatar, size: 32)
                }
                .accessibilityLabel("Menu")
            }
        }
        .task { if load.value == nil { await load.run() } }
        .task { _ = await YTViewer.shared.loadAccount() }
    }
}

struct YTFeedView: View {
    let feed: YTFeed
    @State private var load: YTLoad<[YTVideo]>
    init(feed: YTFeed) {
        self.feed = feed
        _load = State(initialValue: YTLoad { try await YTViewer.shared.feed(feed) })
    }
    var body: some View {
        VideoListView(title: feed.title, videos: load.value, error: load.error, empty: "Nothing here yet.", reload: load.run) { EmptyView() }
            .task { if load.value == nil { await load.run() } }
    }
}

struct YTSearchView: View {
    @State private var q = ""
    @State private var results: [YTVideo]?
    @State private var error: String?
    @State private var asked = false

    var body: some View {
        VideoListView(title: "Search", videos: asked ? results : [], error: error,
                      empty: asked ? "No videos found." : "Search YouTube for videos.", reload: search) { EmptyView() }
            .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search YouTube")
            .onSubmit(of: .search) { Task { await search() } }
    }

    private func search() async {
        let text = q.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        asked = true
        results = nil
        error = nil
        do { results = try await YTViewer.shared.search(text) } catch { self.error = error.localizedDescription }
    }
}

struct YTSubscriptionsView: View {
    @State private var load = YTLoad { try await YTViewer.shared.channels() }
    var body: some View {
        List {
            if let list = load.value {
                if list.isEmpty { Text("Channels you subscribe to on YouTube show up here.").foregroundStyle(Theme.muted) }
                ForEach(list) { c in
                    NavigationLink(value: Route.ytChannel(c.id)) {
                        HStack(spacing: 12) {
                            Round(url: c.avatar, size: 42)
                            Text(c.name).lineLimit(1)
                            Spacer()
                            if c.fresh { Circle().fill(Color.ytRed).frame(width: 8, height: 8) }
                        }
                    }
                    .listRowBackground(Theme.bg)
                }
            } else if let e = load.error {
                Text(e).foregroundStyle(Theme.muted)
            } else {
                ProgressView()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Subscriptions")
        .refreshable { await load.run() }
        .task { if load.value == nil { await load.run() } }
    }
}

struct YTLibraryView: View {
    private var yt: YTViewer { .shared }
    var body: some View {
        List {
            HStack(spacing: 14) {
                Round(url: yt.account?.avatar, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(yt.account?.name ?? "YouTube").font(.system(size: 18, weight: .bold))
                    if let h = yt.account?.handle, !h.isEmpty { Text(h).font(.system(size: 13)).foregroundStyle(Theme.muted) }
                }
            }
            .listRowBackground(Theme.bg)
            if let id = yt.account?.channelId {
                row("Your channel", "person.crop.square", .ytChannel(id))
            }
            row("History", "clock.arrow.circlepath", .ytFeed(.history))
            row("Watch later", "clock", .ytFeed(.watchLater))
            row("Liked videos", "hand.thumbsup", .ytFeed(.liked))
            Button("Sign out of YouTube", role: .destructive) { yt.signOut() }
                .listRowBackground(Theme.bg)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Library")
        .task { _ = await yt.loadAccount() }
    }

    private func row(_ title: String, _ icon: String, _ route: Route) -> some View {
        NavigationLink(value: route) {
            Label(title, systemImage: icon).foregroundStyle(Theme.text)
        }
        .tint(.ytRed)
        .listRowBackground(Theme.bg)
    }
}

struct YTChannelView: View {
    let id: String
    @State private var load: YTLoad<(YTChannel, [YTVideo])>
    @State private var subscribed: Bool?
    init(id: String) {
        self.id = id
        _load = State(initialValue: YTLoad { try await YTViewer.shared.channel(id) })
    }
    var body: some View {
        VideoListView(title: load.value?.0.name ?? "", videos: load.value?.1, error: load.error, empty: "No videos.", reload: load.run) {
            if let c = load.value?.0 {
                HStack(spacing: 14) {
                    Round(url: c.avatar, size: 60)
                    Text(c.name).font(.system(size: 20, weight: .heavy)).lineLimit(2)
                    Spacer()
                    if YTViewer.shared.account?.channelId == id {
                        Text("Your channel").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    } else {
                        SubscribeButton(channelId: id, subscribed: subscribed ?? false) { subscribed = $0 }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { if load.value == nil { await load.run() } }
    }
}

private struct SubscribeButton: View {
    let channelId: String
    let subscribed: Bool
    var changed: (Bool) -> Void
    @State private var busy = false
    var body: some View {
        Button {
            busy = true
            Task {
                if (try? await YTViewer.shared.subscribe(channelId, !subscribed)) != nil { changed(!subscribed) }
                busy = false
            }
        } label: {
            Text(subscribed ? "Subscribed" : "Subscribe")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(subscribed ? Theme.text : Color.black)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background(subscribed ? Theme.surface2 : Theme.text, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy || channelId.isEmpty)
    }
}

// MARK: Watching

struct YTWatchView: View {
    let id: String
    @State private var details: YTVideoDetails?
    @State private var subscribed: Bool?
    @State private var more = false
    @State private var fullScreen = false
    @State private var notice: String?
    private var player: Player { .shared }
    private var settings: AppSettings { .shared }

    var body: some View {
        let t = player.current?.id == id ? player.current : nil
        VStack(spacing: 0) {
            GeometryReader { geo in
                if let t {
                    YTPlayerView(track: t, width: geo.size.width) { fullScreen = true }
                } else {
                    ZStack { Color.black; ProgressView().tint(.white) }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(details?.title ?? t?.title ?? "").font(.system(size: 18, weight: .heavy))
                    if let d = details {
                        Button { more.toggle() } label: {
                            Text([d.views, d.published].filter { !$0.isEmpty }.joined(separator: " · ") + (d.description.isEmpty ? "" : (more ? "  · less" : "  · more")))
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                        .buttonStyle(.plain)
                        if more { Text(d.description).font(.system(size: 13)).foregroundStyle(Theme.text2).textSelection(.enabled) }
                        HStack(spacing: 10) {
                            NavigationLink(value: Route.ytChannel(d.channel.id)) {
                                HStack(spacing: 10) {
                                    Round(url: d.channel.avatar, size: 36)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(d.channel.name).font(.system(size: 15, weight: .bold)).lineLimit(1)
                                        Text(d.subscribers).font(.system(size: 12)).foregroundStyle(Theme.muted)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(d.channel.id.isEmpty)
                            Spacer()
                            if YTViewer.shared.account?.channelId != d.channel.id {
                                SubscribeButton(channelId: d.channel.id, subscribed: subscribed ?? d.subscribed) { subscribed = $0 }
                            }
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            action("Like", "hand.thumbsup") { try await YTViewer.shared.like(id); return "Liked" }
                            action("Watch later", "clock") { try await YTViewer.shared.watchLater(id); return "Saved to Watch later" }
                            if let t {
                                chip("Download", "arrow.down.circle") { DownloadManager.shared.download(t); notice = "Downloading" }
                                if SocialStore.shared.me != nil { chip("Send", "paperplane") { UIState.shared.sendTrack = t } }
                            }
                            Button { settings.skipSponsors.toggle() } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(settings.skipSponsors ? Color(red: 0, green: 0.83, blue: 0) : Theme.muted).frame(width: 10, height: 10)
                                    Text("SponsorBlock \(settings.skipSponsors ? "on" : "off")").font(.system(size: 13, weight: .semibold))
                                }
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .background(settings.skipSponsors ? Color(red: 0, green: 0.83, blue: 0).opacity(0.22) : Theme.surface2, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    YTCommentsSection(videoId: id, start: details?.commentsToken, loaded: details != nil)
                    Text("Up next").font(.system(size: 16, weight: .heavy)).padding(.top, 6)
                    ForEach(details?.related.prefix(20).map { $0 } ?? []) { v in
                        Button {
                            if let rel = details?.related { playVideo(v, after: Array(rel.drop { $0.id != v.id }.dropFirst())) }
                            UIState.shared.openVideo = v.id
                        } label: { SmallVideoRow(video: v) }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
                .padding(.bottom, 80)
            }
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.bottom, 100)
                    .task {
                        try? await Task.sleep(for: .seconds(2))
                        self.notice = nil
                    }
            }
        }
        .fullScreenCover(isPresented: $fullScreen) {
            if let t = player.current { EpisodeVideoFullScreen(track: t) }
        }
        .task(id: id) {
            details = try? await YTViewer.shared.video(id)
            // Opened from a link, history or the mini player while something else plays: start this one.
            if let d = details, player.current?.id != id {
                playVideo(YTVideo(id: id, title: d.title, channel: d.channel.name, channelId: d.channel.id,
                                  thumbnail: URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"), duration: nil,
                                  views: d.views, published: d.published, live: false), after: d.related)
            }
        }
    }

    private func action(_ label: String, _ icon: String, _ run: @escaping () async throws -> String) -> some View {
        chip(label, icon) {
            Task {
                do { notice = try await run() } catch { notice = error.localizedDescription }
            }
        }
    }

    private func chip(_ label: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(label, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Theme.surface2, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The video with YouTube-style controls: tap to show them, double-tap a side to jump 10 s, and a timeline
/// with SponsorBlock's parts on it.
private struct YTPlayerView: View {
    let track: Track
    let width: CGFloat
    var onFullScreen: () -> Void
    @State private var controls = true
    @State private var drag: Double?
    private var player: Player { .shared }

    var body: some View {
        ZStack {
            EpisodeVideoView(track: track, width: width, onFullScreen: onFullScreen)
            // Taps (below the quality and full-screen buttons, which stay tappable).
            Color.clear
                .contentShape(Rectangle())
                .padding(.top, 48)
                .onTapGesture(count: 2, coordinateSpace: .local) { p in
                    player.seek(to: p.x < width / 2 ? max(0, player.currentTime - 10) : player.currentTime + 10)
                }
                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { controls.toggle() } }
            if controls {
                HStack(spacing: 32) {
                    roundButton("gobackward.10", 44) { player.seek(to: max(0, player.currentTime - 10)) }
                    roundButton(player.isPlaying ? "pause.fill" : "play.fill", 58) { player.togglePlay() }
                    roundButton("goforward.10", 44) { player.seek(to: player.currentTime + 10) }
                }
                VStack(spacing: 2) {
                    Spacer()
                    HStack {
                        Text("\(timeText(drag ?? player.currentTime)) / \(timeText(player.duration))")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    timeline(thin: false)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .background(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).frame(height: 70)
                }
            } else {
                VStack { Spacer(); timeline(thin: true) }
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .task(id: controls && player.isPlaying) {
            guard controls, player.isPlaying else { return }
            try? await Task.sleep(for: .seconds(3.5))
            withAnimation { controls = false }
        }
    }

    private func roundButton(_ icon: String, _ size: CGFloat, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: icon)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
    }

    /// The SponsorBlock extension's colors, so the parts look the same everywhere.
    private func color(_ category: String) -> Color {
        switch category {
        case "sponsor": Color(red: 0, green: 0.83, blue: 0)
        case "selfpromo": Color(red: 1, green: 1, blue: 0)
        case "interaction": Color(red: 0.8, green: 0, blue: 1)
        case "intro": Color(red: 0, green: 1, blue: 1)
        case "outro": Color(red: 0.01, green: 0.01, blue: 0.93)
        default: Color(red: 1, green: 0.6, blue: 0)
        }
    }

    private func timeline(thin: Bool) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let d = max(player.duration, 1)
            let fraction = min(1, max(0, (drag ?? player.currentTime) / d))
            let h: CGFloat = thin ? 3 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3)).frame(height: h)
                Capsule().fill(Color.ytRed).frame(width: w * fraction, height: h)
                if AppSettings.shared.skipSponsors {
                    ForEach(Array(player.shownSegments.enumerated()), id: \.offset) { _, s in
                        Rectangle()
                            .fill(color(s.category).opacity(0.9))
                            .frame(width: max(2, w * (min(s.range.upperBound, d) - s.range.lowerBound) / d), height: h)
                            .offset(x: w * s.range.lowerBound / d)
                    }
                }
                if !thin {
                    Circle().fill(Color.ytRed).frame(width: 13, height: 13).offset(x: w * fraction - 6.5)
                }
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(thin ? nil : DragGesture(minimumDistance: 0)
                .onChanged { v in drag = min(d, max(0, v.location.x / w * d)) }
                .onEnded { v in
                    player.seek(to: min(d, max(0, v.location.x / w * d)))
                    drag = nil
                })
        }
        .frame(height: thin ? 3 : 22)
        .accessibilityElement()
        .accessibilityLabel("Video position")
        .accessibilityValue("\(timeText(player.currentTime)) of \(timeText(player.duration))")
    }
}

// MARK: Comments

private struct YTCommentsSection: View {
    let videoId: String
    let start: String?
    let loaded: Bool
    @State private var newest = false
    @State private var newestToken: String?
    @State private var postParams: String?
    @State private var list: [YTComment]?
    @State private var more: String?
    @State private var error: String?
    @State private var draft = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Comments").font(.system(size: 16, weight: .heavy)).padding(.trailing, 4)
                sortChip("Top", !newest) { newest = false }
                if newestToken != nil { sortChip("Newest", newest) { newest = true } }
            }
            if postParams != nil {
                HStack {
                    TextField("Add a comment…", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                    if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button { post() } label: { Image(systemName: "paperplane.fill").foregroundStyle(Color.ytRed) }
                            .disabled(busy)
                            .accessibilityLabel("Comment")
                    }
                }
            }
            if let list {
                if list.isEmpty { Text(error ?? "No comments.").font(.system(size: 13)).foregroundStyle(Theme.muted) }
                ForEach(list) { CommentRow(comment: $0) }
                if let more, !list.isEmpty {
                    Button("More comments") { Task { await loadMore(more) } }
                        .font(.system(size: 13, weight: .semibold))
                }
            } else if loaded {
                ProgressView()
            }
        }
        .task(id: "\(start ?? "")|\(newest)") { await load() }
    }

    private func sortChip(_ label: String, _ on: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? Color.black : Theme.text)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(on ? Theme.text : Theme.surface2, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        guard let token = newest ? newestToken : start else {
            if loaded { list = [] }
            return
        }
        list = nil
        do {
            let page = try await YTViewer.shared.comments(token)
            list = page.comments
            more = page.more
            if let n = page.newest { newestToken = n }
            if let p = page.postParams { postParams = p }
        } catch {
            self.error = error.localizedDescription
            list = []
        }
    }

    private func loadMore(_ token: String) async {
        guard let page = try? await YTViewer.shared.comments(token) else { return }
        list = (list ?? []) + page.comments
        more = page.more
    }

    private func post() {
        guard let params = postParams else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        Task {
            if (try? await YTViewer.shared.postComment(params: params, text: text)) != nil {
                let a = YTViewer.shared.account
                list = [YTComment(id: "mine-\(Date().timeIntervalSince1970)", author: (a?.handle.isEmpty == false ? a?.handle : a?.name) ?? "You",
                                  authorAvatar: a?.avatar, authorChannelId: a?.channelId, text: text, published: "just now",
                                  likes: "", replies: 0, pinned: false, byCreator: false)] + (list ?? [])
                draft = ""
            }
            busy = false
        }
    }
}

private struct CommentRow: View {
    let comment: YTComment
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Round(url: comment.authorAvatar, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if comment.pinned { Text("Pinned").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.muted) }
                    Text(comment.author)
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, comment.byCreator ? 6 : 0)
                        .background(comment.byCreator ? Theme.surface2 : .clear, in: Capsule())
                    Text(comment.published).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Text(comment.text).font(.system(size: 14)).textSelection(.enabled)
                HStack(spacing: 6) {
                    Image(systemName: "hand.thumbsup").font(.system(size: 11))
                    Text(comment.likes).font(.system(size: 11))
                    if comment.replies > 0 { Text(comment.replies == 1 ? "1 reply" : "\(comment.replies) replies").font(.system(size: 11)) }
                }
                .foregroundStyle(Theme.muted)
            }
        }
    }
}
