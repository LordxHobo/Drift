package com.lordxhobo.drift.ui

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.filled.Close
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.FastRewind
import androidx.compose.material.icons.filled.FastForward
import androidx.compose.material.icons.filled.OpenInFull
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.unit.IntOffset
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.lordxhobo.drift.playback.EpisodeVideo
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.SmartDisplay
import androidx.compose.material.icons.filled.ThumbUp
import androidx.compose.material.icons.filled.Forward10
import androidx.compose.material.icons.filled.Replay10
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import coil.compose.AsyncImage
import com.lordxhobo.drift.data.Track
import com.lordxhobo.drift.playback.Downloads
import com.lordxhobo.drift.playback.Playback
import com.lordxhobo.drift.playback.Skipping
import com.lordxhobo.drift.social.Inbox
import com.lordxhobo.drift.social.Social
import com.lordxhobo.drift.youtube.YTChannel
import com.lordxhobo.drift.youtube.YTComment
import com.lordxhobo.drift.youtube.YTVideo
import com.lordxhobo.drift.youtube.YTVideoDetails
import com.lordxhobo.drift.youtube.YTViewer
import kotlinx.coroutines.launch

/** YouTube mode's color (Drift's own accent stays for music). */
val YTRed = Color(0xFFFF0033)

// MARK: Playing

fun YTVideo.toTrack(): Track = Track(
    id = id, title = title, artist = channel, duration = duration, artworkURL = thumbnail,
    upload = true, podcast = true, channelID = channelId, watch = true,
)

/** Plays a video (then the ones after it, like YouTube's autoplay) and opens its watch page. */
fun playVideo(v: YTVideo, after: List<YTVideo> = emptyList()) {
    val list = listOf(v) + after.filter { it.id != v.id && !it.live }
    Playback.play(list.map { it.toTrack() }, 0, v.channel.ifEmpty { "YouTube" })
    if (Nav.top != Screen.YTWatch(v.id)) Nav.open(Screen.YTWatch(v.id))
}

/** Something loaded from YouTube: the value, or why it failed (with a way to try again). */
private class Loaded<T>(val value: T?, val error: String?, val reload: () -> Unit)

@Composable
private fun <T> rememberYT(key: Any, load: suspend () -> T): Loaded<T> {
    var tick by remember { mutableStateOf(0) }
    var value by remember(key) { mutableStateOf<T?>(null) }
    var error by remember(key) { mutableStateOf<String?>(null) }
    LaunchedEffect(key, tick) {
        error = null
        runCatching { load() }.onSuccess { value = it }.onFailure { error = it.message ?: "That didn't work." }
    }
    return Loaded(value, error) { tick++ }
}

// MARK: The switch and signing in

/** At the top of Settings: music or the YouTube viewer (signing in the first time). */
@Composable
fun YTViewerSwitch() {
    Row(
        Modifier.padding(horizontal = 16.dp).padding(bottom = 12.dp).fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(DriftColors.surface)
            .clickable { flipViewer(!YTViewer.on) }.padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(40.dp).clip(RoundedCornerShape(10.dp)).background(YTRed), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.SmartDisplay, contentDescription = null, tint = Color.White)
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text("YouTube viewer", color = DriftColors.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            Text(
                if (YTViewer.signedIn) "Swap Drift to videos" else "Sign in with YouTube to watch videos",
                color = DriftColors.muted, fontSize = 12.sp,
            )
        }
        Switch(
            checked = YTViewer.on, onCheckedChange = { flipViewer(it) },
            colors = SwitchDefaults.colors(checkedTrackColor = YTRed, checkedThumbColor = Color.White),
        )
    }
}

private fun flipViewer(on: Boolean) {
    if (on && !YTViewer.signedIn) {
        Nav.open(Screen.YTSignIn)
        return
    }
    YTViewer.turn(on)
    Nav.back()
    Nav.tab = if (on) Tab.YT_HOME else Tab.HOME
}

/** Hides passkey support (or Google asks for a security key first) and Chromium's hints (or Google refuses the web view). */
private const val HIDE_SCRIPT = """(() => {
  try { Object.defineProperty(Navigator.prototype, 'userAgentData', { get: () => undefined, configurable: true }) } catch (e) {}
  try { Object.defineProperty(window, 'PublicKeyCredential', { value: undefined, configurable: true }) } catch (e) {}
  try {
    const refuse = () => Promise.reject(new DOMException('Not supported here', 'NotSupportedError'))
    if (navigator.credentials) {
      Object.defineProperty(navigator.credentials, 'get', { value: refuse, configurable: true })
      Object.defineProperty(navigator.credentials, 'create', { value: refuse, configurable: true })
    }
  } catch (e) {}
})()"""

@SuppressLint("SetJavaScriptEnabled")
@Composable
fun YTSignInScreen() {
    var web by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize()) {
        BackBar("Sign in to YouTube")
        if (!web) {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Box(Modifier.size(60.dp).clip(RoundedCornerShape(16.dp)).background(YTRed), contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.SmartDisplay, contentDescription = null, tint = Color.White, modifier = Modifier.size(34.dp))
                }
                Text("Sign in to watch YouTube", color = DriftColors.text, fontSize = 24.sp, fontWeight = FontWeight.ExtraBold)
                Text(
                    "The viewer uses your own YouTube account, so YouTube sees a signed-in viewer, and your subscriptions, Watch later and history come with it.",
                    color = DriftColors.text2, fontSize = 15.sp, lineHeight = 21.sp,
                )
                Text(
                    "Use an account you don't mind Drift using. Each phone or computer signs in on its own, and Google's own page does the signing in.",
                    color = DriftColors.muted, fontSize = 13.sp, lineHeight = 18.sp,
                    modifier = Modifier.clip(RoundedCornerShape(12.dp)).background(DriftColors.surface).padding(12.dp),
                )
                Box(
                    Modifier.fillMaxWidth().heightIn(min = 52.dp).clip(RoundedCornerShape(26.dp)).background(Color.White).clickable { web = true },
                    contentAlignment = Alignment.Center,
                ) { Text("Sign in with Google", color = Color(0xFF111111), fontSize = 16.sp, fontWeight = FontWeight.Bold) }
            }
        } else {
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { ctx ->
                    WebView(ctx).apply {
                        settings.javaScriptEnabled = true
                        settings.domStorageEnabled = true
                        settings.userAgentString = YTViewer.SIGNIN_UA
                        CookieManager.getInstance().setAcceptCookie(true)
                        CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
                        // Web views tell sites they're an app (a header Google checks): not here.
                        if (WebViewFeature.isFeatureSupported(WebViewFeature.REQUESTED_WITH_HEADER_ALLOW_LIST)) {
                            WebSettingsCompat.setRequestedWithHeaderOriginAllowList(settings, emptySet())
                        }
                        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
                            WebViewCompat.addDocumentStartJavaScript(this, HIDE_SCRIPT, setOf("*"))
                        }
                        webViewClient = object : WebViewClient() {
                            override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) = check(url)
                            override fun onPageFinished(view: WebView, url: String?) = check(url)
                            private fun check(url: String?) {
                                if (url == null || !(url.startsWith("https://www.youtube.com") || url.startsWith("https://m.youtube.com"))) return
                                CookieManager.getInstance().flush()
                                if (YTViewer.signedInWith(CookieManager.getInstance().getCookie("https://www.youtube.com"))) {
                                    YTViewer.turn(true)
                                    // Out of sign-in (and Settings) into the viewer.
                                    while (Nav.back()) Unit
                                    Nav.tab = Tab.YT_HOME
                                }
                            }
                        }
                        loadUrl("https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2F")
                    }
                },
            )
        }
    }
}

// MARK: Pieces

@Composable
private fun VideoCard(v: YTVideo, list: List<YTVideo>) {
    Column(Modifier.fillMaxWidth().clickable { playVideo(v, list.drop(list.indexOf(v) + 1)) }.padding(bottom = 18.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(16f / 9f).background(DriftColors.surface)) {
            AsyncImage(model = v.thumbnail, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
            LengthBadge(v, Modifier.align(Alignment.BottomEnd).padding(8.dp))
        }
        Row(Modifier.padding(start = 14.dp, end = 14.dp, top = 10.dp)) {
            Column(Modifier.weight(1f)) {
                Text(v.title, color = DriftColors.text, fontSize = 15.sp, fontWeight = FontWeight.Bold, lineHeight = 20.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(
                    listOf(v.channel, v.views, v.published).filter { it.isNotEmpty() }.joinToString(" · "),
                    color = DriftColors.muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 3.dp).clickable(enabled = v.channelId != null) { v.channelId?.let { Nav.open(Screen.YTChannel(it)) } },
                )
            }
        }
    }
}

@Composable
private fun LengthBadge(v: YTVideo, modifier: Modifier) {
    val d = v.duration
    if (!v.live && d == null) return
    Text(
        if (v.live) "LIVE" else formatSeconds(d ?: 0.0),
        color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Bold,
        modifier = modifier.clip(RoundedCornerShape(4.dp)).background(if (v.live) YTRed else Color.Black.copy(alpha = 0.8f)).padding(horizontal = 5.dp, vertical = 2.dp),
    )
}

private fun formatSeconds(s: Double): String {
    val t = s.toLong()
    val h = t / 3600
    val m = (t % 3600) / 60
    val sec = t % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, sec) else "%d:%02d".format(m, sec)
}

@Composable
private fun SmallVideoRow(v: YTVideo, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 6.dp)) {
        Box(Modifier.width(150.dp).aspectRatio(16f / 9f).clip(RoundedCornerShape(8.dp)).background(DriftColors.surface)) {
            AsyncImage(model = v.thumbnail, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
            LengthBadge(v, Modifier.align(Alignment.BottomEnd).padding(4.dp))
        }
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(v.title, color = DriftColors.text, fontSize = 13.sp, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Text(v.channel, color = DriftColors.muted, fontSize = 12.sp, maxLines = 1)
            Text(listOf(v.views, v.published).filter { it.isNotEmpty() }.joinToString(" · "), color = DriftColors.muted, fontSize = 12.sp, maxLines = 1)
        }
    }
}

@Composable
private fun Avatarish(url: String?, size: androidx.compose.ui.unit.Dp) {
    Box(Modifier.size(size).clip(CircleShape).background(DriftColors.surface2)) {
        if (url != null) AsyncImage(model = url, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
    }
}

@Composable
private fun Chip(label: String, on: Boolean, onClick: () -> Unit) {
    Text(
        label, color = if (on) Color.Black else DriftColors.text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
        modifier = Modifier.clip(RoundedCornerShape(8.dp)).background(if (on) DriftColors.text else DriftColors.surface2)
            .clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 7.dp),
    )
}

@Composable
private fun Failed(error: String, reload: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(error, color = DriftColors.muted, fontSize = 14.sp)
        Chip("Try again", false, reload)
    }
}

@Composable
private fun Spinning() {
    Box(Modifier.fillMaxWidth().padding(30.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = YTRed) }
}

/** A list of videos with a title row (and what to show while loading, when empty or when it failed). */
@Composable
private fun VideoList(title: String?, loaded: Loaded<List<YTVideo>>, empty: String, back: Boolean, header: @Composable () -> Unit = {}, filter: (YTVideo) -> Boolean = { true }) {
    val list = loaded.value?.filter(filter)
    // The first few get their sound and picture found now, so they start the moment they're tapped.
    LaunchedEffect(list?.firstOrNull()?.id) {
        val first = list.orEmpty().filter { !it.live }.take(4)
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            first.forEach { v ->
                runCatching { com.lordxhobo.drift.youtube.YouTube.audio(v.id) }
                runCatching { com.lordxhobo.drift.youtube.YouTube.video(v.id, EpisodeVideo.quality) }
            }
        }
    }
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        if (back) item { BackBar(title ?: "") } else if (title != null) item { PageTitle(title) }
        item { header() }
        when {
            list == null && loaded.error != null -> item { Failed(loaded.error, loaded.reload) }
            list == null -> item { Spinning() }
            list.isEmpty() -> item { EmptyText(empty) }
            else -> items(list, key = { it.id }) { VideoCard(it, list) }
        }
    }
}

// MARK: Tabs

@Composable
fun YTHomeScreen() {
    val loaded = rememberYT("home") { YTViewer.feed(YTViewer.Feed.SUBSCRIPTIONS) }
    var chip by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) { YTViewer.loadAccount() }
    VideoList(
        title = null, loaded = loaded, empty = "Nothing new from your subscriptions.", back = false,
        header = {
            Column {
                Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Home", color = DriftColors.text, fontSize = 26.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.weight(1f))
                    IconButton(onClick = loaded.reload) { Icon(Icons.Filled.Refresh, contentDescription = "Refresh", tint = DriftColors.text) }
                    Box(Modifier.clip(CircleShape).clickable { Nav.open(Screen.Settings) }.padding(4.dp)) {
                        val a = YTViewer.account
                        if (a?.avatar != null) Avatarish(a.avatar, 34.dp) else Avatar(Social.me, 34.dp)
                    }
                }
                Row(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Chip("All", chip == 0) { chip = 0 }
                    Chip("20 min+", chip == 1) { chip = 1 }
                    Chip("Live", chip == 2) { chip = 2 }
                }
            }
        },
        filter = { v -> when (chip) { 1 -> (v.duration ?: 0.0) >= 1200; 2 -> v.live; else -> true } },
    )
}

@Composable
fun YTFeedScreen(feed: YTViewer.Feed) {
    VideoList(feed.title, rememberYT(feed) { YTViewer.feed(feed) }, "Nothing here yet.", back = true)
}

@Composable
fun YTSearchScreen() {
    var q by remember { mutableStateOf("") }
    var asked by remember { mutableStateOf("") }
    val loaded = rememberYT(asked) { if (asked.isBlank()) emptyList() else YTViewer.search(asked) }
    VideoList(
        title = "Search", loaded = loaded, empty = if (asked.isBlank()) "Search YouTube for videos." else "No videos found.", back = false,
        header = {
            OutlinedTextField(
                value = q, onValueChange = { q = it }, singleLine = true, placeholder = { Text("Search YouTube") },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = { asked = q.trim() }),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 12.dp),
            )
        },
    )
}

@Composable
fun YTSubscriptionsScreen() {
    val loaded = rememberYT("channels") { YTViewer.channels() }
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        item { PageTitle("Subscriptions") }
        val list = loaded.value
        when {
            list == null && loaded.error != null -> item { Failed(loaded.error, loaded.reload) }
            list == null -> item { Spinning() }
            list.isEmpty() -> item { EmptyText("Channels you subscribe to on YouTube show up here.") }
            else -> items(list, key = { it.id }) { c -> ChannelRow(c) }
        }
    }
}

@Composable
private fun ChannelRow(c: YTChannel) {
    Row(
        Modifier.fillMaxWidth().clickable { Nav.open(Screen.YTChannel(c.id)) }.padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Avatarish(c.avatar, 44.dp)
        Spacer(Modifier.width(12.dp))
        Text(c.name, color = DriftColors.text, fontSize = 15.sp, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (c.fresh) Box(Modifier.size(8.dp).clip(CircleShape).background(YTRed))
    }
}

@Composable
fun YTLibraryScreen() {
    LaunchedEffect(Unit) { YTViewer.loadAccount() }
    val a = YTViewer.account
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        item { PageTitle("Library") }
        item {
            Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Avatarish(a?.avatar, 56.dp)
                Spacer(Modifier.width(14.dp))
                Column {
                    Text(a?.name ?: "YouTube", color = DriftColors.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                    if (!a?.handle.isNullOrEmpty()) Text(a!!.handle, color = DriftColors.muted, fontSize = 13.sp)
                }
            }
        }
        item {
            Column(Modifier.padding(top = 8.dp)) {
                a?.channelId?.let { id -> LibraryRow(Icons.Filled.Person, "Your channel") { Nav.open(Screen.YTChannel(id)) } }
                LibraryRow(Icons.Filled.History, "History") { Nav.open(Screen.YTFeed(YTViewer.Feed.HISTORY)) }
                LibraryRow(Icons.Filled.Schedule, "Watch later") { Nav.open(Screen.YTFeed(YTViewer.Feed.WATCH_LATER)) }
                LibraryRow(Icons.Filled.ThumbUp, "Liked videos") { Nav.open(Screen.YTFeed(YTViewer.Feed.LIKED)) }
            }
        }
        item {
            Text(
                "Sign out of YouTube", color = DriftColors.muted, fontSize = 14.sp,
                modifier = Modifier.padding(16.dp).clickable {
                    YTViewer.signOut()
                    Nav.tab = Tab.HOME
                },
            )
        }
    }
}

@Composable
private fun LibraryRow(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).clickable(onClick = onClick).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = YTRed)
        Spacer(Modifier.width(16.dp))
        Text(label, color = DriftColors.text, fontSize = 16.sp)
    }
}

@Composable
fun YTChannelScreen(id: String) {
    val loaded = rememberYT(id) { YTViewer.channel(id) }
    val own = YTViewer.account?.channelId == id
    var subscribed by remember(id) { mutableStateOf<Boolean?>(null) }
    val channel = loaded.value?.first
    VideoList(
        title = channel?.name ?: "", back = true, empty = "No videos.",
        loaded = Loaded(loaded.value?.second, loaded.error, loaded.reload),
        header = {
            if (channel != null) {
                Row(Modifier.padding(horizontal = 16.dp).padding(bottom = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Avatarish(channel.avatar, 64.dp)
                    Spacer(Modifier.width(14.dp))
                    Text(channel.name, color = DriftColors.text, fontSize = 20.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.weight(1f))
                    if (own) Text("Your channel", color = DriftColors.muted, fontSize = 13.sp)
                    else SubscribeButton(id, subscribed ?: false) { subscribed = it }
                }
            }
        },
    )
}

@Composable
private fun SubscribeButton(channelId: String, subscribed: Boolean, onChange: (Boolean) -> Unit) {
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    Text(
        if (subscribed) "Subscribed" else "Subscribe",
        color = if (subscribed) DriftColors.text else Color.Black, fontSize = 13.sp, fontWeight = FontWeight.Bold,
        modifier = Modifier.clip(RoundedCornerShape(18.dp)).background(if (subscribed) DriftColors.surface2 else DriftColors.text)
            .clickable(enabled = !busy && channelId.isNotEmpty()) {
                busy = true
                scope.launch {
                    runCatching { YTViewer.subscribe(channelId, !subscribed) }
                        .onSuccess { onChange(!subscribed) }
                        .onFailure { com.lordxhobo.drift.social.Jam.notice = it.message }
                    busy = false
                }
            }.padding(horizontal = 16.dp, vertical = 9.dp),
    )
}

// MARK: Watching

@Composable
fun YTWatchScreen(id: String) {
    val loaded = rememberYT("video:$id") { YTViewer.video(id) }
    val d: YTVideoDetails? = loaded.value
    val scope = rememberCoroutineScope()
    val t = Playback.current?.takeIf { it.id == id }
    var subscribed by remember(id) { mutableStateOf<Boolean?>(null) }
    var more by remember(id) { mutableStateOf(false) }
    var started by remember(id) { mutableStateOf(false) }
    // Opened from a link, history or the mini player while something else plays: start this one.
    // (Even when its details didn't load.)
    LaunchedEffect(d, loaded.error) {
        if ((d != null || loaded.error != null) && !started && Playback.current?.id != id) {
            started = true
            playVideo(
                YTVideo(id, d?.title ?: "YouTube video", d?.channel?.name.orEmpty(), d?.channel?.id, "https://i.ytimg.com/vi/$id/hqdefault.jpg", null, d?.views.orEmpty(), d?.published.orEmpty(), false),
                d?.related.orEmpty(),
            )
        }
    }
    // This one ended and the next video started by itself: follow it, like YouTube.
    val now = Playback.current
    LaunchedEffect(now?.id) {
        if (now != null && now.id != id && now.watch == true && System.currentTimeMillis() - Playback.naturalEndAt < 3000 && Nav.top == Screen.YTWatch(id)) {
            Nav.open(Screen.YTWatch(now.id))
        }
    }
    val say: (String?) -> Unit = { com.lordxhobo.drift.social.Jam.notice = it }
    Column(Modifier.fillMaxSize()) {
        BackBar()
        if (t != null) YTPlayer(t) else Box(Modifier.fillMaxWidth().aspectRatio(16f / 9f).background(Color.Black), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = YTRed) }
        LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
            item {
                Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(d?.title ?: t?.title ?: "", color = DriftColors.text, fontSize = 18.sp, fontWeight = FontWeight.ExtraBold, lineHeight = 23.sp)
                    if (d != null) {
                        Text(
                            listOf(d.views, d.published).filter { it.isNotEmpty() }.joinToString(" · ") + if (d.description.isNotEmpty()) "  ·  ${if (more) "less" else "more"}" else "",
                            color = DriftColors.muted, fontSize = 12.sp, modifier = Modifier.clickable { more = !more },
                        )
                        if (more) Text(d.description, color = DriftColors.text2, fontSize = 13.sp, lineHeight = 18.sp)
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Row(Modifier.weight(1f).clickable { if (d.channel.id.isNotEmpty()) Nav.open(Screen.YTChannel(d.channel.id)) }, verticalAlignment = Alignment.CenterVertically) {
                                Avatarish(d.channel.avatar, 36.dp)
                                Spacer(Modifier.width(10.dp))
                                Column {
                                    Text(d.channel.name, color = DriftColors.text, fontSize = 15.sp, fontWeight = FontWeight.Bold, maxLines = 1)
                                    Text(d.subscribers, color = DriftColors.muted, fontSize = 12.sp)
                                }
                            }
                            if (YTViewer.account?.channelId != d.channel.id) SubscribeButton(d.channel.id, subscribed ?: d.subscribed) { subscribed = it }
                        }
                    }
                    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Action(Icons.Filled.ThumbUp, "Like") { scope.launch { runCatching { YTViewer.like(id) }.onSuccess { say("Liked") }.onFailure { say(it.message) } } }
                        Action(Icons.Filled.Schedule, "Watch later") { scope.launch { runCatching { YTViewer.watchLater(id) }.onSuccess { say("Saved to Watch later") }.onFailure { say(it.message) } } }
                        if (t != null) Action(Icons.Filled.Download, "Download") { Downloads.download(t); say("Downloading") }
                        if (t != null && Social.me != null) Action(Icons.AutoMirrored.Filled.Send, "Send") { Inbox.sending = t }
                        val sb = Skipping.sponsors
                        Row(
                            Modifier.clip(RoundedCornerShape(18.dp)).background(if (sb) Color(0xFF00D400).copy(alpha = 0.22f) else DriftColors.surface2)
                                .clickable { Skipping.changeSponsors(!sb) }.padding(horizontal = 14.dp, vertical = 9.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Box(Modifier.size(10.dp).clip(CircleShape).background(if (sb) Color(0xFF00D400) else DriftColors.muted))
                            Spacer(Modifier.width(6.dp))
                            Text("SponsorBlock ${if (sb) "on" else "off"}", color = DriftColors.text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
            }
            item { Comments(id, d?.commentsToken) }
            item { Text("Up next", color = DriftColors.text, fontSize = 16.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.padding(14.dp)) }
            val related = d?.related.orEmpty()
            items(related.take(20), key = { "next-" + it.id }) { v -> SmallVideoRow(v) { playVideo(v, related.drop(related.indexOf(v) + 1)) } }
        }
    }
}

@Composable
private fun Action(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    Row(
        Modifier.clip(RoundedCornerShape(18.dp)).background(DriftColors.surface2).clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = DriftColors.text, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text(label, color = DriftColors.text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** The video with YouTube-style controls: tap to show them, double-tap a side to jump 10 s, the timeline with SponsorBlock's parts. */
/**
 * The video with YouTube-style controls: tap to show them (and the timeline), double-tap a side to jump 10 s
 * (keep tapping that side for 20, 30, …), back and ahead 10 s buttons, quality and full screen. All of it hides
 * again after a few seconds of playing. Full screen uses the same, with X at the top right.
 */
@Composable
private fun YTPlayer(t: Track, fullScreen: Boolean = false, onClose: (() -> Unit)? = null) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var controls by remember { mutableStateOf(true) }
    // Bumped by anything done on the controls, so they stay up a while longer.
    var poke by remember { mutableStateOf(0) }
    LaunchedEffect(controls, Playback.isPlaying, poke) {
        if (controls && Playback.isPlaying) {
            kotlinx.coroutines.delay(3500)
            controls = false
        }
    }
    // Double-tap jumps: the tap before, and a run of jumps on one side.
    var lastTapAt by remember { mutableStateOf(0L) }
    var lastTapRight by remember { mutableStateOf(false) }
    var streakRight by remember { mutableStateOf<Boolean?>(null) }
    var streakTotal by remember { mutableStateOf(0) }
    var streakBase by remember { mutableStateOf(0L) }
    var streakUntil by remember { mutableStateOf(0L) }
    var pending by remember { mutableStateOf<kotlinx.coroutines.Job?>(null) }
    fun step() {
        streakTotal += 10
        streakUntil = System.currentTimeMillis() + 800
        val by = streakTotal * 1000L
        Playback.seek(if (streakRight == true) streakBase + by else (streakBase - by).coerceAtLeast(0))
        val total = streakTotal
        scope.launch {
            kotlinx.coroutines.delay(850)
            if (streakTotal == total) streakRight = null
        }
    }
    fun jump(by: Long) {
        Playback.seek((Playback.exactPosition() + by).coerceAtLeast(0))
        poke++
    }
    BoxWithConstraints(
        (if (fullScreen) Modifier.fillMaxSize() else Modifier.fillMaxWidth().aspectRatio(16f / 9f)).background(Color.Black),
        contentAlignment = Alignment.Center,
    ) {
        val w = if (fullScreen) minOf(maxWidth, maxHeight * 16f / 9f) else maxWidth
        EpisodeVideoView(t, w, fullScreen = fullScreen, buttons = false) {}
        // Taps and swipes anywhere on it.
        Box(
            Modifier.fillMaxSize().pointerInput(t.id) {
                // Swipe down: back to browsing (the video floats over the app), or out of full screen.
                var pulled = 0f
                detectVerticalDragGestures(
                    onDragStart = { pulled = 0f },
                    onDragEnd = {
                        if (pulled > 120.dp.toPx()) {
                            if (onClose != null) onClose() else if (Nav.top is Screen.YTWatch) Nav.back()
                        }
                    },
                ) { _, dy -> pulled += dy }
            }.pointerInput(t.id) {
                detectTapGestures(onTap = { o ->
                    val right = o.x > size.width / 2
                    val now = System.currentTimeMillis()
                    if (streakRight == right && now < streakUntil) {
                        step()
                    } else if (lastTapRight == right && now - lastTapAt < 300) {
                        // Two quick taps on one side: jump 10 s that way (the first tap does nothing).
                        pending?.cancel()
                        lastTapAt = 0
                        streakRight = right
                        streakTotal = 0
                        streakBase = Playback.exactPosition()
                        step()
                    } else {
                        lastTapAt = now
                        lastTapRight = right
                        pending?.cancel()
                        pending = scope.launch {
                            kotlinx.coroutines.delay(300)
                            controls = !controls
                        }
                    }
                })
            },
        )
        streakRight?.let { right ->
            // "+30 s" on the side being tapped.
            Box(Modifier.fillMaxSize(), contentAlignment = if (right) Alignment.CenterEnd else Alignment.CenterStart) {
                Column(
                    Modifier.fillMaxHeight().fillMaxWidth(0.32f).clip(RoundedCornerShape(50)).background(Color.White.copy(alpha = 0.12f)),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    Icon(if (right) Icons.Filled.FastForward else Icons.Filled.FastRewind, null, tint = Color.White, modifier = Modifier.size(22.dp))
                    Text((if (right) "+" else "−") + streakTotal + " s", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                }
            }
        }
        if (controls) {
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.25f)))
            val big = if (fullScreen) 54.dp else 44.dp
            Row(Modifier.align(Alignment.Center), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(if (fullScreen) 56.dp else 28.dp)) {
                RoundIcon(Icons.Filled.Replay10, "Back 10 seconds", big) { jump(-10_000) }
                RoundIcon(if (Playback.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (Playback.isPlaying) "Pause" else "Play", big + 12.dp) {
                    Playback.toggle()
                    poke++
                }
                RoundIcon(Icons.Filled.Forward10, "Ahead 10 seconds", big) { jump(10_000) }
            }
            Row(
                Modifier.align(Alignment.TopEnd).padding(horizontal = if (fullScreen) 20.dp else 8.dp, vertical = if (fullScreen) 16.dp else 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                VideoQualityButton(t)
                if (onClose != null) {
                    RoundIcon(Icons.Filled.Close, "Close full screen", 40.dp) { onClose() }
                } else {
                    RoundIcon(Icons.Filled.Fullscreen, "Full screen", 34.dp) { openVideoFullScreen(context) }
                }
            }
            Column(
                Modifier.align(Alignment.BottomCenter).fillMaxWidth()
                    .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.7f))))
                    .padding(horizontal = if (fullScreen) 28.dp else 12.dp, vertical = if (fullScreen) 14.dp else 6.dp),
            ) {
                Text(
                    "${formatSeconds(Playback.position / 1000.0)} / ${formatSeconds(Playback.duration / 1000.0)}",
                    color = Color.White, fontSize = if (fullScreen) 14.sp else 12.sp, fontWeight = FontWeight.SemiBold,
                )
                Timeline(onUse = { poke++ })
            }
        } else {
            // A thin line along the bottom while the controls are hidden.
            Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(3.dp)) { Timeline(thin = true) }
        }
    }
}

/** Full screen for videos from the YouTube viewer: the same controls, sideways, X at the top right. */
@Composable
fun YTFullScreen(t: Track) {
    val context = LocalContext.current
    val onClose = { closeVideoFullScreen(context) }
    androidx.compose.ui.window.Dialog(
        onDismissRequest = onClose,
        properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        YTPlayer(t, fullScreen = true, onClose = onClose)
    }
}

@Composable
private fun RoundIcon(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, size: androidx.compose.ui.unit.Dp, onClick: () -> Unit) {
    Box(Modifier.size(size).clip(CircleShape).background(Color.Black.copy(alpha = 0.45f)).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, contentDescription = label, tint = Color.White, modifier = Modifier.size(size * 0.55f))
    }
}

/** The SponsorBlock extension's colors, so the parts look the same everywhere. */
fun segmentColor(category: String): Color = when (category) {
    "sponsor" -> Color(0xFF00D400)
    "selfpromo" -> Color(0xFFFFFF00)
    "interaction" -> Color(0xFFCC00FF)
    "intro" -> Color(0xFF00FFFF)
    "outro" -> Color(0xFF0202ED)
    "preview" -> Color(0xFF008FD6)
    else -> Color(0xFFFF9900)
}

/** The timeline: played part, SponsorBlock's parts on top, drag or tap to jump. */
@Composable
private fun Timeline(thin: Boolean = false, onUse: () -> Unit = {}) {
    val duration = Playback.duration.coerceAtLeast(1)
    var drag by remember { mutableStateOf<Float?>(null) }
    val fraction = drag ?: (Playback.position.toFloat() / duration).coerceIn(0f, 1f)
    val segments = if (Skipping.sponsors) Skipping.shown else emptyList()
    Canvas(
        Modifier.fillMaxWidth().height(if (thin) 3.dp else 22.dp).then(
            if (thin) Modifier else Modifier
                .pointerInput(duration) { detectTapGestures { o -> Playback.seek((o.x / size.width * duration).toLong()); onUse() } }
                .pointerInput(duration) {
                    detectHorizontalDragGestures(
                        onDragStart = { o -> drag = (o.x / size.width).coerceIn(0f, 1f); onUse() },
                        onDragEnd = { drag?.let { Playback.seek((it * duration).toLong()) }; drag = null; onUse() },
                        onDragCancel = { drag = null },
                    ) { change, _ -> drag = (change.position.x / size.width).coerceIn(0f, 1f) }
                },
        ),
    ) {
        val h = if (thin) size.height else 4.dp.toPx()
        val y = (size.height - h) / 2
        drawRoundRect(Color.White.copy(alpha = 0.3f), Offset(0f, y), Size(size.width, h), CornerRadius(h / 2))
        drawRoundRect(YTRed, Offset(0f, y), Size(size.width * fraction, h), CornerRadius(h / 2))
        val secs = duration / 1000f
        for (s in segments) {
            val x0 = (s.start.toFloat() / secs).coerceIn(0f, 1f) * size.width
            val x1 = (s.end.toFloat() / secs).coerceIn(0f, 1f) * size.width
            drawRect(segmentColor(s.category).copy(alpha = 0.9f), Offset(x0, y), Size((x1 - x0).coerceAtLeast(2f), h))
        }
        if (!thin) drawCircle(YTRed, radius = 6.dp.toPx(), center = Offset(size.width * fraction, size.height / 2))
    }
}

// MARK: Comments

@Composable
private fun Comments(videoId: String, start: String?) {
    val scope = rememberCoroutineScope()
    var newest by remember(videoId) { mutableStateOf(false) }
    var newestToken by remember(videoId) { mutableStateOf<String?>(null) }
    var postParams by remember(videoId) { mutableStateOf<String?>(null) }
    var list by remember(videoId) { mutableStateOf<List<YTComment>?>(null) }
    var more by remember(videoId) { mutableStateOf<String?>(null) }
    var error by remember(videoId) { mutableStateOf<String?>(null) }
    var draft by remember(videoId) { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    val token = if (newest) newestToken else start
    LaunchedEffect(token) {
        if (token == null) {
            list = if (start == null) emptyList() else null
            return@LaunchedEffect
        }
        list = null
        runCatching { YTViewer.comments(token) }
            .onSuccess { p ->
                list = p.comments
                more = p.more
                if (p.newest != null) newestToken = p.newest
                if (p.postParams != null) postParams = p.postParams
            }
            .onFailure { error = it.message; list = emptyList() }
    }
    Column(Modifier.padding(horizontal = 14.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Comments", color = DriftColors.text, fontSize = 16.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.padding(end = 6.dp))
            Chip("Top", !newest) { newest = false }
            if (newestToken != null) Chip("Newest", newest) { newest = true }
        }
        if (postParams != null) {
            OutlinedTextField(
                value = draft, onValueChange = { draft = it.take(10_000) }, placeholder = { Text("Add a comment…") },
                modifier = Modifier.fillMaxWidth(), maxLines = 4,
                trailingIcon = {
                    if (draft.isNotBlank()) IconButton(enabled = !busy, onClick = {
                        val text = draft.trim()
                        busy = true
                        scope.launch {
                            runCatching { YTViewer.postComment(postParams!!, text) }
                                .onSuccess {
                                    val a = YTViewer.account
                                    list = listOf(YTComment("mine-${System.currentTimeMillis()}", a?.handle?.ifEmpty { null } ?: a?.name ?: "You", a?.avatar, a?.channelId, text, "just now", "", 0, false, false)) + list.orEmpty()
                                    draft = ""
                                }
                                .onFailure { com.lordxhobo.drift.social.Jam.notice = it.message }
                            busy = false
                        }
                    }) { Icon(Icons.AutoMirrored.Filled.Send, contentDescription = "Comment", tint = YTRed) }
                },
            )
        }
        val l = list
        when {
            l == null -> Spinning()
            l.isEmpty() -> Text(error ?: "No comments.", color = DriftColors.muted, fontSize = 13.sp)
            else -> l.forEach { c -> CommentRow(c) }
        }
        val next = more
        if (next != null && !l.isNullOrEmpty()) {
            Chip("More comments", false) {
                scope.launch {
                    runCatching { YTViewer.comments(next) }.onSuccess { p ->
                        list = list.orEmpty() + p.comments
                        more = p.more
                    }
                }
            }
        }
    }
}

@Composable
private fun CommentRow(c: YTComment) {
    Row {
        Avatarish(c.authorAvatar, 34.dp)
        Spacer(Modifier.width(10.dp))
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (c.pinned) Text("Pinned", color = DriftColors.muted, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                Text(
                    c.author, color = DriftColors.text, fontSize = 12.sp, fontWeight = FontWeight.Bold,
                    modifier = Modifier.then(if (c.byCreator) Modifier.clip(RoundedCornerShape(10.dp)).background(DriftColors.surface2).padding(horizontal = 6.dp, vertical = 1.dp) else Modifier)
                        .clickable(enabled = c.authorChannelId != null) { c.authorChannelId?.let { Nav.open(Screen.YTChannel(it)) } },
                )
                Text(c.published, color = DriftColors.muted, fontSize = 11.sp)
            }
            Text(c.text, color = DriftColors.text, fontSize = 14.sp, lineHeight = 19.sp)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Filled.ThumbUp, contentDescription = null, tint = DriftColors.muted, modifier = Modifier.size(12.dp))
                Text(c.likes, color = DriftColors.muted, fontSize = 11.sp)
                if (c.replies > 0) Text(if (c.replies == 1) "1 reply" else "${c.replies} replies", color = DriftColors.muted, fontSize = 11.sp)
            }
        }
    }
}

// The floating video

/**
 * The video playing, floating over the app while its watch page isn't open (swiped down, or another page
 * opened over it), like YouTube's mini player: drag it anywhere, pinch it or drag its corner to resize (from
 * half the screen's width to all of it), tap it to go back to the video, X to stop it.
 */
@Composable
fun YTPictureInPicture() {
    val t = Playback.current
    if (!YTViewer.on || t == null || t.watch != true || UiState.showPlayer || Nav.top == Screen.YTWatch(t.id)) return
    BoxWithConstraints(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().padding(bottom = 64.dp)) {
        val density = androidx.compose.ui.platform.LocalDensity.current
        val margin = with(density) { 10.dp.toPx() }
        val screenW = with(density) { maxWidth.toPx() }
        val screenH = with(density) { maxHeight.toPx() }
        val minW = screenW * 0.5f
        val maxW = screenW - margin * 2
        var w by remember { mutableStateOf(screenW * 0.62f) }
        val h = w * 9f / 16f
        // Its top-left corner (starts at the bottom right).
        var x by remember { mutableStateOf(Float.NaN) }
        var y by remember { mutableStateOf(Float.NaN) }
        fun clamp() {
            w = w.coerceIn(minW, maxW)
            val hh = w * 9f / 16f
            if (x.isNaN()) x = screenW - margin - w
            if (y.isNaN()) y = screenH - margin - hh
            x = x.coerceIn(margin, (screenW - margin - w).coerceAtLeast(margin))
            y = y.coerceIn(margin, (screenH - margin - hh).coerceAtLeast(margin))
        }
        clamp()
        Box(
            Modifier
                .offset { IntOffset(x.toInt(), y.toInt()) }
                .size(with(density) { w.toDp() }, with(density) { h.toDp() })
                .shadow(14.dp, RoundedCornerShape(12.dp))
                .clip(RoundedCornerShape(12.dp))
                .background(Color.Black)
                .pointerInput(Unit) {
                    detectTransformGestures { centroid, pan, zoom, _ ->
                        val oldW = w
                        w = (w * zoom).coerceIn(minW, maxW)
                        // Grow around the fingers.
                        x += pan.x - (w - oldW) * (centroid.x / oldW)
                        y += pan.y - (w - oldW) * 9f / 16f * (centroid.y / (oldW * 9f / 16f))
                        clamp()
                    }
                }
                .pointerInput(t.id) { detectTapGestures(onTap = { Nav.open(Screen.YTWatch(t.id)) }) },
        ) {
            PiPVideo()
            // Until the picture is there: its thumbnail (not a black box).
            val web = com.lordxhobo.drift.playback.YTWeb
            if (Playback.isBuffering || !(if (web.active) web.ready && !web.ad else EpisodeVideo.ready)) {
                AsyncImage(model = t.artwork(480), contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize().alpha(0.6f))
            }
            if (Playback.isBuffering) CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.align(Alignment.Center).size(26.dp))
            // Drag the corner to make it bigger or smaller.
            Box(
                Modifier.align(Alignment.TopStart).padding(6.dp).size(30.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.6f))
                    .pointerInput(Unit) {
                        detectDragGestures { change, drag ->
                            change.consume()
                            val oldW = w
                            w = (w - (drag.x + drag.y) / 2f).coerceIn(minW, maxW)
                            // The other corner stays put.
                            x -= w - oldW
                            y -= (w - oldW) * 9f / 16f
                            clamp()
                        }
                    },
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Filled.OpenInFull, "Resize", tint = Color.White, modifier = Modifier.size(16.dp)) }
            Box(
                Modifier.align(Alignment.TopEnd).padding(6.dp).size(30.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.6f))
                    .clickable { Playback.close() },
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Filled.Close, "Close video", tint = Color.White, modifier = Modifier.size(18.dp)) }
            Box(
                Modifier.align(Alignment.BottomStart).padding(6.dp).size(32.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.6f))
                    .clickable { Playback.toggle() },
                contentAlignment = Alignment.Center,
            ) {
                Icon(if (Playback.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (Playback.isPlaying) "Pause" else "Play", tint = Color.White, modifier = Modifier.size(18.dp))
            }
            val progress = if (Playback.duration > 0) (Playback.position.toFloat() / Playback.duration).coerceIn(0f, 1f) else 0f
            Box(Modifier.align(Alignment.BottomStart).fillMaxWidth(progress).height(2.dp).background(YTRed))
        }
    }
}

/** The picture itself (the same player as the watch page, so nothing loads twice). */
@Composable
private fun PiPVideo() {
    if (com.lordxhobo.drift.playback.YTWeb.active) {
        YTWebVideo()
        return
    }
    val context = LocalContext.current
    val view = remember { android.view.TextureView(context) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(view, lifecycle) {
        val watcher = LifecycleEventObserver { _, e ->
            when (e) {
                Lifecycle.Event.ON_START -> EpisodeVideo.attach(view)
                Lifecycle.Event.ON_STOP -> EpisodeVideo.detach(view)
                else -> {}
            }
        }
        if (lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) EpisodeVideo.attach(view)
        lifecycle.addObserver(watcher)
        onDispose {
            lifecycle.removeObserver(watcher)
            EpisodeVideo.detach(view)
        }
    }
    AndroidView(factory = { view }, modifier = Modifier.fillMaxSize())
}
