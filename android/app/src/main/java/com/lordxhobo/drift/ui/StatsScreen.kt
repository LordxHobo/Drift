package com.lordxhobo.drift.ui

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lordxhobo.drift.data.Track
import com.lordxhobo.drift.playback.Playback
import com.lordxhobo.drift.social.PlayHistory
import com.lordxhobo.drift.social.PlayRecord
import com.lordxhobo.drift.social.Social
import com.lordxhobo.drift.social.Stats
import com.lordxhobo.drift.social.StatsSpan
import com.lordxhobo.drift.social.StatsSummary
import java.text.DateFormat
import java.text.NumberFormat
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.floor
import kotlin.math.log10
import kotlin.math.pow

private fun PlayRecord.toTrack() = Track(id = id, title = title, artist = artist, artworkURL = art)
private fun plural(n: Int, word: String) = "${NumberFormat.getInstance().format(n)} $word${if (n == 1) "" else "s"}"

/** Listening stats: how much you listened, to what, and when (every device you use Drift on). */
@Composable
fun StatsScreen() {
    val prefs = LocalContext.current.getSharedPreferences("drift.settings", Context.MODE_PRIVATE)
    var span by remember { mutableStateOf(runCatching { StatsSpan.valueOf(prefs.getString("statsSpan", null) ?: "") }.getOrDefault(StatsSpan.MONTH)) }
    var data by remember { mutableStateOf<Pair<List<PlayRecord>, Int>?>(null) }
    LaunchedEffect(Unit) { data = PlayHistory.everything() }
    val s = remember(data, span) { data?.let { Stats.summarize(it.first, span) } }
    val fmt = NumberFormat.getInstance()

    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        item { BackBar("Listening stats") }
        item {
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (x in StatsSpan.entries) {
                    val on = x == span
                    Text(
                        x.label, color = if (on) DriftColors.onAccent else DriftColors.text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.clip(RoundedCornerShape(16.dp)).background(if (on) DriftColors.accent else DriftColors.surface2)
                            .clickable {
                                span = x
                                prefs.edit().putString("statsSpan", x.name).apply()
                            }
                            .padding(horizontal = 14.dp, vertical = 7.dp),
                    )
                }
            }
        }
        if (s == null) {
            item { Box(Modifier.fillMaxWidth().padding(40.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = DriftColors.accent) } }
        } else if (s.plays.isEmpty()) {
            item {
                EmptyText(
                    if (data?.first?.isNotEmpty() == true) "Nothing in this period. Pick a longer one to see more."
                    else "Nothing yet. Play some music: songs show up here once you've listened for 30 seconds.",
                )
            }
        } else {
            item {
                Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Total(fmt.format(s.minutes), "minutes", Modifier.weight(1f))
                    Total(fmt.format(s.plays.size), if (s.plays.size == 1) "play" else "plays", Modifier.weight(1f))
                    Total(fmt.format(s.artistCount), if (s.artistCount == 1) "artist" else "artists", Modifier.weight(1f))
                }
            }
            item { MinutesChart(s) }
            item { SectionTitle("Top artists") }
            itemsIndexed(s.topArtists) { i, a ->
                Row(Modifier.fillMaxWidth().heightIn(min = 60.dp).padding(horizontal = 16.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("${i + 1}", color = DriftColors.muted, fontSize = 15.sp, fontWeight = FontWeight.Bold, modifier = Modifier.width(28.dp))
                    Artwork(a.art, a.name, 46.dp, CircleShape)
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(a.name, color = DriftColors.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text("${fmt.format(a.minutes)} min · ${plural(a.plays, "play")}", color = DriftColors.muted, fontSize = 12.sp)
                    }
                }
            }
            item { SectionTitle("Top songs") }
            itemsIndexed(s.topSongs) { i, x ->
                val tracks = s.topSongs.map { it.play.toTrack() }
                val t = tracks[i]
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 60.dp).clickable { Playback.play(tracks, i, "Your top songs") }.padding(horizontal = 16.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("${i + 1}", color = DriftColors.muted, fontSize = 15.sp, fontWeight = FontWeight.Bold, modifier = Modifier.width(28.dp))
                    Artwork(t.artwork(120), t.id, 46.dp)
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(t.title, color = DriftColors.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(t.artist, color = DriftColors.muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    Text(plural(x.plays, "play"), color = DriftColors.text2, fontSize = 12.sp, modifier = Modifier.padding(start = 8.dp))
                }
            }
        }
        item {
            val notes = mutableListOf("Songs count once you've listened for 30 seconds.")
            data?.first?.minOfOrNull { it.at }?.let { notes += "Counting since ${DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(it * 1000))}." }
            val devices = data?.second ?: 1
            if (devices > 1) notes += "Adds up $devices devices."
            else if (Social.me == null) notes += "Make a Drift profile in Settings to add up what you play on your other devices too."
            Text(notes.joinToString(" "), color = DriftColors.muted, fontSize = 12.sp, modifier = Modifier.padding(16.dp))
        }
    }
}

@Composable
private fun Total(value: String, label: String, modifier: Modifier) {
    Column(modifier.clip(RoundedCornerShape(12.dp)).background(DriftColors.surface).padding(vertical = 14.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, color = DriftColors.text, fontSize = 22.sp, fontWeight = FontWeight.ExtraBold, maxLines = 1)
        Text(label, color = DriftColors.muted, fontSize = 12.sp)
    }
}

/** Minutes per day, week or month, as bars. */
@Composable
private fun MinutesChart(s: StatsSummary) {
    val max = maxOf(1.0, s.buckets.maxOfOrNull { it.second } ?: 0.0)
    val nice = niceMax(max)
    val dayFmt = SimpleDateFormat(if (s.unit == Calendar.MONTH) "MMM" else "d MMM", Locale.getDefault())
    val every = maxOf(1, (s.buckets.size + 5) / 6)
    val label = when (s.unit) {
        Calendar.DAY_OF_MONTH -> "per day"
        Calendar.WEEK_OF_YEAR -> "per week"
        else -> "per month"
    }
    val fmt = NumberFormat.getInstance().apply { maximumFractionDigits = 1 }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).clip(RoundedCornerShape(12.dp)).background(DriftColors.surface).padding(14.dp)) {
        Text("Minutes $label", color = DriftColors.text2, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(10.dp))
        Row(Modifier.fillMaxWidth().height(150.dp)) {
            Column(Modifier.fillMaxHeight().padding(end = 6.dp, bottom = 18.dp), verticalArrangement = Arrangement.SpaceBetween, horizontalAlignment = Alignment.End) {
                Text(fmt.format(nice), color = DriftColors.muted, fontSize = 10.sp)
                Text(fmt.format(nice / 2), color = DriftColors.muted, fontSize = 10.sp)
                Text("0", color = DriftColors.muted, fontSize = 10.sp)
            }
            Column(Modifier.weight(1f).fillMaxHeight()) {
                Row(Modifier.weight(1f).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.Bottom) {
                    for ((_, minutes) in s.buckets) {
                        val f = (minutes / nice).toFloat().coerceIn(0f, 1f)
                        Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.BottomCenter) {
                            if (f > 0f) Box(Modifier.fillMaxWidth().fillMaxHeight(f).clip(RoundedCornerShape(topStart = 3.dp, topEnd = 3.dp)).background(DriftColors.accent))
                        }
                    }
                }
                // A date under every few bars (each label as wide as its bars).
                Row(Modifier.height(18.dp).fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
                    for (group in s.buckets.chunked(every)) {
                        Box(Modifier.weight(group.size.toFloat())) {
                            Text(dayFmt.format(Date(group.first().first)), color = DriftColors.muted, fontSize = 9.sp, maxLines = 1, overflow = TextOverflow.Clip)
                        }
                    }
                }
            }
        }
    }
}

private fun niceMax(n: Double): Double {
    val step = 10.0.pow(floor(log10(n)))
    for (m in listOf(1.0, 2.0, 2.5, 5.0, 10.0)) if (m * step >= n) return m * step
    return 10 * step
}
