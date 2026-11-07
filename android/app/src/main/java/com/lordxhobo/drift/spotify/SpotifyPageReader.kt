package com.lordxhobo.drift.spotify

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.util.concurrent.ConcurrentHashMap

/**
 * Reads a whole playlist of any length, like the computer: Spotify's own page is opened in a hidden
 * browser, and the song lists it loads are read as they arrive. Missing parts are then asked for with
 * the page's own request, page by page. No account or keys needed. Runs on the main thread.
 */
class SpotifyPageReader(private val context: Context) {
    private class Req(val url: String, val body: String?, val headers: JsonObject, val op: String)

    private val main = Handler(Looper.getMainLooper())
    private val songs = sortedMapOf<Int, SpotifySong?>()
    private val requests = mutableListOf<Req>()
    private var name: String? = null
    private var total: Int? = null
    private val firstPage = CompletableDeferred<Unit>()
    private val answers = ConcurrentHashMap<String, CompletableDeferred<String>>()

    /** null when this phone's browser can't do it (very old Android System WebView): use the embed page. */
    @SuppressLint("SetJavaScriptEnabled", "JavascriptInterface")
    suspend fun read(id: String, onProgress: (Int, Int?) -> Unit): SpotifyList? {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) return null
        val web = WebView(context)
        try {
            web.settings.javaScriptEnabled = true
            web.settings.domStorageEnabled = true
            web.settings.mediaPlaybackRequiresUserGesture = true
            web.settings.userAgentString = Spotify.CHROME_AGENT
            // A desktop-sized page (Spotify's mobile page sends you to the app instead).
            web.layout(0, 0, 1280, 900)
            web.webViewClient = WebViewClient()
            web.addJavascriptInterface(Bridge(), "DriftBridge")
            WebViewCompat.addDocumentStartJavaScript(web, HOOK, setOf("https://open.spotify.com"))
            web.loadUrl("https://open.spotify.com/playlist/$id")

            if (withTimeoutOrNull(25_000) { firstPage.await() } == null) return null
            delay(1500) // let the page finish its first few requests
            onProgress(songs.size, total)

            // Ask for the missing parts with the page's own request (the one that returned songs).
            val usable = requests.filter { !Regex("metadata", RegexOption.IGNORE_CASE).containsMatchIn(it.op) }
            val best = usable.firstOrNull { Regex("contents", RegexOption.IGNORE_CASE).containsMatchIn(it.op) }
                ?: usable.firstOrNull { it.op == "fetchPlaylist" } ?: usable.firstOrNull()
            if (best != null) {
                var failures = 0
                var size = 0
                val sizes = listOf(100, 50, 25)
                while (total != null && failures < 6) {
                    val at = missingFrom()
                    if (at < 0) break
                    val limit = sizes[minOf(size, sizes.lastIndex)]
                    val text = ask(web, best, at, limit)
                    val page = text?.let { runCatching { Spotify.parsePage(Json.parseToJsonElement(it)) }.getOrNull() }
                    if (page != null && page.items.isNotEmpty()) {
                        add(page, at)
                        failures = 0
                        onProgress(songs.size, total)
                    } else {
                        failures++
                        size++ // try smaller pages
                        delay(800)
                    }
                }
            }

            val list = songs.values.filterNotNull()
            if (list.isEmpty()) return null
            val t = total
            return SpotifyList(name ?: "Spotify import", list, total = if (t != null && songs.size < t) t else null)
        } finally {
            web.stopLoading()
            web.destroy()
            // Spotify's cookies aren't needed afterwards (Drift uses no other web pages).
            CookieManager.getInstance().removeAllCookies(null)
        }
    }

    private fun missingFrom(): Int {
        val t = total ?: return -1
        for (i in 0 until t) if (!songs.containsKey(i)) return i
        return -1
    }

    private fun add(page: SpotifyPage, offset: Int) {
        if (name == null) name = page.name
        page.total?.let { total = it }
        page.items.forEachIndexed { i, s -> songs[offset + i] = s }
    }

    /** One page with the page's own request; its answer as text, or null. */
    private suspend fun ask(web: WebView, r: Req, offset: Int, limit: Int): String? {
        val token = java.util.UUID.randomUUID().toString()
        val deferred = CompletableDeferred<String>()
        answers[token] = deferred
        // Headers the page isn't allowed to set itself are left out (the browser adds them).
        val headers = JsonObject(r.headers.filterKeys { k ->
            !Regex("^(host|origin|referer|cookie|connection|content-length|accept-encoding|user-agent|sec-|proxy-|:)", RegexOption.IGNORE_CASE).containsMatchIn(k)
        })
        val req = buildJsonObject {
            put("url", r.url)
            put("body", r.body?.let { JsonPrimitive(it) } ?: kotlinx.serialization.json.JsonNull)
            put("headers", headers)
        }
        val script = """(async () => {
            const r = $req;
            let url = r.url, init;
            if (r.body) {
              const b = JSON.parse(r.body);
              b.variables = Object.assign({}, b.variables, { offset: $offset, limit: $limit });
              init = { method: 'POST', headers: r.headers, body: JSON.stringify(b) };
            } else {
              const u = new URL(r.url);
              const v = JSON.parse(u.searchParams.get('variables') || '{}');
              v.offset = $offset; v.limit = $limit;
              u.searchParams.set('variables', JSON.stringify(v));
              url = u.toString();
              init = { method: 'GET', headers: r.headers };
            }
            let text = '';
            try { const res = await (window.__driftFetch || fetch)(url, init); text = await res.text(); } catch (e) {}
            DriftBridge.answer('$token', text);
          })()"""
        web.evaluateJavascript(script, null)
        val text = withTimeoutOrNull(15_000) { deferred.await() }
        answers.remove(token)
        return text?.takeIf { it.isNotEmpty() }
    }

    /** Called from Spotify's page (on the browser's own thread). */
    private inner class Bridge {
        @JavascriptInterface
        fun page(request: String, text: String) {
            main.post {
                val r = runCatching { Json.parseToJsonElement(request) as JsonObject }.getOrNull() ?: return@post
                val url = Spotify.str(r["url"]) ?: return@post
                val body = Spotify.str(r["body"])
                val op = Spotify.operation(url, body)
                if (!Regex("playlist", RegexOption.IGNORE_CASE).containsMatchIn(op)) return@post
                requests.add(Req(url, body, r["headers"] as? JsonObject ?: JsonObject(emptyMap()), op))
                val page = runCatching { Spotify.parsePage(Json.parseToJsonElement(text)) }.getOrNull() ?: return@post
                add(page, Spotify.offsetOf(url, body))
                firstPage.complete(Unit)
            }
        }

        @JavascriptInterface
        fun answer(token: String, text: String) {
            answers[token]?.complete(text)
        }
    }

    companion object {
        /** Runs before Spotify's own scripts: passes on every playlist request the page makes, and its answer. */
        private const val HOOK = """(function () {
  if (window.__driftFetch) return;
  const original = window.fetch;
  window.__driftFetch = original;
  const report = (url, body, headers, text) => {
    try { if (String(url).indexOf('pathfinder') >= 0) DriftBridge.page(JSON.stringify({ url: String(url), body: body, headers: headers }), text); } catch (e) {}
  };
  const plainHeaders = (h) => {
    const out = {};
    if (!h) return out;
    if (h instanceof Headers) h.forEach((v, k) => { out[k] = v; });
    else if (Array.isArray(h)) h.forEach((p) => { out[p[0]] = p[1]; });
    else Object.keys(h).forEach((k) => { out[k] = h[k]; });
    return out;
  };
  window.fetch = async function (input, init) {
    const res = await original.apply(this, arguments);
    try {
      const url = typeof input === 'string' ? input : (input && input.url) || String(input);
      if (url.indexOf('pathfinder') >= 0) {
        let body = init && typeof init.body === 'string' ? init.body : null;
        if (body === null && input instanceof Request) { try { body = await input.clone().text(); } catch (e) {} }
        const headers = plainHeaders((init && init.headers) || (input instanceof Request ? input.headers : null));
        res.clone().text().then((text) => report(url, body || null, headers, text)).catch(() => {});
      }
    } catch (e) {}
    return res;
  };
  const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send, set = XMLHttpRequest.prototype.setRequestHeader;
  XMLHttpRequest.prototype.open = function (m, url) { this.__drift = { url: url, headers: {} }; return open.apply(this, arguments); };
  XMLHttpRequest.prototype.setRequestHeader = function (k, v) { if (this.__drift) this.__drift.headers[k] = v; return set.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function (body) {
    const d = this.__drift;
    if (d && String(d.url).indexOf('pathfinder') >= 0) {
      this.addEventListener('load', () => { try { report(d.url, typeof body === 'string' ? body : null, d.headers, this.responseText); } catch (e) {} });
    }
    return send.apply(this, arguments);
  };
})();"""
    }
}
