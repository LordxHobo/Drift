import SwiftUI
import UIKit
import WebKit

/// Videos from the YouTube viewer, played by YouTube's own mobile player (like ProTube does), in a web view
/// signed in as you: it starts at once, picks the quality itself and gets past YouTube's checks. Drift's own
/// controls, timeline, SponsorBlock and queue sit on top; the page shows only the video, with ads taken out
/// of YouTube's answers (and any left skipped) and ad servers blocked.
@Observable @MainActor
final class YTWebPlayer {
    static let shared = YTWebPlayer()

    /// The video loaded, and where it is.
    private(set) var videoID: String?
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    private(set) var playing = false
    private(set) var buffering = false
    /// Has a picture (the first frame came).
    private(set) var ready = false
    /// An ad is being skipped.
    private(set) var ad = false
    /// The qualities YouTube offers for it (heights), and the one asked for.
    private(set) var heights: [Int] = []
    private(set) var height: Int?

    /// What the player hears: new state, the end, or a video YouTube's player couldn't play.
    @ObservationIgnored var onState: (() -> Void)?
    @ObservationIgnored var onEnded: (() -> Void)?
    @ObservationIgnored var onError: ((String) -> Void)?

    @ObservationIgnored let web: WKWebView
    @ObservationIgnored private let bridge = Bridge()
    @ObservationIgnored private var endedReported = false
    @ObservationIgnored private var loadedAt = Date()
    @ObservationIgnored private var qualitySet = false
    @ObservationIgnored private var rate: Float = 1
    @ObservationIgnored private var errorReported = false
    @ObservationIgnored private var stallCheck: Task<Void, Never>?

    private init() {
        Self.made = true
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        config.allowsAirPlayForMediaPlayback = true
        config.websiteDataStore = .default()   // signed in (YTSignInSheet signs in here)
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.add(bridge, name: "drift")
        config.userContentController = content
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), configuration: config)
        web.customUserAgent = YTViewer.signInUA
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isUserInteractionEnabled = false   // Drift's controls take the taps
        web.navigationDelegate = bridge
        bridge.owner = self
        Self.blockAds(in: content)
        // In the background iOS may pause it: ask it to go on (the page keeps it going after that).
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { YTWebPlayer.shared.keepPlaying() }
        }
    }

    // MARK: Playing

    func load(_ id: String, at: Double, autoplay: Bool) {
        videoID = id
        time = at
        duration = 0
        playing = false
        buffering = true
        ready = false
        ad = false
        heights = []
        endedReported = false
        errorReported = false
        qualitySet = false
        loadedAt = Date()
        var hash = "drift-at=\(Int(at))"
        if !autoplay { hash += "&drift-paused" }
        guard let url = URL(string: "https://m.youtube.com/watch?v=\(id)#\(hash)") else { return }
        web.load(URLRequest(url: url))
        YTWebHost.ensureParked()
        // Nothing playing 15 s in (page didn't load, or YouTube's player gave up): let the player fall back.
        stallCheck?.cancel()
        stallCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled, self.videoID == id, self.duration == 0, !self.ad, autoplay else { return }
            self.reportError("YouTube's player didn't start")
        }
    }

    func play() { run("__drift.play()") }
    func pause() { run("__drift.pause()") }
    func seek(to t: Double) {
        time = t
        endedReported = false
        run("__drift.seek(\(t))")
    }
    func setRate(_ r: Float) {
        rate = r
        run("__drift.rate(\(r))")
    }

    /// A quality (height), from the menu: remembered for the next videos too.
    func choose(_ h: Int) {
        AppSettings.shared.videoQuality = h
        height = h
        run("__drift.quality('\(Self.label(h))')")
    }

    /// Made yet (it's only made for the first video, not for music).
    private static var made = false

    /// Unloads it, if it was ever used.
    static func stopIfUsed() {
        if made { shared.stop() }
    }

    /// Unloads it (music plays, or the video was closed).
    func stop() {
        guard videoID != nil else { return }
        videoID = nil
        playing = false
        ready = false
        stallCheck?.cancel()
        web.load(URLRequest(url: URL(string: "about:blank")!))
    }

    private func keepPlaying() {
        guard videoID != nil, playing || buffering else { return }
        for delay in [0.3, 1.0, 2.5] {
            Task {
                try? await Task.sleep(for: .seconds(delay))
                self.run("__drift.play()")
            }
        }
    }

    private func run(_ js: String) {
        web.evaluateJavaScript("window.__drift && \(js)", completionHandler: nil)
    }

    private func reportError(_ text: String) {
        guard !errorReported else { return }
        errorReported = true
        onError?(text)
    }

    fileprivate func received(_ m: [String: Any]) {
        guard (m["k"] as? String) == "state", let id = videoID else { return }
        // YouTube went on to another video by itself: Drift picks what's next.
        if let v = m["v"] as? String, !v.isEmpty, v != id {
            run("__drift.pause()")
            return
        }
        let isAd = m["ad"] as? Bool ?? false
        ad = isAd
        let t = m["t"] as? Double ?? 0
        let d = m["d"] as? Double ?? 0
        if !isAd, t >= 0 { time = t }
        if !isAd, d > 0 {
            duration = d
            if !ready { ready = true }
            stallCheck?.cancel()
        }
        playing = m["playing"] as? Bool ?? false
        buffering = m["buffering"] as? Bool ?? false
        if playing, !qualitySet {
            qualitySet = true
            let h = AppSettings.shared.dataSaver ? 360 : AppSettings.shared.videoQuality
            height = min(h, 2160)
            run("__drift.quality('\(Self.label(h))')")
            if rate != 1 { setRate(rate) }
            readQualities()
        }
        if let e = m["error"] as? String, !e.isEmpty, duration == 0 { reportError(e) }
        if (m["ended"] as? Bool) == true, !endedReported {
            endedReported = true
            onEnded?()
        }
        onState?()
    }

    private func readQualities() {
        web.evaluateJavaScript("window.__drift ? __drift.qualities() : []") { [weak self] result, _ in
            let labels = result as? [String] ?? []
            Task { @MainActor in
                guard let self else { return }
                self.heights = labels.compactMap(Self.height(of:)).sorted()
            }
        }
    }

    /// YouTube's names for the qualities.
    static func label(_ h: Int) -> String {
        switch h {
        case 2160...: "hd2160"
        case 1440...: "hd1440"
        case 1080...: "hd1080"
        case 720...: "hd720"
        case 480...: "large"
        case 360...: "medium"
        case 240...: "small"
        default: "tiny"
        }
    }

    static func height(of label: String) -> Int? {
        ["hd2160": 2160, "hd1440": 1440, "hd1080": 1080, "hd720": 720, "large": 480, "medium": 360, "small": 240, "tiny": 144][label]
    }

    // MARK: Ad servers

    private static func blockAds(in content: WKUserContentController) {
        let filters = [
            "^https?://[^/]*doubleclick[.]net/",
            "^https?://[^/]*googlesyndication[.]com/",
            "^https?://[^/]*googleadservices[.]com/",
            "^https?://[^/]*google-analytics[.]com/",
            "^https?://[^/]*youtube[.]com/pagead/",
            "^https?://[^/]*youtube[.]com/api/stats/ads",
            "^https?://[^/]*youtube[.]com/ptracking",
            "^https?://[^/]*youtube[.]com/get_midroll_",
            "^https?://[^/]*youtube[.]com/pcs/activeview",
        ]
        let rules = filters.map { #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"# }
        let list = "[" + rules.joined(separator: ",") + "]"
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "drift-ads", encodedContentRuleList: list) { compiled, _ in
            guard let compiled else { return }
            Task { @MainActor in content.add(compiled) }
        }
    }

    // MARK: The page script

    static let script = #"""
(() => {
  if (window.__drift) return;
  const D = window.__drift = {};
  const post = (m) => {
    try { window.webkit.messageHandlers.drift.postMessage(m) } catch (e) {}
    try { window.DriftAndroid.post(JSON.stringify(m)) } catch (e) {}
  };
  const hash = location.hash || '';
  const startMatch = hash.match(/drift-at=([0-9.]+)/);
  const startAt = startMatch ? parseFloat(startMatch[1]) : 0;
  let want = hash.indexOf('drift-paused') < 0;
  let rate = 1;
  let started = false;
  let adNow = false;

  // Always "on screen", so the video keeps playing while the app is in the background (like ProTube).
  try {
    Object.defineProperty(Document.prototype, 'hidden', { get: () => false, configurable: true });
    Object.defineProperty(Document.prototype, 'visibilityState', { get: () => 'visible', configurable: true });
    Object.defineProperty(Document.prototype, 'webkitHidden', { get: () => false, configurable: true });
    Object.defineProperty(Document.prototype, 'webkitVisibilityState', { get: () => 'visible', configurable: true });
  } catch (e) {}
  for (const type of ['visibilitychange', 'webkitvisibilitychange', 'pagehide', 'freeze']) {
    window.addEventListener(type, (e) => e.stopImmediatePropagation(), true);
    document.addEventListener(type, (e) => e.stopImmediatePropagation(), true);
  }

  // Ads, step 1: taken out of YouTube's answers before its player reads them.
  const AD_KEYS = ['adPlacements', 'adSlots', 'playerAds', 'adBreakHeartbeatParams', 'adBreakParams'];
  const prune = (o, depth) => {
    depth = depth || 0;
    if (!o || typeof o !== 'object' || depth > 4) return o;
    for (const k of AD_KEYS) if (k in o) { try { delete o[k] } catch (e) {} }
    if (o.playerResponse) prune(o.playerResponse, depth + 1);
    if (Array.isArray(o)) for (const x of o) prune(x, depth + 1);
    return o;
  };
  const parse = JSON.parse;
  JSON.parse = function () { return prune(parse.apply(this, arguments)) };
  const json = Response.prototype.json;
  Response.prototype.json = function () { return json.call(this).then((o) => prune(o)) };
  let initial;
  try {
    Object.defineProperty(window, 'ytInitialPlayerResponse', {
      configurable: true, get: () => initial, set: (v) => { initial = prune(v) },
    });
  } catch (e) {}

  // Only the video, filling the page (Drift draws its own controls over it).
  const css = `
    html, body { background: #000 !important; overflow: hidden !important; }
    body * { visibility: hidden !important; }
    #player-container-id, #player-container-id *, #player, #player *, .html5-video-player, .html5-video-player * { visibility: visible !important; }
    #player-container-id, #player { position: fixed !important; inset: 0 !important; width: 100vw !important; height: 100vh !important; max-height: none !important; margin: 0 !important; padding: 0 !important; z-index: 2147483647 !important; background: #000 !important; transform: none !important; }
    .html5-video-player, .html5-video-container { position: absolute !important; inset: 0 !important; width: 100% !important; height: 100% !important; }
    video { position: absolute !important; left: 0 !important; top: 0 !important; width: 100% !important; height: 100% !important; object-fit: contain !important; }
    .ytp-chrome-top, .ytp-chrome-bottom, .player-controls-content, .player-controls-background, .player-controls-top, .player-controls-middle, .player-controls-bottom, .ytp-unmute, .ytp-ce-element, .ytp-cards-teaser, .ytp-pause-overlay, .ytp-spinner, .ytp-gradient-top, .ytp-gradient-bottom, .ytm-autonav-bar, .ytp-paid-content-overlay, .ytp-endscreen-content, .videowall-endscreen, .ytp-ad-module, .ytp-suggested-action, .ytp-watermark, ytm-custom-control, .player-overlays, .ytp-caption-window-container { display: none !important; }
  `;
  const addStyle = () => {
    const root = document.head || document.documentElement;
    if (!root || document.getElementById('drift-style')) return;
    const s = document.createElement('style');
    s.id = 'drift-style';
    s.textContent = css;
    root.appendChild(s);
  };
  addStyle();
  document.addEventListener('DOMContentLoaded', addStyle);

  const video = () => document.querySelector('#player-container-id video, .html5-video-player video, video');
  const api = () => document.getElementById('movie_player') || document.querySelector('.html5-video-player');
  const id = () => { try { return new URL(location.href).searchParams.get('v') || '' } catch (e) { return '' } };

  // Commands from Drift.
  D.play = () => { want = true; const v = video(); if (v) v.play().catch(() => {}) };
  D.pause = () => { want = false; const v = video(); if (v) v.pause() };
  D.seek = (t) => { const v = video(); if (v) v.currentTime = t; started = true };
  D.rate = (r) => { rate = r; const v = video(); if (v && !adNow) v.playbackRate = r };
  D.quality = (q) => {
    try {
      const p = api();
      if (p && p.setPlaybackQualityRange) p.setPlaybackQualityRange(q, q);
      if (p && p.setPlaybackQuality) p.setPlaybackQuality(q);
    } catch (e) {}
  };
  D.qualities = () => { try { const p = api(); return (p && p.getAvailableQualityLevels && p.getAvailableQualityLevels()) || [] } catch (e) { return [] } };

  // Ads, step 2: any that still play are skipped (sped through, muted, skip button pressed).
  const isAd = () => {
    const p = api();
    return !!((p && (p.classList.contains('ad-showing') || p.classList.contains('ad-interrupting'))) ||
      document.querySelector('.ytp-ad-player-overlay, .ytp-ad-player-overlay-layout'));
  };
  const skipButtons = '.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytp-ad-skip-button-slot button, .ytp-ad-overlay-close-button';

  const tick = () => {
    addStyle();
    const v = video();
    const ad = isAd();
    if (ad) {
      document.querySelectorAll(skipButtons).forEach((b) => { try { b.click() } catch (e) {} });
      if (v) {
        v.muted = true;
        v.playbackRate = 16;
        if (isFinite(v.duration) && v.duration > 0) v.currentTime = v.duration;
        if (v.paused) v.play().catch(() => {});
      }
    } else if (adNow && v) {
      v.muted = false;
      v.playbackRate = rate;
    }
    adNow = ad;
    if (!v) { post({ k: 'state', v: id(), t: 0, d: 0, playing: false, buffering: true, ended: false, ad: ad, error: '' }); return }
    if (!ad) {
      if (v.muted) v.muted = false;
      if (v.playbackRate !== rate) v.playbackRate = rate;
      if (!started && v.readyState >= 1) {
        if (startAt > 1 && v.currentTime < startAt - 2) v.currentTime = startAt;
        started = true;
      }
      // Wanted playing: keep it playing (also when the system paused it in the background).
      if (want && v.paused && !v.ended) v.play().catch(() => {});
      if (!want && !v.paused) v.pause();
    }
    const err = document.querySelector('.ytp-error, ytm-player-error-message-renderer');
    post({
      k: 'state', v: id(),
      t: ad ? -1 : v.currentTime,
      d: ad ? 0 : (isFinite(v.duration) ? v.duration : 0),
      playing: !v.paused && !ad,
      buffering: ad || (!v.paused && v.readyState < 3),
      ended: !ad && v.ended,
      ad: ad,
      error: err ? (err.innerText || 'error').trim().slice(0, 200) : '',
    });
  };
  setInterval(tick, 250);
  document.addEventListener('ended', (e) => { if (e.target && e.target.tagName === 'VIDEO' && !isAd()) { want = false; tick() } }, true);
  document.addEventListener('playing', () => tick(), true);
  document.addEventListener('pause', () => tick(), true);
})();
"""#

    private final class Bridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var owner: YTWebPlayer?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            MainActor.assumeIsolated { owner?.received(body) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated { owner?.reportError(error.localizedDescription) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let e = error as NSError
            guard e.code != NSURLErrorCancelled else { return }
            MainActor.assumeIsolated { owner?.reportError(error.localizedDescription) }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            MainActor.assumeIsolated { owner?.reportError("The video stopped") }
        }
    }
}

/// Where the video is shown: the watch page, the floating video or full screen take it in turns (the last
/// one shown has it); with none on screen it waits, playing, in a tiny view behind the app.
final class YTWebHost: UIView {
    private static var hosts: [Weak] = []
    private static weak var parking: UIView?
    private struct Weak { weak var view: YTWebHost? }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        MainActor.assumeIsolated {
            if window != nil { Self.show(self) } else { Self.hide(self) }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        MainActor.assumeIsolated {
            let web = YTWebPlayer.shared.web
            if web.superview === self { web.frame = bounds }
        }
    }

    @MainActor private static func show(_ host: YTWebHost) {
        hosts.removeAll { $0.view == nil || $0.view === host }
        hosts.append(Weak(view: host))
        move(to: host)
    }

    @MainActor private static func hide(_ host: YTWebHost) {
        hosts.removeAll { $0.view == nil || $0.view === host }
        guard YTWebPlayer.shared.web.superview === host else { return }
        if let next = hosts.last(where: { $0.view?.window != nil })?.view { move(to: next) } else { park() }
    }

    @MainActor private static func move(to host: UIView) {
        let web = YTWebPlayer.shared.web
        guard web.superview !== host else { return }
        web.removeFromSuperview()
        web.frame = host.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(web)
    }

    /// Out of sight but still in the window (so it keeps playing).
    @MainActor static func park() {
        let web = YTWebPlayer.shared.web
        if parking == nil || parking?.window == nil {
            guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
            let v = UIView(frame: CGRect(x: 0, y: 0, width: 160, height: 90))
            v.isUserInteractionEnabled = false
            v.alpha = 0.01
            window.insertSubview(v, at: 0)
            parking = v
        }
        guard let parking, web.superview !== parking else { return }
        web.removeFromSuperview()
        web.frame = parking.bounds
        parking.addSubview(web)
    }

    @MainActor static func ensureParked() {
        if YTWebPlayer.shared.web.superview == nil { park() }
    }
}

/// The video, for SwiftUI.
struct YTWebVideo: UIViewRepresentable {
    func makeUIView(context: Context) -> YTWebHost { YTWebHost(frame: .zero) }
    func updateUIView(_ uiView: YTWebHost, context: Context) {}
}
