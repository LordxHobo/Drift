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

    /// Watches the page: notes its playlist requests and reads every song list it gets back.
    private static let captureScript = """
    (() => {
      if (window.__drift) return;
      const D = window.__drift = { reqs: [], pages: {}, name: null, total: null, log: [], signalled: false, changed: Date.now() };
      const note = (s) => { try { D.log.push(new Date().toISOString().slice(11, 19) + ' ' + s); } catch (e) {} };
      D.note = note;
      const opOf = (url, body) => {
        try { if (body) return JSON.parse(body).operationName || ''; } catch (e) {}
        try { return new URL(url, location.href).searchParams.get('operationName') || ''; } catch (e) { return ''; }
      };
      const offOf = (url, body) => {
        try {
          const v = body ? JSON.parse(body).variables : JSON.parse(new URL(url, location.href).searchParams.get('variables') || '{}');
          return Number(v && v.offset) || 0;
        } catch (e) { return 0; }
      };
      // One page of songs: kept by place, so pages from anywhere fill the same list.
      D.add = (json, offset, from) => {
        const pl = json && json.data && (json.data.playlistV2 || json.data.playlist);
        if (!pl || !pl.content || !Array.isArray(pl.content.items)) { note(from + ': no song list'); return 0; }
        if (!D.name && pl.name) D.name = pl.name;
        if (typeof pl.content.totalCount === 'number') D.total = pl.content.totalCount;
        let fresh = 0;
        pl.content.items.forEach((it, i) => {
          const d = it && ((it.itemV2 && it.itemV2.data) || (it.item && it.item.data));
          let song = null;
          if (d && d.name && (!d.__typename || d.__typename === 'Track')) {
            const artists = ((d.artists && d.artists.items) || []).map(a => a && a.profile && a.profile.name).filter(Boolean);
            const ms = (d.trackDuration && d.trackDuration.totalMilliseconds) || (d.duration && d.duration.totalMilliseconds) || 0;
            const added = Date.parse((it.addedAt && it.addedAt.isoString) || '');
            song = { t: d.name, a: artists[0] || '', ms: ms, ad: isFinite(added) ? added / 1000 : 0 };
          }
          if (!((offset + i) in D.pages)) fresh++;
          D.pages[offset + i] = song;
        });
        if (fresh) D.changed = Date.now();
        note(from + ': offset ' + offset + ', ' + pl.content.items.length + ' items (' + fresh + ' new), total ' + D.total);
        if (!D.signalled) {
          D.signalled = true;
          try { window.webkit.messageHandlers.drift.postMessage('ready'); } catch (e) {}
        }
        return pl.content.items.length;
      };
      const origFetch = window.fetch;
      window.fetch = function (input, init) {
        let url = null, i = init, body = null;
        try {
          url = typeof input === 'string' ? input : (input && input.url);
          if (!i && input && typeof input !== 'string') i = { method: input.method, headers: input.headers };
          body = i && typeof i.body === 'string' ? i.body : null;
        } catch (e) {}
        const p = origFetch.apply(this, arguments);
        try {
          if (url && url.indexOf('pathfinder') >= 0 && !(i && i.__drift)) {
            const op = opOf(url, body);
            if (/playlist/i.test(op)) {
              const headers = {};
              new Headers((i && i.headers) || {}).forEach((v, k) => { headers[k] = v; });
              D.reqs.push({ url: url, body: body, headers: headers, op: op });
              note('page asked: ' + op);
              const off = offOf(url, body);
              // Read a copy of the answer (before the page reads it).
              p.then(r => r.clone().json()).then(j => D.add(j, off, 'page got ' + op)).catch(() => note('couldn’t read answer to ' + op));
            }
          }
        } catch (e) {}
        return p;
      };
    })();
    """

    /// Fills the gaps: asks for missing parts with the page's own request (smaller pages when
    /// refused), then scrolls the page so it loads the rest itself. Returns {name, total, filled, tracks, log}.
    private static let fetchAllScript = """
    const D = window.__drift;
    if (!D) { return JSON.stringify({ error: 'no-script' }); }
    const sleep = (ms) => new Promise(r => setTimeout(r, ms));
    const note = D.note;
    await sleep(1500);
    const missingFrom = () => {
      if (D.total == null) return -1;
      for (let i = 0; i < D.total; i++) if (!(i in D.pages)) return i;
      return -1;
    };
    const usable = D.reqs.filter(r => !/metadata/i.test(r.op));
    const best = usable.find(r => /contents/i.test(r.op)) || usable.find(r => r.op === 'fetchPlaylist') || usable[0];
    if (best) {
      const sizes = [100, 50, 25];
      let size = 0, failures = 0;
      while (D.total != null && failures < 6) {
        const at = missingFrom();
        if (at < 0) break;
        const limit = sizes[Math.min(size, sizes.length - 1)];
        let url = best.url, init;
        if (best.body) {
          const b = JSON.parse(best.body);
          b.variables = Object.assign({}, b.variables, { offset: at, limit: limit });
          init = { method: 'POST', headers: best.headers, body: JSON.stringify(b), __drift: true };
        } else {
          const u = new URL(best.url, location.href);
          const v = JSON.parse(u.searchParams.get('variables') || '{}');
          v.offset = at; v.limit = limit;
          u.searchParams.set('variables', JSON.stringify(v));
          url = u.toString();
          init = { method: 'GET', headers: best.headers, __drift: true };
        }
        let got = 0, status = '';
        try {
          const res = await fetch(url, init);
          status = String(res.status);
          got = D.add(await res.json(), at, 'asked ' + best.op + ' (limit ' + limit + ')');
        } catch (e) { status = String(e); }
        if (got > 0) {
          failures = 0;
        } else {
          note('asked ' + best.op + ' at ' + at + ' (limit ' + limit + '): ' + status);
          failures++;
          size++;
          await sleep(800);
        }
      }
    } else {
      note('no usable request seen');
    }
    if (missingFrom() >= 0) {
      note('scrolling for the rest');
      const until = Date.now() + 60000;
      D.changed = Date.now();
      while (missingFrom() >= 0 && Date.now() < until && Date.now() - D.changed < 8000) {
        for (const el of [document.scrollingElement, ...document.querySelectorAll('*')]) {
          if (el && el.scrollHeight > el.clientHeight + 200 && el.clientHeight > 200) el.scrollTop = el.scrollTop + el.clientHeight * 0.9;
        }
        await sleep(700);
      }
    }
    const places = Object.keys(D.pages).map(Number).sort((a, b) => a - b);
    const tracks = places.map(k => D.pages[k]).filter(Boolean);
    note('done: ' + places.length + ' of ' + D.total + ' places, ' + tracks.length + ' songs');
    return JSON.stringify({ name: D.name, total: D.total, filled: places.length, tracks: tracks, log: D.log });
    """

    private struct Result: Decodable {
        struct T: Decodable {
            let t: String
            let a: String
            let ms: Double
            /// Added on Spotify (seconds since 1970), 0 when unknown.
            let ad: Double?
        }
        let name: String?
        let total: Int?
        let filled: Int?
        let tracks: [T]?
        let log: [String]?
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
        let result = (raw as? String).flatMap { try? JSONDecoder().decode(Result.self, from: Data($0.utf8)) }
        Self.saveLog(result?.log ?? ["no answer from the page"])
        guard let result, let list = result.tracks, !list.isEmpty else { throw SpotifyImportError.unreadable }

        let tracks = list.map {
            SpotifyTrack(title: $0.t, artist: $0.a, duration: $0.ms > 0 ? $0.ms / 1000 : nil,
                         added: ($0.ad ?? 0) > 0 ? Date(timeIntervalSince1970: $0.ad!) : nil)
        }
        // Spotify said there are more songs than it gave: say so after the import.
        let short = result.total.flatMap { total in (result.filled ?? 0) < total ? total : nil }
        return SpotifyList(name: result.name ?? "Spotify import", tracks: tracks, total: short)
    }

    /// A short record of the last import's reading (Files app → Drift → spotify-import.log).
    private static func saveLog(_ lines: [String]) {
        let url = AppFiles.data.appending(path: "spotify-import.log")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
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
