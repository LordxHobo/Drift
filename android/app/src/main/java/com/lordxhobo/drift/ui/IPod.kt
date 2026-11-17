package com.lordxhobo.drift.ui

import android.content.Context
import android.media.AudioManager
import android.view.HapticFeedbackConstants
import android.view.View
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.Check
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import androidx.compose.runtime.withFrameMillis
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.material.icons.filled.FastForward
import androidx.compose.material.icons.filled.FastRewind
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import com.lordxhobo.drift.data.Library
import com.lordxhobo.drift.data.Playlist
import com.lordxhobo.drift.data.Track
import com.lordxhobo.drift.playback.Downloads
import com.lordxhobo.drift.playback.Playback
import kotlinx.coroutines.delay
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.roundToInt
import kotlin.math.sign

/**
 * The iPod theme: Cover Flow and a click wheel, one thumb at a time. Menu (top of the ring) goes back, the
 * centre button selects, play/pause and skipping sit on the ring. Now playing: the wheel sets the volume,
 * and Select switches it to seeking (back to volume a few seconds after you stop).
 */
object IPod {
    /** The theme is on (instead of Drift's own look). */
    var on by mutableStateOf(false)
        private set
    /** Its style (only the click wheel so far). */
    var style by mutableStateOf("wheel")
        private set
    var haptics by mutableStateOf(true)
        private set
    var clicks by mutableStateOf(false)
        private set
    /** Showing one of Drift's own pages (Settings, Search) over the theme for a moment. */
    var away by mutableStateOf(false)

    private lateinit var app: Context
    private val prefs get() = app.getSharedPreferences("drift.settings", Context.MODE_PRIVATE)

    fun init(context: Context) {
        app = context.applicationContext
        on = prefs.getBoolean("ipodTheme", false)
        style = prefs.getString("ipodStyle", "wheel") ?: "wheel"
        haptics = prefs.getBoolean("ipodHaptics", true)
        clicks = prefs.getBoolean("ipodClicks", false)
    }

    fun turn(value: Boolean) {
        on = value
        away = false
        prefs.edit().putBoolean("ipodTheme", value).apply()
    }

    fun choose(s: String) {
        style = s
        prefs.edit().putString("ipodStyle", s).apply()
    }

    fun changeHaptics(value: Boolean) {
        haptics = value
        prefs.edit().putBoolean("ipodHaptics", value).apply()
    }

    fun changeClicks(value: Boolean) {
        clicks = value
        prefs.edit().putBoolean("ipodClicks", value).apply()
    }

    val styles = listOf(
        Triple("wheel", "Click wheel", "Cover Flow and a full click wheel."),
        Triple("summoned", "Summoned wheel", "All covers; hold anywhere for a wheel."),
        Triple("crate", "Record crate", "Flip through sleeves; play on a turntable."),
        Triple("arc", "Thumb arc", "A dial along the bottom edge."),
    )

    /** One step of the wheel. */
    fun tick(view: View) {
        if (haptics) view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
        if (clicks) audio()?.playSoundEffect(AudioManager.FX_KEY_CLICK, 0.6f)
    }

    /** A button on the wheel. */
    fun pressed(view: View) {
        if (haptics) view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
        if (clicks) audio()?.playSoundEffect(AudioManager.FX_KEY_CLICK, 0.6f)
    }

    /** The end of a list: can't go further. */
    fun bump(view: View) {
        if (haptics) view.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
    }

    fun audio(): AudioManager? = if (::app.isInitialized) app.getSystemService(Context.AUDIO_SERVICE) as? AudioManager else null

    /** The phone's media volume, 0–1. */
    fun volume(): Float {
        val a = audio() ?: return 0f
        val max = a.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
        return a.getStreamVolume(AudioManager.STREAM_MUSIC).toFloat() / max
    }

    /** Media volume up or down by whole steps (no system pop-up). */
    fun changeVolume(steps: Int) {
        val a = audio() ?: return
        val max = a.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        val now = a.getStreamVolume(AudioManager.STREAM_MUSIC)
        a.setStreamVolume(AudioManager.STREAM_MUSIC, (now + steps).coerceIn(0, max), 0)
    }
}

// MARK: Settings

/** In Settings: the theme switch, its styles, and haptics and the click sound. */
@Composable
fun IPodThemeSettings() {
    Column(
        Modifier.padding(horizontal = 16.dp, vertical = 6.dp).fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(DriftColors.surface).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text("Theme", color = DriftColors.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(DriftColors.bg).padding(4.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            for ((value, label) in listOf(false to "Drift", true to "iPod")) {
                val picked = IPod.on == value
                Box(
                    Modifier.weight(1f).height(40.dp).clip(RoundedCornerShape(9.dp)).background(if (picked) DriftColors.surface2 else Color.Transparent)
                        .clickable { IPod.turn(value) },
                    contentAlignment = Alignment.Center,
                ) { Text(label, color = if (picked) DriftColors.text else DriftColors.muted, fontSize = 13.sp, fontWeight = FontWeight.Bold) }
            }
        }
        Text(
            if (IPod.on) "Browse with one thumb, like an iPod: Cover Flow and a click wheel. Settings is in its main menu." else "Drift's own look.",
            color = DriftColors.muted, fontSize = 12.sp,
        )
        if (IPod.on) {
            for (row in IPod.styles.chunked(2)) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    for ((id, name, detail) in row) {
                        val available = true
                        val picked = IPod.style == id
                        Column(
                            Modifier.weight(1f).heightIn(min = 72.dp).clip(RoundedCornerShape(12.dp)).background(DriftColors.bg)
                                .border(2.dp, if (picked) DriftColors.accent else Color.Transparent, RoundedCornerShape(12.dp))
                                .clickable(enabled = available) { IPod.choose(id) }.padding(10.dp),
                            verticalArrangement = Arrangement.spacedBy(3.dp),
                        ) {
                            Text(name, color = if (available) DriftColors.text else DriftColors.muted, fontSize = 13.sp, fontWeight = FontWeight.Bold)
                            Text(if (available) detail else "Coming soon", color = DriftColors.muted, fontSize = 11.sp)
                        }
                    }
                }
            }
            SwitchRow("Haptics", IPod.haptics) { IPod.changeHaptics(it) }
            SwitchRow("Click sound", IPod.clicks) { IPod.changeClicks(it) }
        }
    }
}

@Composable
private fun SwitchRow(title: String, on: Boolean, change: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().clickable { change(!on) }, verticalAlignment = Alignment.CenterVertically) {
        Text(title, color = DriftColors.text, fontSize = 14.sp, modifier = Modifier.weight(1f))
        Switch(checked = on, onCheckedChange = change, colors = SwitchDefaults.colors(checkedThumbColor = DriftColors.onAccent, checkedTrackColor = DriftColors.accent))
    }
}

// MARK: The theme

private sealed interface IPodScreen {
    data object Menu : IPodScreen
    data class Covers(val shelf: String) : IPodScreen
    data class Songs(val title: String, val tracks: List<Track>) : IPodScreen
    data object NowPlaying : IPodScreen
}

private class Cover(val id: String, val title: String, val subtitle: String, val tracks: List<Track>, val playlist: Playlist? = null)

private class MenuItem(val title: String, val action: () -> Unit)

private fun allSongs(): List<Track> {
    val seen = HashSet<String>()
    return (Library.liked + Library.playlists.flatMap { it.tracks })
        .filter { !it.isEpisode && seen.add(it.id) }
        .sortedBy { it.title.lowercase() }
}

private fun covers(shelf: String): List<Cover> = when (shelf) {
    "Playlists" -> Library.playlists.filter { it.isAlbum != true }.map { Cover(it.id, it.name, "${it.tracks.size} songs", it.tracks, it) }
    "Albums" -> Library.playlists.filter { it.isAlbum == true }.map { Cover(it.id, it.name, it.albumArtist ?: "", it.tracks, it) }
    else -> allSongs().filter { it.artist.isNotBlank() }.groupBy { it.artist.trim() }.toSortedMap(String.CASE_INSENSITIVE_ORDER)
        .map { (name, list) -> Cover("artist-$name", name, if (list.size == 1) "1 song" else "${list.size} songs", list) }
}

private fun time(ms: Long): String {
    val s = (ms / 1000).coerceAtLeast(0)
    return "%d:%02d".format(s / 60, s % 60)
}

/** The whole screen in the iPod theme (over the rest of Drift). */
@Composable
fun IPodRoot() {
    val view = LocalView.current
    val stack = remember { mutableStateListOf<IPodScreen>(IPodScreen.Menu) }
    val picks = remember { mutableStateListOf(0) }
    var seeking by remember { mutableStateOf(false) }
    var lastTurn by remember { mutableLongStateOf(0L) }
    var volume by remember { mutableStateOf(IPod.volume()) }
    val screen = stack.last()
    val pick = picks.last()

    fun push(s: IPodScreen) {
        stack.add(s)
        picks.add(0)
    }

    fun menu() {
        if (stack.size <= 1) return
        seeking = false
        stack.removeAt(stack.lastIndex)
        picks.removeAt(picks.lastIndex)
    }

    val menuItems = buildList {
        if (Playback.current != null) add(MenuItem("Now playing") { push(IPodScreen.NowPlaying) })
        add(MenuItem("Playlists") { push(IPodScreen.Covers("Playlists")) })
        add(MenuItem("Albums") { push(IPodScreen.Covers("Albums")) })
        add(MenuItem("Artists") { push(IPodScreen.Covers("Artists")) })
        add(MenuItem("Songs") { push(IPodScreen.Songs("Songs", allSongs())) })
        add(MenuItem("Liked songs") { push(IPodScreen.Songs("Liked songs", Library.liked)) })
        add(MenuItem("Recently played") { push(IPodScreen.Songs("Recently played", Library.recent)) })
        add(MenuItem("Downloads") { push(IPodScreen.Songs("Downloads", Downloads.songs.values.map { it.track })) })
        add(MenuItem("Search") {
            IPod.away = true
            Nav.select(Tab.SEARCH)
        })
        add(MenuItem("Settings") {
            IPod.away = true
            if (Nav.top != Screen.Settings) Nav.open(Screen.Settings)
        })
    }

    fun count(s: IPodScreen): Int = when (s) {
        IPodScreen.Menu -> menuItems.size
        is IPodScreen.Covers -> covers(s.shelf).size
        is IPodScreen.Songs -> s.tracks.size
        IPodScreen.NowPlaying -> 0
    }

    fun turn(steps: Int) {
        if (screen == IPodScreen.NowPlaying) {
            if (seeking) {
                Playback.seek((Playback.position + steps * 5000L).coerceIn(0L, Playback.duration.coerceAtLeast(0L)))
            } else {
                IPod.changeVolume(steps)
                volume = IPod.volume()
            }
            lastTurn = System.currentTimeMillis()
            IPod.tick(view)
            return
        }
        val n = count(screen)
        if (n == 0) return
        val moved = (pick + steps).coerceIn(0, n - 1)
        if (moved == pick) {
            IPod.bump(view)
            return
        }
        picks[picks.lastIndex] = moved
        IPod.tick(view)
    }

    fun select() {
        when (val s = screen) {
            IPodScreen.Menu -> menuItems.getOrNull(pick)?.action?.invoke()
            is IPodScreen.Covers -> covers(s.shelf).getOrNull(pick)?.let { push(IPodScreen.Songs(it.title, it.tracks)) }
            is IPodScreen.Songs -> if (pick < s.tracks.size) {
                Playback.play(s.tracks, pick, s.title)
                push(IPodScreen.NowPlaying)
            }
            IPodScreen.NowPlaying -> {
                seeking = !seeking
                lastTurn = System.currentTimeMillis()
            }
        }
    }

    // Seeking goes back to the volume a few seconds after the wheel was last turned (like the iPod).
    LaunchedEffect(lastTurn, seeking) {
        if (seeking) {
            delay(5000)
            seeking = false
        }
    }
    // Nothing playing any more: leave the now playing screen.
    LaunchedEffect(Playback.current?.id) {
        if (Playback.current == null && screen == IPodScreen.NowPlaying) menu()
        volume = IPod.volume()
    }
    // The phone's back gesture works like Menu.
    BackHandler(enabled = stack.size > 1) { menu() }

    fun titleOf(s: IPodScreen): String = when (s) {
        IPodScreen.Menu -> "Drift"
        is IPodScreen.Covers -> s.shelf
        is IPodScreen.Songs -> s.title
        IPodScreen.NowPlaying -> "Now playing"
    }

    // The summoned wheel's lists: a tap on a row opens that row.
    fun tapped(i: Int) {
        picks[picks.lastIndex] = i
        select()
    }

    val style = IPod.style
    val back = style != "wheel" && stack.size > 1
    val header: @Composable () -> Unit = {
        Column(Modifier.fillMaxWidth().padding(horizontal = 22.dp, vertical = 8.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                if (back) {
                    // The click wheel has Menu on its ring; the other styles go back from here.
                    Row(
                        Modifier.weight(1f).heightIn(min = 32.dp).clickable {
                            IPod.pressed(view)
                            menu()
                        }.semantics { contentDescription = "Back" },
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, null, tint = DriftColors.muted, modifier = Modifier.size(18.dp))
                        Text(titleOf(stack[stack.size - 2]), color = DriftColors.muted, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                } else {
                    Text(if (stack.size < 2) "iPod" else stack.dropLast(1).joinToString(" › ") { titleOf(it) }, color = DriftColors.muted, fontSize = 13.sp, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                val n = count(screen)
                if (n > 0) Text("${pick + 1} of $n", color = DriftColors.muted, fontSize = 13.sp)
            }
            Text(titleOf(screen), color = DriftColors.text, fontSize = if (style == "crate") 24.sp else 30.sp, fontWeight = FontWeight.ExtraBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
    val content: @Composable (Modifier) -> Unit = { m ->
        Box(m, contentAlignment = Alignment.Center) {
            when (val s = screen) {
                IPodScreen.Menu -> {
                    val rows = menuItems.map { Triple(it.title, null, null) }
                    if (style == "summoned") IPodTapList(rows, pick, onTap = { tapped(it) }, onTurn = { turn(it) }) else IPodList(rows, pick)
                }
                is IPodScreen.Covers -> {
                    val items = covers(s.shelf)
                    if (items.isEmpty()) Text(if (s.shelf == "Albums") "Albums you save show up here." else "Nothing here yet.", color = DriftColors.muted)
                    else if (style == "crate") IPodCrate(items, pick.coerceAtMost(items.size - 1))
                    else CoverFlow(items, pick.coerceAtMost(items.size - 1))
                }
                is IPodScreen.Songs ->
                    if (s.tracks.isEmpty()) Text("No songs.", color = DriftColors.muted)
                    else {
                        val rows = s.tracks.map { Triple(it.title, it.artist, it.durationText.ifEmpty { null }) }
                        val at = pick.coerceAtMost(s.tracks.size - 1)
                        if (style == "summoned") IPodTapList(rows, at, onTap = { tapped(it) }, onTurn = { turn(it) }) else IPodList(rows, at)
                    }
                IPodScreen.NowPlaying -> IPodNowPlaying(seeking, volume)
            }
        }
    }
    val openNow = {
        if (Playback.current != null && screen != IPodScreen.NowPlaying) {
            IPod.pressed(view)
            push(IPodScreen.NowPlaying)
        }
    }
    // What's playing (opens Now playing).
    val chip: @Composable ColumnScope.() -> Unit = {
        val t = Playback.current
        if (t != null && screen != IPodScreen.NowPlaying) {
            Row(
                Modifier.align(Alignment.CenterHorizontally).padding(vertical = 8.dp).clip(RoundedCornerShape(50)).background(DriftColors.surface)
                    .clickable { openNow() }.padding(horizontal = 14.dp, vertical = 7.dp).widthIn(max = 320.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(if (Playback.isPlaying) Icons.Filled.GraphicEq else Icons.Filled.Pause, null, tint = DriftColors.accent, modifier = Modifier.size(14.dp))
                Text(t.title, color = DriftColors.text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                Text(t.artist, color = DriftColors.muted, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
            }
        } else {
            Spacer(Modifier.height(16.dp))
        }
    }

    Box(Modifier.fillMaxSize().background(DriftColors.bg).statusBarsPadding().navigationBarsPadding()) {
        when (style) {
            // Swipe to flip, tap to open; hold anywhere for a wheel under your thumb.
            "summoned" -> Column(Modifier.fillMaxSize()) {
                header()
                Box(Modifier.weight(1f).fillMaxWidth()) {
                    content(Modifier.fillMaxSize())
                    // Lists scroll and take taps themselves (IPodTapList); covers and Now playing: swipes.
                    if (screen !is IPodScreen.Menu && screen !is IPodScreen.Songs) {
                        IPodGestures(horizontal = screen is IPodScreen.Covers, summon = true, onTurn = { turn(it) }, onTap = { select() })
                    }
                }
                IPodMiniBar(openNow)
            }
            // A turntable on top (the song playing), the crate (or a list) below.
            "crate" -> Column(Modifier.fillMaxSize()) {
                IPodTurntable()
                header()
                Box(Modifier.weight(1f).fillMaxWidth()) {
                    content(Modifier.fillMaxSize())
                    IPodGestures(horizontal = false, summon = false, onTurn = { turn(it) }, onTap = { select() })
                }
            }
            // A dial rising from the bottom edge.
            "arc" -> {
                Column(Modifier.fillMaxSize()) {
                    header()
                    content(Modifier.weight(1f).fillMaxWidth())
                    chip()
                    Spacer(Modifier.height(196.dp))
                }
                IPodArcDial(
                    onTurn = { turn(it) }, onBack = { menu() }, onSelect = { select() },
                    onPrevious = { Playback.previous() }, onNext = { Playback.next() },
                    modifier = Modifier.align(Alignment.BottomCenter),
                )
            }
            else -> Column(Modifier.fillMaxSize()) {
                header()
                content(Modifier.weight(1f).fillMaxWidth())
                chip()
                ClickWheel(
                    onTurn = { turn(it) },
                    onMenu = { menu() },
                    onSelect = { select() },
                    onPrevious = { Playback.previous() },
                    onNext = { Playback.next() },
                    onPlayPause = { Playback.toggle() },
                    modifier = Modifier.align(Alignment.CenterHorizontally).padding(bottom = 18.dp),
                )
            }
        }
    }
}

/** Back to the iPod theme from one of Drift's pages (Settings, Search). */
@Composable
fun IPodReturn(modifier: Modifier = Modifier) {
    Box(
        modifier.statusBarsPadding().padding(top = 8.dp, end = 12.dp).clip(RoundedCornerShape(50)).background(DriftColors.accent)
            .clickable { IPod.away = false }.padding(horizontal = 14.dp, vertical = 8.dp),
    ) { Text("Back to iPod", color = DriftColors.onAccent, fontSize = 13.sp, fontWeight = FontWeight.Bold) }
}

// MARK: Lists

@Composable
private fun IPodList(rows: List<Triple<String, String?, String?>>, selected: Int) {
    val state = rememberLazyListState()
    LaunchedEffect(selected) { state.animateScrollToItem((selected - 3).coerceAtLeast(0)) }
    LazyColumn(state = state, userScrollEnabled = false, modifier = Modifier.fillMaxSize().padding(horizontal = 12.dp)) {
        itemsIndexed(rows) { i, row ->
            val on = i == selected
            Row(
                Modifier.fillMaxWidth().heightIn(min = 46.dp).padding(vertical = 1.dp).clip(RoundedCornerShape(10.dp))
                    .background(if (on) DriftColors.accent else Color.Transparent).padding(horizontal = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                val color = if (on) DriftColors.onAccent else DriftColors.text
                Column(Modifier.weight(1f)) {
                    Text(row.first, color = color, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    row.second?.let { Text(it, color = color.copy(alpha = 0.7f), fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                }
                when {
                    row.third != null -> Text(row.third!!, color = color.copy(alpha = 0.7f), fontSize = 13.sp)
                    row.second == null -> Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = color.copy(alpha = 0.6f))
                }
            }
        }
    }
}

// MARK: Cover Flow

@Composable
private fun CoverFlow(items: List<Cover>, selected: Int) {
    val at by animateFloatAsState(selected.toFloat(), tween(220), label = "coverflow")
    val density = LocalDensity.current
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val big = minOf(maxWidth * 0.58f, maxHeight - 90.dp).coerceAtLeast(60.dp)
        val small = big * 0.74f
        Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Box(Modifier.fillMaxWidth().height(big), contentAlignment = Alignment.Center) {
                items.forEachIndexed { i, c ->
                    val d = i - at
                    val ad = abs(d)
                    if (ad <= 4.5f) {
                        val near = (1f - ad).coerceIn(0f, 1f)
                        val size = small + (big - small) * near
                        val side = sign(d)
                        val x = if (ad < 1f) d * (big.value * 0.55f) else side * (big.value * 0.55f + (ad - 1f) * small.value * 0.28f)
                        Box(
                            Modifier.zIndex(10f - ad).offset { IntOffset(with(density) { x.dp.roundToPx() }, with(density) { ((big - size) / 2).roundToPx() }) }
                                .size(size)
                                .graphicsLayer {
                                    rotationY = -side * 62f * ad.coerceAtMost(1f)
                                    cameraDistance = 14f * density.density
                                    alpha = when {
                                        ad >= 4f -> 0f
                                        ad >= 3f -> 0.45f
                                        else -> 1f
                                    }
                                }
                                .shadow(16.dp, RoundedCornerShape(10.dp)),
                        ) {
                            if (c.playlist != null) PlaylistCover(c.playlist, size) else Artwork(c.tracks.firstOrNull()?.artwork(600), c.id, size, RoundedCornerShape(10.dp))
                        }
                    }
                }
            }
            items.getOrNull(selected)?.let { c ->
                Spacer(Modifier.height(14.dp))
                Text(c.title, color = DriftColors.text, fontSize = 19.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(horizontal = 24.dp))
                Text(c.subtitle, color = DriftColors.muted, fontSize = 14.sp, maxLines = 1)
            }
        }
    }
}

// MARK: Now playing

@Composable
private fun IPodNowPlaying(seeking: Boolean, volume: Float) {
    val t = Playback.current ?: return
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val art = minOf(maxWidth * 0.6f, maxHeight - 150.dp).coerceAtLeast(80.dp)
        Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically)) {
            Box(Modifier.shadow(18.dp, RoundedCornerShape(12.dp))) { Artwork(t.artwork(600), t.id, art, RoundedCornerShape(12.dp)) }
            Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(horizontal = 24.dp)) {
                Text(t.title, color = DriftColors.text, fontSize = 19.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(listOfNotNull(t.artist, t.album).filter { it.isNotBlank() }.joinToString(" · "), color = DriftColors.muted, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Column(Modifier.fillMaxWidth().padding(horizontal = 28.dp)) {
                Bar(if (Playback.duration > 0) Playback.position.toFloat() / Playback.duration else 0f, seeking)
                Row(Modifier.fillMaxWidth().padding(top = 6.dp)) {
                    Text(time(Playback.position), color = DriftColors.muted, fontSize = 12.sp, modifier = Modifier.weight(1f))
                    Text("-" + time(Playback.duration - Playback.position), color = DriftColors.muted, fontSize = 12.sp)
                }
            }
            Row(Modifier.fillMaxWidth().padding(horizontal = 28.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Volume", color = DriftColors.muted, fontSize = 11.sp, modifier = Modifier.width(52.dp))
                Box(Modifier.weight(1f)) { Bar(volume, !seeking) }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Wheel:", color = DriftColors.muted, fontSize = 12.sp)
                Text(if (seeking) "Seeking" else "Volume", color = DriftColors.accent, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                Text("· press the centre to switch", color = DriftColors.muted, fontSize = 12.sp)
            }
        }
    }
}

@Composable
private fun Bar(fraction: Float, on: Boolean) {
    Box(Modifier.fillMaxWidth().height(6.dp).clip(RoundedCornerShape(3.dp)).background(DriftColors.surface2)) {
        Box(Modifier.fillMaxWidth(fraction.coerceIn(0f, 1f)).height(6.dp).background(if (on) DriftColors.accent else DriftColors.text2))
    }
}

// MARK: The click wheel

@Composable
private fun ClickWheel(
    onTurn: (Int) -> Unit,
    onMenu: () -> Unit,
    onSelect: () -> Unit,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    onPlayPause: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val view = LocalView.current
    // The latest callbacks (the gesture below is set up once).
    val turnNow by androidx.compose.runtime.rememberUpdatedState(onTurn)
    // Degrees per step: about 24 steps a turn, like the iPod.
    val step = 15f
    var finger by remember { mutableStateOf<Float?>(null) }
    BoxWithConstraints(modifier.widthIn(max = 300.dp).fillMaxWidth(0.78f).aspectRatio(1f), contentAlignment = Alignment.Center) {
        val r = maxWidth / 2
        Box(
            Modifier.fillMaxSize().shadow(20.dp, CircleShape).clip(CircleShape).background(DriftColors.surface).border(1.dp, DriftColors.line, CircleShape)
                .semantics { contentDescription = "Click wheel: turn to scroll" }
                .pointerInput(Unit) {
                    awaitEachGesture {
                        awaitFirstDown()
                        var last: Float? = null
                        var turned = 0f
                        val c = Offset(size.width / 2f, size.height / 2f)
                        val inner = size.width * 0.2f
                        while (true) {
                            val event = awaitPointerEvent()
                            val change = event.changes.firstOrNull() ?: break
                            if (!change.pressed) break
                            val p = change.position - c
                            if (p.getDistance() < inner) continue
                            val angle = (atan2(p.y, p.x) * 180f / PI.toFloat())
                            finger = angle
                            val l = last
                            last = angle
                            if (l == null) continue
                            var delta = angle - l
                            if (delta > 180f) delta -= 360f
                            if (delta < -180f) delta += 360f
                            turned += delta
                            var steps = 0
                            while (turned >= step) { steps++; turned -= step }
                            while (turned <= -step) { steps--; turned += step }
                            if (steps != 0) turnNow(steps)
                            change.consume()
                        }
                        finger = null
                    }
                },
        )
        finger?.let { a ->
            val rad = a * PI.toFloat() / 180f
            val dist = r - 22.dp
            Box(
                Modifier.offset(dist * kotlin.math.cos(rad), dist * kotlin.math.sin(rad)).size(12.dp).clip(CircleShape).background(DriftColors.accent),
            )
        }
        RingButton("MENU", null, "Menu", Modifier.offset(y = -(r - 30.dp))) { IPod.pressed(view); onMenu() }
        RingButton(null, Icons.Filled.FastRewind, "Previous", Modifier.offset(x = -(r - 30.dp))) { IPod.pressed(view); onPrevious() }
        RingButton(null, Icons.Filled.FastForward, "Next", Modifier.offset(x = r - 30.dp)) { IPod.pressed(view); onNext() }
        RingButton(null, if (Playback.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow, "Play or pause", Modifier.offset(y = r - 30.dp)) { IPod.pressed(view); onPlayPause() }
        Box(
            Modifier.size(maxWidth * 0.4f).shadow(8.dp, CircleShape).clip(CircleShape).background(DriftColors.surface2).border(1.dp, DriftColors.line, CircleShape)
                .semantics { contentDescription = "Select" }
                .clickable {
                    IPod.pressed(view)
                    onSelect()
                },
        )
    }
}

@Composable
private fun RingButton(text: String?, icon: androidx.compose.ui.graphics.vector.ImageVector?, label: String, modifier: Modifier, onClick: () -> Unit) {
    Box(
        modifier.size(width = 60.dp, height = 44.dp).clip(RoundedCornerShape(10.dp)).semantics { contentDescription = label }.clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        if (text != null) Text(text, color = DriftColors.text2, fontSize = 13.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.5.sp)
        else if (icon != null) Icon(icon, null, tint = DriftColors.text2, modifier = Modifier.size(22.dp))
    }
}

// MARK: Turning, shared by the styles

/** Turns finger angles into steps (one per [step] degrees; + clockwise). */
private class IPodTurns(val step: Float) {
    private var last: Float? = null
    private var turned = 0f

    fun feed(angle: Float): Int {
        val l = last
        last = angle
        if (l == null) return 0
        var d = angle - l
        if (d > 180f) d -= 360f
        if (d < -180f) d += 360f
        turned += d
        var n = 0
        while (turned >= step) { n++; turned -= step }
        while (turned <= -step) { n--; turned += step }
        return n
    }

    fun reset() {
        last = null
        turned = 0f
    }
}

private fun angleOf(p: Offset, c: Offset): Float = atan2(p.y - c.y, p.x - c.x) * 180f / PI.toFloat()

// MARK: Summoned wheel (and the crate's flicking)

/**
 * Swipe to flip (a step every so often, sideways or up and down), tap to select, and with [summon], touch and
 * hold anywhere for a wheel under your thumb: circle to scroll, let go and it's gone.
 */
@Composable
private fun IPodGestures(horizontal: Boolean, summon: Boolean, onTurn: (Int) -> Unit, onTap: () -> Unit) {
    val view = LocalView.current
    val turn by rememberUpdatedState(onTurn)
    val tap by rememberUpdatedState(onTap)
    val across by rememberUpdatedState(horizontal)
    var wheel by remember { mutableStateOf<Offset?>(null) }
    var finger by remember { mutableStateOf<Float?>(null) }
    val density = LocalDensity.current
    val radius = 105.dp
    Box(
        Modifier.fillMaxSize()
            .semantics { contentDescription = "Swipe to scroll, tap to open" }
            .pointerInput(summon) {
                val stepH = 54.dp.toPx()
                val stepV = 38.dp.toPx()
                val slop = 10.dp.toPx()
                awaitEachGesture {
                    val down = awaitFirstDown()
                    val start = down.position
                    val began = System.currentTimeMillis()
                    var moved = false
                    var stepped = 0f
                    val turns = IPodTurns(22f)
                    while (true) {
                        val waiting = summon && wheel == null && !moved
                        val event = if (waiting) {
                            val left = 280L - (System.currentTimeMillis() - began)
                            if (left <= 0) null else withTimeoutOrNull(left) { awaitPointerEvent() }
                        } else awaitPointerEvent()
                        if (event == null) {
                            // Held still: the wheel, right under the thumb.
                            wheel = start
                            IPod.pressed(view)
                            continue
                        }
                        val change = event.changes.firstOrNull() ?: break
                        if (!change.pressed) {
                            if (wheel != null) {
                                wheel = null
                                finger = null
                            } else if (!moved && System.currentTimeMillis() - began < 300) {
                                IPod.pressed(view)
                                tap()
                            }
                            break
                        }
                        val w = wheel
                        if (w != null) {
                            val p = change.position
                            if ((p - w).getDistance() > 20.dp.toPx()) {
                                val a = angleOf(p, w)
                                finger = a
                                val n = turns.feed(a)
                                if (n != 0) turn(n)
                            }
                            change.consume()
                            continue
                        }
                        val t = change.position - start
                        if (!moved && (abs(t.x) > slop || abs(t.y) > slop)) moved = true
                        if (!moved) continue
                        change.consume()
                        // Up or left moves on.
                        val along = if (across) -t.x else -t.y
                        val size = if (across) stepH else stepV
                        while (along - stepped >= size) { turn(1); stepped += size }
                        while (along - stepped <= -size) { turn(-1); stepped -= size }
                    }
                }
            },
    ) {
        wheel?.let { w ->
            val r = with(density) { radius.toPx() }
            Box(
                Modifier.offset { IntOffset((w.x - r).roundToInt(), (w.y - r).roundToInt()) }.size(radius * 2)
                    .shadow(20.dp, CircleShape).clip(CircleShape).background(DriftColors.surface.copy(alpha = 0.92f))
                    .border(2.dp, DriftColors.accent, CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                finger?.let { a ->
                    val rad = a * PI.toFloat() / 180f
                    val dist = radius - 18.dp
                    Box(Modifier.offset(dist * kotlin.math.cos(rad), dist * kotlin.math.sin(rad)).size(14.dp).clip(CircleShape).background(DriftColors.accent))
                }
            }
        }
    }
}

/** The summoned wheel's mini player: what's playing (tap for Now playing), previous, play/pause, next. */
@Composable
private fun IPodMiniBar(open: () -> Unit) {
    val view = LocalView.current
    val t = Playback.current
    if (t == null) {
        Text("Touch and hold anywhere for the wheel", color = DriftColors.muted, fontSize = 13.sp, modifier = Modifier.fillMaxWidth().padding(vertical = 18.dp), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        return
    }
    Row(
        Modifier.padding(horizontal = 12.dp).padding(bottom = 10.dp).fillMaxWidth().height(64.dp).clip(RoundedCornerShape(16.dp)).background(DriftColors.surface).padding(start = 10.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(Modifier.weight(1f).clickable { open() }.semantics { contentDescription = "Now playing: ${t.title}" }, verticalAlignment = Alignment.CenterVertically) {
            Artwork(t.artwork(120), t.id, 44.dp, RoundedCornerShape(8.dp))
            Column(Modifier.padding(start = 10.dp)) {
                Text(t.title, color = DriftColors.text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(t.artist, color = DriftColors.muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        BarIcon(Icons.Filled.SkipPrevious, "Previous") { IPod.pressed(view); Playback.previous() }
        BarIcon(if (Playback.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (Playback.isPlaying) "Pause" else "Play") { IPod.pressed(view); Playback.toggle() }
        BarIcon(Icons.Filled.SkipNext, "Next") { IPod.pressed(view); Playback.next() }
    }
}

@Composable
private fun BarIcon(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    Box(Modifier.size(44.dp).clip(CircleShape).clickable(onClick = onClick).semantics { contentDescription = label }, contentAlignment = Alignment.Center) {
        Icon(icon, null, tint = DriftColors.text, modifier = Modifier.size(24.dp))
    }
}

// MARK: Record crate

/** Sleeves standing in a crate, the chosen one in front; the ones behind lean back. */
@Composable
private fun IPodCrate(items: List<Cover>, selected: Int) {
    val density = LocalDensity.current
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val front = minOf(maxWidth * 0.62f, maxHeight - 80.dp).coerceAtLeast(60.dp)
        for (k in 3 downTo 0) {
            val c = items.getOrNull(selected + k) ?: continue
            val size = front - (k * 18).dp
            Box(
                Modifier.align(Alignment.BottomCenter).offset(y = -(70 + k * 26).dp).zIndex(10f - k).size(size)
                    .graphicsLayer {
                        rotationX = if (k == 0) 4f else 16f
                        cameraDistance = 12f * density.density
                    }
                    .shadow(10.dp, RoundedCornerShape(6.dp)),
            ) {
                if (c.playlist != null) PlaylistCover(c.playlist, size) else Artwork(c.tracks.firstOrNull()?.artwork(600), c.id, size, RoundedCornerShape(6.dp))
                if (k > 0) Box(Modifier.matchParentSize().background(Color.Black.copy(alpha = 0.14f * k)))
            }
        }
        // The crate's front, with what's in front.
        Column(
            Modifier.align(Alignment.BottomCenter).zIndex(20f).padding(horizontal = 30.dp).padding(bottom = 12.dp).fillMaxWidth().height(96.dp)
                .shadow(14.dp, RoundedCornerShape(10.dp)).clip(RoundedCornerShape(10.dp)).background(Color(0xFF3A2C20)),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Box(Modifier.fillMaxWidth().height(3.dp).background(Color(0xFF5A4430)))
            Spacer(Modifier.weight(1f))
            items.getOrNull(selected)?.let { c ->
                Text(c.title, color = Color(0xFFF2E6D8), fontSize = 15.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(horizontal = 12.dp))
                Text(c.subtitle, color = Color(0xFFD9C7B3), fontSize = 12.sp, maxLines = 1)
            }
            Spacer(Modifier.weight(1f))
        }
    }
}

/** The crate's turntable: the song playing spins on it; drag the record round to seek. */
@Composable
private fun IPodTurntable() {
    val view = LocalView.current
    val t = Playback.current
    var spin by remember { mutableStateOf(0f) }
    var drag by remember { mutableStateOf<Float?>(null) }
    var scratch by remember { mutableStateOf(0f) }
    LaunchedEffect(Playback.isPlaying, drag == null) {
        if (!Playback.isPlaying || drag != null) return@LaunchedEffect
        var last = withFrameMillis { it }
        while (true) {
            val now = withFrameMillis { it }
            spin = (spin + (now - last) * 0.2f) % 360f
            last = now
        }
    }
    Row(
        Modifier.padding(horizontal = 14.dp).padding(top = 6.dp).fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(DriftColors.surface).padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Box(
            Modifier.size(150.dp).shadow(10.dp, CircleShape).clip(CircleShape)
                .semantics { contentDescription = "Record: drag round to seek" }
                .pointerInput(Unit) {
                    val c = Offset(size.width / 2f, size.height / 2f)
                    awaitEachGesture {
                        val down = awaitFirstDown()
                        val a0 = angleOf(down.position, c)
                        var lastTick = 0
                        while (true) {
                            val ev = awaitPointerEvent()
                            val ch = ev.changes.firstOrNull() ?: break
                            if (!ch.pressed) break
                            var d = angleOf(ch.position, c) - a0
                            if (d > 180f) d -= 360f
                            if (d < -180f) d += 360f
                            drag = d
                            // A full turn of the record: 8 seconds of the song.
                            scratch = d / 360f * 8f
                            val tick = (scratch / 2f).toInt()
                            if (tick != lastTick) { IPod.tick(view); lastTick = tick }
                            ch.consume()
                        }
                        if (Playback.current != null && drag != null) {
                            Playback.seek((Playback.position + (scratch * 1000).toLong()).coerceIn(0L, Playback.duration.coerceAtLeast(0L)))
                        }
                        spin = (spin + (drag ?: 0f)) % 360f
                        drag = null
                        scratch = 0f
                    }
                },
            contentAlignment = Alignment.Center,
        ) {
            Box(Modifier.fillMaxSize().graphicsLayer { rotationZ = spin + (drag ?: 0f) }, contentAlignment = Alignment.Center) {
                Canvas(Modifier.fillMaxSize()) {
                    drawCircle(Color(0xFF121212))
                    for (i in 0 until 9) drawCircle(Color(0xFF222222), radius = size.minDimension / 2 - (8 + i * 6).dp.toPx(), style = Stroke(1.dp.toPx()))
                }
                if (t != null) Artwork(t.artwork(200), t.id, 56.dp, CircleShape)
                else Box(Modifier.size(56.dp).clip(CircleShape).background(DriftColors.surface2))
                Box(Modifier.size(6.dp).clip(CircleShape).background(DriftColors.bg))
            }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            if (t != null) {
                Text(t.title, color = DriftColors.text, fontSize = 16.sp, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(t.artist, color = DriftColors.muted, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(time(Playback.position + (scratch * 1000).toLong()) + " / " + time(Playback.duration), color = DriftColors.muted, fontSize = 12.sp)
            } else {
                Text("Nothing playing", color = DriftColors.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                Text("Tap a sleeve to put it on", color = DriftColors.muted, fontSize = 13.sp)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                PillIcon(Icons.Filled.SkipPrevious, "Previous") { IPod.pressed(view); Playback.previous() }
                PillIcon(if (Playback.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (Playback.isPlaying) "Pause" else "Play") { IPod.pressed(view); Playback.toggle() }
                PillIcon(Icons.Filled.SkipNext, "Next") { IPod.pressed(view); Playback.next() }
            }
        }
    }
}

@Composable
private fun PillIcon(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    Box(
        Modifier.size(width = 44.dp, height = 40.dp).clip(RoundedCornerShape(50)).background(DriftColors.surface2).clickable(onClick = onClick).semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) { Icon(icon, null, tint = DriftColors.text, modifier = Modifier.size(20.dp)) }
}

// MARK: Thumb arc

/** A dial rising from the bottom edge: its ticks turn under your thumb; Select in the notch, previous and next at its ends; swipe down on it to go back. */
@Composable
private fun IPodArcDial(
    onTurn: (Int) -> Unit,
    onBack: () -> Unit,
    onSelect: () -> Unit,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val view = LocalView.current
    val turn by rememberUpdatedState(onTurn)
    val back by rememberUpdatedState(onBack)
    var rotation by remember { mutableStateOf(0f) }
    val visible: Dp = 196.dp
    BoxWithConstraints(modifier.fillMaxWidth().height(visible)) {
        val w = maxWidth
        val radiusDp = w * 0.725f
        Canvas(
            Modifier.fillMaxSize().clipToBounds()
                .semantics { contentDescription = "Dial: turn to scroll, swipe down to go back" }
                .pointerInput(Unit) {
                    val r = radiusDp.toPx()
                    val c = Offset(size.width / 2f, r)
                    awaitEachGesture {
                        val down = awaitFirstDown()
                        val turns = IPodTurns(12f)
                        var last: Float? = null
                        var steps = 0
                        var end = down.position
                        while (true) {
                            val ev = awaitPointerEvent()
                            val ch = ev.changes.firstOrNull() ?: break
                            if (!ch.pressed) break
                            end = ch.position
                            val a = angleOf(ch.position, c)
                            last?.let { l ->
                                var d = a - l
                                if (d > 180f) d -= 360f
                                if (d < -180f) d += 360f
                                // The ticks follow the thumb.
                                rotation += d
                            }
                            last = a
                            val n = turns.feed(a)
                            if (n != 0) { steps += abs(n); turn(n) }
                            ch.consume()
                        }
                        // A swipe down that barely turned it: back.
                        val dy = end.y - down.position.y
                        val dx = end.x - down.position.x
                        if (dy > 60.dp.toPx() && abs(dx) < dy && steps == 0) {
                            IPod.pressed(view)
                            back()
                        }
                    }
                },
        ) {
            val r = radiusDp.toPx()
            val c = Offset(size.width / 2f, r)
            drawCircle(DriftColors.surface, radius = r, center = c)
            drawCircle(DriftColors.line, radius = r, center = c, style = Stroke(1.dp.toPx()))
            rotate(rotation, pivot = c) {
                for (i in 0 until 72) {
                    val major = i % 3 == 0
                    rotate(i * 5f, pivot = c) {
                        drawLine(
                            if (major) DriftColors.muted.copy(alpha = 0.7f) else DriftColors.line,
                            start = Offset(c.x, c.y - r + 6.dp.toPx()),
                            end = Offset(c.x, c.y - r + (if (major) 22 else 15).dp.toPx()),
                            strokeWidth = 2.dp.toPx(),
                        )
                    }
                }
            }
        }
        Box(
            Modifier.align(Alignment.TopCenter).offset(y = 58.dp).size(84.dp).shadow(8.dp, CircleShape).clip(CircleShape).background(DriftColors.surface2)
                .border(1.dp, DriftColors.line, CircleShape).semantics { contentDescription = "Select" }
                .clickable { IPod.pressed(view); onSelect() },
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.Filled.Check, null, tint = DriftColors.accent, modifier = Modifier.size(26.dp)) }
        Row(Modifier.align(Alignment.TopCenter).offset(y = 92.dp).fillMaxWidth().padding(horizontal = 22.dp)) {
            BarIcon(Icons.Filled.SkipPrevious, "Previous") { IPod.pressed(view); onPrevious() }
            Spacer(Modifier.weight(1f))
            BarIcon(Icons.Filled.SkipNext, "Next") { IPod.pressed(view); onNext() }
        }
    }
}


// MARK: The summoned wheel's lists

/** A normal list (scroll it, tap a row to open it); touch and hold anywhere for the wheel, which moves the highlight while the list stays put. */
@Composable
private fun IPodTapList(rows: List<Triple<String, String?, String?>>, selected: Int, onTap: (Int) -> Unit, onTurn: (Int) -> Unit) {
    val view = LocalView.current
    val turn by rememberUpdatedState(onTurn)
    var wheel by remember { mutableStateOf<Offset?>(null) }
    var finger by remember { mutableStateOf<Float?>(null) }
    val state = rememberLazyListState()
    val density = LocalDensity.current
    val radius = 105.dp
    LaunchedEffect(selected) {
        // The wheel moved the highlight: keep it in view.
        if (wheel != null) state.animateScrollToItem((selected - 3).coerceAtLeast(0))
    }
    Box(
        Modifier.fillMaxSize().pointerInput(Unit) {
            val slop = 10.dp.toPx()
            awaitEachGesture {
                val down = awaitFirstDown(requireUnconsumed = false, pass = androidx.compose.ui.input.pointer.PointerEventPass.Initial)
                val start = down.position
                // Held still for a moment: the wheel. Moved or let go first: a normal scroll or tap.
                var still = true
                val result = withTimeoutOrNull(280L) {
                    while (true) {
                        val ev = awaitPointerEvent(androidx.compose.ui.input.pointer.PointerEventPass.Initial)
                        val ch = ev.changes.firstOrNull() ?: break
                        if (!ch.pressed || (ch.position - start).getDistance() > slop) {
                            still = false
                            break
                        }
                    }
                }
                if (result != null || !still) return@awaitEachGesture
                wheel = start
                IPod.pressed(view)
                val turns = IPodTurns(22f)
                while (true) {
                    val ev = awaitPointerEvent(androidx.compose.ui.input.pointer.PointerEventPass.Initial)
                    val ch = ev.changes.firstOrNull() ?: break
                    ch.consume()
                    if (!ch.pressed) break
                    if ((ch.position - start).getDistance() > 20.dp.toPx()) {
                        val a = angleOf(ch.position, start)
                        finger = a
                        val n = turns.feed(a)
                        if (n != 0) turn(n)
                    }
                }
                wheel = null
                finger = null
            }
        },
    ) {
        LazyColumn(state = state, userScrollEnabled = wheel == null, modifier = Modifier.fillMaxSize().padding(horizontal = 12.dp)) {
            itemsIndexed(rows) { i, row ->
                val on = i == selected
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 46.dp).padding(vertical = 1.dp).clip(RoundedCornerShape(10.dp))
                        .background(if (on) DriftColors.accent else Color.Transparent)
                        .clickable {
                            IPod.pressed(view)
                            onTap(i)
                        }
                        .padding(horizontal = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    val color = if (on) DriftColors.onAccent else DriftColors.text
                    Column(Modifier.weight(1f)) {
                        Text(row.first, color = color, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        row.second?.let { Text(it, color = color.copy(alpha = 0.7f), fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                    }
                    when {
                        row.third != null -> Text(row.third!!, color = color.copy(alpha = 0.7f), fontSize = 13.sp)
                        row.second == null -> Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = color.copy(alpha = 0.6f))
                    }
                }
            }
        }
        wheel?.let { w ->
            val r = with(density) { radius.toPx() }
            Box(
                Modifier.offset { IntOffset((w.x - r).roundToInt(), (w.y - r).roundToInt()) }.size(radius * 2)
                    .shadow(20.dp, CircleShape).clip(CircleShape).background(DriftColors.surface.copy(alpha = 0.92f))
                    .border(2.dp, DriftColors.accent, CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                finger?.let { a ->
                    val rad = a * PI.toFloat() / 180f
                    val dist = radius - 18.dp
                    Box(Modifier.offset(dist * kotlin.math.cos(rad), dist * kotlin.math.sin(rad)).size(14.dp).clip(CircleShape).background(DriftColors.accent))
                }
            }
        }
    }
}
