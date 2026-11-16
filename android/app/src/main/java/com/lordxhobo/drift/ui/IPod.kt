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
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
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
                        val available = id == "wheel"
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

    Column(Modifier.fillMaxSize().background(DriftColors.bg).statusBarsPadding().navigationBarsPadding()) {
        // Where you are.
        Column(Modifier.fillMaxWidth().padding(horizontal = 22.dp, vertical = 8.dp)) {
            Row(Modifier.fillMaxWidth()) {
                Text(if (stack.size < 2) "iPod" else stack.dropLast(1).joinToString(" › ") { titleOf(it) }, color = DriftColors.muted, fontSize = 13.sp, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                val n = count(screen)
                if (n > 0) Text("${pick + 1} of $n", color = DriftColors.muted, fontSize = 13.sp)
            }
            Text(titleOf(screen), color = DriftColors.text, fontSize = 30.sp, fontWeight = FontWeight.ExtraBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
            when (val s = screen) {
                IPodScreen.Menu -> IPodList(menuItems.map { Triple(it.title, null, null) }, pick)
                is IPodScreen.Covers -> {
                    val items = covers(s.shelf)
                    if (items.isEmpty()) Text(if (s.shelf == "Albums") "Albums you save show up here." else "Nothing here yet.", color = DriftColors.muted)
                    else CoverFlow(items, pick.coerceAtMost(items.size - 1))
                }
                is IPodScreen.Songs ->
                    if (s.tracks.isEmpty()) Text("No songs.", color = DriftColors.muted)
                    else IPodList(s.tracks.map { Triple(it.title, it.artist, it.durationText.ifEmpty { null }) }, pick.coerceAtMost(s.tracks.size - 1))
                IPodScreen.NowPlaying -> IPodNowPlaying(seeking, volume)
            }
        }
        // What's playing (opens Now playing).
        val t = Playback.current
        if (t != null && screen != IPodScreen.NowPlaying) {
            Row(
                Modifier.align(Alignment.CenterHorizontally).padding(vertical = 8.dp).clip(RoundedCornerShape(50)).background(DriftColors.surface)
                    .clickable {
                        IPod.pressed(view)
                        push(IPodScreen.NowPlaying)
                    }.padding(horizontal = 14.dp, vertical = 7.dp).widthIn(max = 320.dp),
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
