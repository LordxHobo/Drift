import Foundation
import UIKit
import WebKit

/// Reads a whole public Spotify playlist (any length) by opening it in a hidden browser.
///
/// Spotify's page asks its own server for the song list. Drift notes that request when the page
/// makes it, then repeats it inside the page for every next page of songs, so it gets the same
/// list a visitor would see, without a Spotify account or developer keys.
@MainActor
final class SpotifyWebReader: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private var webView: WKWebView?
    private var ready: CheckedContinuation<Void, Error>?
    private var gotRequest = false

    /// Captures Spotify's own playlist request ("fetchPlaylist…") as the page makes it.
    private static let captureScript = """
    (() => {
      if (window.__drift) return;
      window.__drift = { req: null };
      const note = (url, init) => {
        try {
          if (window.__drift.req || !url || url.indexOf('pathfinder') < 0) return;
          const body = init && typeof init.body === 'string' ? init.body : null;
          const text = (body || '') + ' ' + url;
          if (!/fetchPlaylist/.test(text)) return;
          const headers = {};
          new Headers((init && init.headers) || {}).forEach((v, k) => { headers[k] = v; });
          window.__drift.req = { url: url, body: body, headers: headers, method: (init && init.method) || (body ? 'POST' : 'GET') };
          window.webkit.messageHandlers.drift.postMessage('ready');
        } catch (e) {}
      };
      const origFetch = window.fetch;
      window.fetch = function (input, init) {
        try {
          const url = typeof input === 'string' ? input : (input && input.url);
          let i = init;
          if (!i && input && typeof input !== 'string') {
            i = { method: input.method, headers: input.headers };
          }
          note(url, i);
        } catch (e) {}
        return origFetch.apply(this, arguments);
      };
    })();
    """

    /// Pages through the playlist with the captured request; returns {name, total, tracks}.
    private static let fetchAllScript = """
    const r = window.__drift && window.__drift.req;
    if (!r) { return JSON.stringify({ error: 'no-request' }); }
    const build = (offset, limit) => {
      if (r.body) {
        const b = JSON.parse(r.body);
        b.variables = Object.assign({}, b.variables, { offset: offset, limit: limit });
        return [r.url, { method: 'POST', headers: r.headers, body: JSON.stringify(b) }];
      }
      const u = new URL(r.url);
      const v = JSON.parse(u.searchParams.get('variables') || '{}');
      v.offset = offset; v.limit = limit;
      u.searchParams.set('variables', JSON.stringify(v));
      return [u.toString(), { method: 'GET', headers: r.headers }];
    };
    let name = null, total = null, offset = 0, limit = 100;
    const tracks = [];
    for (let guard = 0; guard < 200; guard++) {
      let j = null;
      try {
        const [url, init] = build(offset, limit);
        const res = await fetch(url, init);
        j = await res.json();
      } catch (e) { j = null; }
      const pl = j && j.data && (j.data.playlistV2 || j.data.playlist);
      if (!pl || !pl.content) {
        if (limit !== 25 && offset === 0) { limit = 25; continue; }
        break;
      }
      if (!name && pl.name) name = pl.name;
      total = pl.content.totalCount;
      const items = pl.content.items || [];
      for (const it of items) {
        const d = it && it.itemV2 && it.itemV2.data;
        if (!d || !d.name || (d.__typename && d.__typename !== 'Track')) continue;
        const artists = ((d.artists && d.artists.items) || [])
          .map(a => a && a.profile && a.profile.name).filter(Boolean);
        tracks.push({ t: d.name, a: artists[0] || '', ms: (d.trackDuration && d.trackDuration.totalMilliseconds) || 0 });
      }
      offset += items.length;
      if (items.length === 0 || (total != null && offset >= total)) break;
    }
    return JSON.stringify({ name: name, total: total, tracks: tracks });
    """

    private struct Result: Decodable {
        struct T: Decodable { let t: String; let a: String; let ms: Double }
        let name: String?
        let total: Int?
        let tracks: [T]?
        let error: String?
    }

    static func read(playlistID: String) async throws -> SpotifyList {
        let reader = SpotifyWebReader()
        defer { reader.tearDown() }
        return try await reader.run(playlistID)
    }

    private func run(_ id: String) async throws -> SpotifyList {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.captureScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        controller.add(self, name: "drift")
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.websiteDataStore = .nonPersistent()

        // Needs to be in a window for the page's scripts to run normally; invisible and untouchable.
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        web.alpha = 0.01
        web.isUserInteractionEnabled = false
        web.navigationDelegate = self
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        window?.insertSubview(web, at: 0)
        webView = web

        web.load(URLRequest(url: URL(string: "https://open.spotify.com/playlist/\(id)")!))

        // Wait (max 25 s) for the page to ask for its songs.
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            if gotRequest { c.resume(); return }
            ready = c
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(25))
                self?.resume(with: TimeoutError())
            }
        }

        let raw = try await web.callAsyncJavaScript(Self.fetchAllScript, arguments: [:], in: nil, contentWorld: .page)
        guard let json = raw as? String,
              let result = try? JSONDecoder().decode(Result.self, from: Data(json.utf8)),
              let list = result.tracks, !list.isEmpty else { throw SpotifyImportError.unreadable }

        let tracks = list.map {
            SpotifyTrack(title: $0.t, artist: $0.a, duration: $0.ms > 0 ? $0.ms / 1000 : nil)
        }
        return SpotifyList(name: result.name ?? "Spotify import", tracks: tracks)
    }

    private func tearDown() {
        resume(with: CancellationError())
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "drift")
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }

    private func resume(with error: Error?) {
        guard let c = ready else { return }
        ready = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            gotRequest = true
            resume(with: nil)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { pageFailed(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        MainActor.assumeIsolated { pageFailed(error) }
    }

    private func pageFailed(_ error: Error) {
        // Redirects inside the page cancel the previous load; that's not a failure.
        if (error as NSError).code == NSURLErrorCancelled { return }
        resume(with: error)
    }
}
