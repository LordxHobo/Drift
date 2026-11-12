package com.lordxhobo.drift.playback

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.lordxhobo.drift.youtube.YTViewer
import org.json.JSONObject
import java.io.ByteArrayInputStream

/**
 * Videos from the YouTube viewer, played by YouTube's own mobile player (like ProTube does), in a web view
 * signed in as you: it starts at once, picks the quality itself and gets past YouTube's checks. Drift's own
 * controls, timeline, SponsorBlock and queue sit on top (WebVideoPlayer makes it a Media3 player, so the
 * notification and lock screen work); the page shows only the video, with ads taken out of YouTube's answers
 * (and any left skipped) and ad servers blocked.
 */
@SuppressLint("SetJavaScriptEnabled")
object YTWeb {
    /** The phone's player is this one (not ExoPlayer) right now. */
    var active by mutableStateOf(false)
    /** Has a picture (the video started). */
    var ready by mutableStateOf(false)
        private set
    /** An ad is being skipped. */
    var ad by mutableStateOf(false)
        private set
    /** The qualities YouTube offers for it (heights), and the one asked for. */
    var heights by mutableStateOf(listOf<Int>())
        private set
    var height by mutableStateOf<Int?>(null)
        private set

    var videoId: String? = null
        private set
    var durationMs = 0L
        private set
    var playing = false
        private set
    var buffering = true
        private set
    private var timeMs = 0L
    private var timeAt = 0L
    private var rate = 1f
    private var endedReported = false
    private var errorReported = false
    private var qualitySet = false

    interface Listener {
        fun changed()
        fun ended()
        fun failed(message: String)
    }

    var listener: Listener? = null

    private lateinit var app: Context
    private val main = Handler(Looper.getMainLooper())
    private var web: WebView? = null
    private var startScript = false

    fun init(context: Context) {
        app = context.applicationContext
    }

    /** Where it is now (ms), moving on between the page's reports. */
    fun positionMs(): Long =
        if (playing) timeMs + ((System.currentTimeMillis() - timeAt) * rate).toLong() else timeMs

    val view: WebView get() = web ?: build().also { web = it }

    // MARK: Playing

    fun load(id: String, atMs: Long, autoplay: Boolean) {
        videoId = id
        timeMs = atMs
        timeAt = System.currentTimeMillis()
        durationMs = 0
        playing = false
        buffering = true
        ready = false
        ad = false
        heights = emptyList()
        endedReported = false
        errorReported = false
        qualitySet = false
        val hash = "drift-at=" + atMs / 1000 + if (autoplay) "" else "&drift-paused"
        view.loadUrl("https://m.youtube.com/watch?v=" + id + "#" + hash)
        if (view.parent == null) parking?.let { move(it) }
        // Nothing playing 15 s in (page didn't load, or YouTube's player gave up): the player moves on.
        main.removeCallbacks(stallCheck)
        if (autoplay) main.postDelayed(stallCheck, 15_000)
    }

    private val stallCheck = Runnable { if (videoId != null && durationMs == 0L && !ad) fail("YouTube's player didn't start") }

    fun play() = run("__drift.play()")
    fun pause() = run("__drift.pause()")

    fun seek(ms: Long) {
        timeMs = ms
        timeAt = System.currentTimeMillis()
        endedReported = false
        run("__drift.seek(" + ms / 1000.0 + ")")
    }

    fun rate(r: Float) {
        rate = r
        run("__drift.rate(" + r + ")")
    }

    /** A quality (height), from the menu: remembered for the next videos too. */
    fun choose(h: Int) {
        height = h
        EpisodeVideo.rememberQuality(h)
        run("__drift.quality('" + label(h) + "')")
    }

    /** Unloads it (music plays, or the video was closed). */
    fun stop() {
        if (videoId == null) return
        videoId = null
        playing = false
        ready = false
        main.removeCallbacks(stallCheck)
        web?.loadUrl("about:blank")
    }

    private fun run(js: String) {
        web?.evaluateJavascript("window.__drift && " + js, null)
    }

    private fun fail(message: String) {
        if (errorReported) return
        errorReported = true
        listener?.failed(message)
    }

    private fun received(json: String) {
        val m = runCatching { JSONObject(json) }.getOrNull() ?: return
        val id = videoId ?: return
        if (m.optString("k") != "state") return
        // YouTube went on to another video by itself: Drift picks what's next.
        val v = m.optString("v")
        if (v.isNotEmpty() && v != id) {
            run("__drift.pause()")
            return
        }
        val isAd = m.optBoolean("ad")
        if (ad != isAd) ad = isAd
        val t = m.optDouble("t", 0.0)
        val d = m.optDouble("d", 0.0)
        if (!isAd && t >= 0) {
            timeMs = (t * 1000).toLong()
            timeAt = System.currentTimeMillis()
        }
        if (!isAd && d > 0) {
            durationMs = (d * 1000).toLong()
            if (!ready) ready = true
            main.removeCallbacks(stallCheck)
        }
        playing = m.optBoolean("playing")
        buffering = m.optBoolean("buffering")
        if (playing && !qualitySet) {
            qualitySet = true
            val h = EpisodeVideo.quality.coerceAtMost(2160)
            height = h
            run("__drift.quality('" + label(h) + "')")
            if (rate != 1f) rate(rate)
            web?.evaluateJavascript("window.__drift ? __drift.qualities() : []") { result ->
                val labels = runCatching { org.json.JSONArray(result) }.getOrNull()
                heights = (0 until (labels?.length() ?: 0)).mapNotNull { heightOf(labels!!.optString(it)) }.distinct().sorted()
            }
        }
        val error = m.optString("error")
        if (error.isNotEmpty() && durationMs == 0L) fail(error)
        if (m.optBoolean("ended") && !endedReported) {
            endedReported = true
            listener?.ended()
        }
        listener?.changed()
    }

    /** YouTube's names for the qualities. */
    fun label(h: Int): String = when {
        h >= 2160 -> "hd2160"
        h >= 1440 -> "hd1440"
        h >= 1080 -> "hd1080"
        h >= 720 -> "hd720"
        h >= 480 -> "large"
        h >= 360 -> "medium"
        h >= 240 -> "small"
        else -> "tiny"
    }

    private fun heightOf(label: String): Int? = mapOf(
        "hd2160" to 2160, "hd1440" to 1440, "hd1080" to 1080, "hd720" to 720,
        "large" to 480, "medium" to 360, "small" to 240, "tiny" to 144,
    )[label]

    // MARK: Where it's shown

    /** The views showing it (the watch page, the floating video, full screen): the last one has it. */
    private val hosts = mutableListOf<FrameLayout>()
    /** Out of sight but still in the window (so it keeps playing) while none is on screen. */
    var parking: FrameLayout? = null
        set(value) {
            field = value
            if (value != null && web?.parent == null && videoId != null) move(value)
        }

    fun show(host: FrameLayout) {
        hosts.remove(host)
        hosts.add(host)
        move(host)
    }

    fun hide(host: FrameLayout) {
        hosts.remove(host)
        val w = web ?: return
        if (w.parent !== host) return
        val next = hosts.lastOrNull { it.isAttachedToWindow } ?: parking?.takeIf { it.isAttachedToWindow && it !== host }
        if (next != null) move(next) else host.removeView(w)
    }

    private fun move(to: FrameLayout) {
        val w = view
        if (w.parent === to) return
        (w.parent as? ViewGroup)?.removeView(w)
        to.addView(w, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }

    // MARK: The web view

    private fun build(): WebView = WebView(app).apply {
        setBackgroundColor(android.graphics.Color.BLACK)
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.mediaPlaybackRequiresUserGesture = false
        settings.userAgentString = YTViewer.SIGNIN_UA
        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
        if (WebViewFeature.isFeatureSupported(WebViewFeature.REQUESTED_WITH_HEADER_ALLOW_LIST)) {
            WebSettingsCompat.setRequestedWithHeaderOriginAllowList(settings, emptySet())
        }
        // Drift's controls take the taps.
        isFocusable = false
        isFocusableInTouchMode = false
        setOnTouchListener { _, _ -> true }
        isVerticalScrollBarEnabled = false
        isHorizontalScrollBarEnabled = false
        overScrollMode = View.OVER_SCROLL_NEVER
        addJavascriptInterface(Bridge(), "DriftAndroid")
        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            WebViewCompat.addDocumentStartJavaScript(this, SCRIPT, setOf("https://m.youtube.com", "https://www.youtube.com"))
            startScript = true
        }
        webChromeClient = WebChromeClient()
        webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
                if (blocked(request.url.toString())) WebResourceResponse("text/plain", "utf-8", ByteArrayInputStream(ByteArray(0))) else null

            override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
                // Older web views without start scripts: as early as possible.
                if (!startScript) view.evaluateJavascript(SCRIPT, null)
            }

            override fun onPageFinished(view: WebView, url: String?) {
                if (!startScript) view.evaluateJavascript(SCRIPT, null)
            }

            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame && videoId != null) fail(error.description?.toString() ?: "Couldn't load the video")
            }

            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                (view.parent as? ViewGroup)?.removeView(view)
                view.destroy()
                web = null
                if (videoId != null) fail("The video stopped")
                return true
            }
        }
    }

    private class Bridge {
        @JavascriptInterface
        fun post(json: String) {
            main.post { received(json) }
        }
    }

    // MARK: Ad servers

    private val blockedHosts = listOf("doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com")
    private val blockedPaths = listOf("/pagead/", "/api/stats/ads", "/ptracking", "/get_midroll_", "/pcs/activeview")

    private fun blocked(url: String): Boolean {
        val u = runCatching { android.net.Uri.parse(url) }.getOrNull() ?: return false
        val host = u.host ?: return false
        if (blockedHosts.any { host == it || host.endsWith("." + it) }) return true
        val path = u.path ?: return false
        return host.endsWith("youtube.com") && blockedPaths.any { path.startsWith(it) }
    }

    // MARK: The page script

    private const val SCRIPT = """
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
"""
}
