package com.lordxhobo.drift.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowCircleDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lordxhobo.drift.data.Track
import com.lordxhobo.drift.data.formatTime
import com.lordxhobo.drift.playback.Downloads
import com.lordxhobo.drift.playback.Playback
import com.lordxhobo.drift.podcasts.PodcastChannel
import com.lordxhobo.drift.podcasts.PodcastStore
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/** "Today", "Yesterday", "3 days ago", "1 Nov", "1 Nov 2024". */
fun episodeDate(published: Double?): String {
    val p = published ?: return ""
    val ms = ((p + 978_307_200.0) * 1000).toLong()
    val days = ((System.currentTimeMillis() - ms) / 86_400_000L).toInt()
    val then = Calendar.getInstance().apply { timeInMillis = ms }
    val now = Calendar.getInstance()
    return when {
        days <= 0 && then.get(Calendar.DAY_OF_YEAR) == now.get(Calendar.DAY_OF_YEAR) -> "Today"
        days <= 1 -> "Yesterday"
        days < 7 -> "$days days ago"
        then.get(Calendar.YEAR) == now.get(Calendar.YEAR) -> SimpleDateFormat("d MMM", Locale.getDefault()).format(Date(ms))
        else -> SimpleDateFormat("d MMM yyyy", Locale.getDefault()).format(Date(ms))
    }
}

/** "58 min", "1 h 4 min". */
fun lengthText(seconds: Double): String {
    val m = Math.round(seconds / 60).toInt()
    return if (m >= 60) "${m / 60} h ${m % 60} min" else "$m min"
}

/** Plays an episode where it was left off. */
fun playEpisode(t: Track) {
    if (Playback.current?.id == t.id) {
        Playback.toggle()
        return
    }
    Playback.playEpisode(t)
}

/** A show's picture: square for a podcast, round for a YouTube channel. */
@Composable
fun ShowCover(c: PodcastChannel, size: Dp) {
    Artwork(c.avatarURL, c.id, size, if (c.squareCover) RoundedCornerShape(size / 8) else CircleShape)
}

/** One episode: its picture with how far you got, title, show and date, and its menu. */
@Composable
fun EpisodeRow(t: Track, showShow: Boolean = true) {
    var menu by remember { mutableStateOf(false) }
    val fraction = PodcastStore.fraction(t.id)
    val finished = PodcastStore.isFinished(t.id)
    val left = PodcastStore.remaining(t.id)
    val playing = Playback.current?.id == t.id
    Row(
        Modifier.fillMaxWidth().heightIn(min = 70.dp).clickable { playEpisode(t) }.padding(start = 16.dp, end = 4.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(96.dp, 54.dp).clip(RoundedCornerShape(6.dp))) {
            Picture(t.artwork(320), t.id, 96.dp, 54.dp, RoundedCornerShape(0.dp))
            if (fraction != null) {
                Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(3.dp).background(androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.5f)))
                Box(Modifier.align(Alignment.BottomStart).fillMaxWidth(fraction.toFloat()).height(3.dp).background(DriftColors.accent))
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                t.title, color = if (playing) DriftColors.accent else if (finished) DriftColors.muted else DriftColors.text,
                fontSize = 14.sp, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis, lineHeight = 18.sp,
            )
            val parts = listOfNotNull(
                if (showShow) t.artist.ifEmpty { null } else null,
                episodeDate(t.published).ifEmpty { null },
                when {
                    finished -> "Played"
                    left != null -> "${lengthText(left)} left"
                    t.duration != null -> lengthText(t.duration)
                    else -> null
                },
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (Downloads.isDownloaded(t.id)) Icon(Icons.Filled.ArrowCircleDown, contentDescription = "Downloaded", tint = DriftColors.accent, modifier = Modifier.size(14.dp).padding(end = 2.dp))
                if (finished) Icon(Icons.Filled.Check, contentDescription = null, tint = DriftColors.accent, modifier = Modifier.size(14.dp).padding(end = 2.dp))
                Text(parts.joinToString(" · "), color = DriftColors.muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        Box {
            IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, contentDescription = "More for ${t.title}", tint = DriftColors.muted) }
            EpisodeMenu(t, menu) { menu = false }
        }
    }
}

@Composable
fun EpisodeMenu(t: Track, open: Boolean, onClose: () -> Unit) {
    DropdownMenu(expanded = open, onDismissRequest = onClose) {
        DropdownMenuItem(text = { Text("Play next") }, onClick = { onClose(); Playback.playNext(t) })
        DropdownMenuItem(text = { Text("Add to queue") }, onClick = { onClose(); Playback.addToQueue(t) })
        if (Downloads.isDownloaded(t.id) || Downloads.isManual(t.id)) DropdownMenuItem(text = { Text("Remove download") }, onClick = { onClose(); Downloads.remove(t.id) })
        else DropdownMenuItem(text = { Text("Download") }, onClick = { onClose(); Downloads.downloadSong(t) })
        if (PodcastStore.isFinished(t.id)) DropdownMenuItem(text = { Text("Mark as unplayed") }, onClick = { onClose(); PodcastStore.markPlayed(t, false) })
        else DropdownMenuItem(text = { Text("Mark as played") }, onClick = { onClose(); PodcastStore.markPlayed(t, true) })
        PodcastStore.channel(t)?.let { c ->
            if ((Nav.top as? Screen.Show)?.channel?.id != c.id) DropdownMenuItem(text = { Text("Go to show") }, onClick = { onClose(); Nav.open(Screen.Show(c)) })
        }
        DropdownMenuItem(text = { Text("Share") }, onClick = { onClose(); UiState.sharing = t })
    }
}

/** The Podcasts tab: continue listening, the shows you follow, and their newest episodes. */
@Composable
fun PodcastsScreen() {
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { runCatching { PodcastStore.refresh(force = false) } }
    val resume = PodcastStore.continueListening
    val subs = PodcastStore.subscriptions
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        item {
            Row(Modifier.padding(start = 16.dp, end = 8.dp, top = 12.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Podcasts", color = DriftColors.text, fontSize = 26.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.weight(1f))
                if (subs.isNotEmpty()) {
                    if (PodcastStore.refreshing) CircularProgressIndicator(color = DriftColors.accent, strokeWidth = 2.dp, modifier = Modifier.size(20.dp).padding(end = 4.dp))
                    else IconButton(onClick = { scope.launch { runCatching { PodcastStore.refresh(force = true) } } }) {
                        Icon(Icons.Filled.Replay, contentDescription = "Look for new episodes", tint = DriftColors.text2)
                    }
                }
            }
        }
        if (subs.isEmpty() && resume.isEmpty()) {
            item {
                Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Follow your first podcast", color = DriftColors.text, fontSize = 20.sp, fontWeight = FontWeight.ExtraBold)
                    Text(
                        "Go to Search, switch to Podcasts and look up a show or channel (or paste a show's feed link). Tap Follow and new episodes show up here. You can also paste a YouTube link there to play any video.",
                        color = DriftColors.muted, fontSize = 14.sp, lineHeight = 20.sp,
                    )
                    OutlinedButton(onClick = { SearchState.podcasts = true; SearchState.youtube = false; Nav.tab = Tab.SEARCH }) { Text("Search podcasts", color = DriftColors.text, fontWeight = FontWeight.Bold) }
                }
            }
        }
        if (resume.isNotEmpty()) {
            item { SectionTitle("Continue listening") }
            items(resume, key = { "r-" + it.track.id }) { EpisodeRow(it.track) }
        }
        if (subs.isNotEmpty()) {
            item { SectionTitle("Following") }
            item {
                LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    items(subs, key = { it.id }) { c ->
                        Column(Modifier.width(84.dp).clickable { Nav.open(Screen.Show(c)) }, horizontalAlignment = Alignment.CenterHorizontally) {
                            ShowCover(c, 76.dp)
                            Text(c.name, color = DriftColors.text, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 8.dp), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                        }
                    }
                }
            }
            item { SectionTitle("New episodes") }
            val episodes = PodcastStore.newEpisodes
            if (episodes.isEmpty()) {
                item {
                    if (PodcastStore.refreshing) Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = DriftColors.accent) }
                    else EmptyText("No episodes yet. Tap the refresh button above.")
                }
            }
            items(episodes, key = { "n-" + it.id }) { EpisodeRow(it) }
        }
    }
}

/** A show's page: its cover, Follow, and its episodes (newest first). */
@Composable
fun ShowScreen(c: PodcastChannel) {
    var episodes by remember(c.id) { mutableStateOf(PodcastStore.feeds[c.id]) }
    var error by remember(c.id) { mutableStateOf<String?>(null) }
    LaunchedEffect(c.id) {
        runCatching { PodcastStore.loadChannel(c) }
            .onSuccess { if (it.isNotEmpty()) episodes = it else if (episodes == null) episodes = emptyList() }
            .onFailure { if (episodes == null) error = "Couldn't load episodes. Check your connection." }
    }
    val shown = PodcastStore.subscriptions.firstOrNull { it.id == c.id } ?: c
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        item { BackBar() }
        item {
            Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.Bottom) {
                ShowCover(shown, 132.dp)
                Spacer(Modifier.width(16.dp))
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(shown.name, color = DriftColors.text, fontSize = 22.sp, fontWeight = FontWeight.ExtraBold, lineHeight = 26.sp, maxLines = 3, overflow = TextOverflow.Ellipsis)
                    Text(
                        listOfNotNull(shown.subtitle ?: if (shown.isFeed) "Podcast" else "YouTube", episodes?.size?.takeIf { it > 0 }?.let { "$it episodes" }).joinToString(" · "),
                        color = DriftColors.muted, fontSize = 13.sp, maxLines = 2, overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
        item {
            Row(Modifier.padding(horizontal = 16.dp, vertical = 14.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                val following = PodcastStore.isFollowing(c.id)
                if (following) {
                    Button(onClick = { PodcastStore.unfollow(c.id) }, colors = ButtonDefaults.buttonColors(containerColor = DriftColors.accent, contentColor = DriftColors.onAccent)) {
                        Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("Following", fontWeight = FontWeight.Bold)
                    }
                } else {
                    OutlinedButton(onClick = { PodcastStore.follow(shown) }) { Text("Follow", color = DriftColors.text, fontWeight = FontWeight.Bold) }
                }
                episodes?.firstOrNull()?.let { latest ->
                    OutlinedButton(onClick = { playEpisode(latest) }) {
                        Icon(if (Playback.current?.id == latest.id && Playback.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow, contentDescription = null, tint = DriftColors.text, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("Latest", color = DriftColors.text, fontWeight = FontWeight.Bold)
                    }
                }
            }
        }
        item { SectionTitle("Episodes") }
        val list = episodes
        when {
            error != null -> item { EmptyText(error ?: "") }
            list == null -> item { Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = DriftColors.accent) } }
            list.isEmpty() -> item { EmptyText("No episodes found.") }
            else -> items(list, key = { it.id }) { EpisodeRow(it, showShow = false) }
        }
    }
}

/** A show in search results: cover, name, what it is, and Follow. */
@Composable
fun ShowRow(c: PodcastChannel) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 68.dp).clickable { Nav.open(Screen.Show(c)) }.padding(start = 16.dp, end = 12.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ShowCover(c, 56.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(c.name, color = DriftColors.text, fontSize = 15.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(c.subtitle ?: if (c.isFeed) "Podcast" else "YouTube channel", color = DriftColors.muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        val following = PodcastStore.isFollowing(c.id)
        Text(
            if (following) "Following" else "Follow",
            color = if (following) DriftColors.onAccent else DriftColors.text, fontSize = 13.sp, fontWeight = FontWeight.Bold,
            modifier = Modifier.clip(RoundedCornerShape(17.dp)).background(if (following) DriftColors.accent else DriftColors.surface2)
                .clickable { PodcastStore.toggleFollow(c) }.padding(horizontal = 14.dp, vertical = 8.dp),
        )
    }
}
