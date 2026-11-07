package com.lordxhobo.drift.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lordxhobo.drift.data.Track
import com.lordxhobo.drift.lyrics.LyricsResult
import com.lordxhobo.drift.lyrics.LyricsService
import com.lordxhobo.drift.playback.Playback
import com.lordxhobo.drift.youtube.HttpDownloader
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Request

/** One lyrics lookup for the whole app (it remembers songs it already found). */
object LyricsSource {
    val service = LyricsService { url ->
        val request = Request.Builder().url(url).header("User-Agent", "Drift Android (personal music player)").build()
        HttpDownloader.shared.client.newCall(request).execute().use { r -> r.code to (r.body?.string() ?: "") }
    }
}

/** Lyrics over the player: synced lines follow the song (tap one to jump there); plain lyrics scroll. */
@Composable
fun LyricsView(t: Track) {
    var result by remember(t.id) { mutableStateOf<LyricsResult?>(null) }
    LaunchedEffect(t.id) {
        result = withContext(Dispatchers.IO) { runCatching { LyricsSource.service.lyrics(t) }.getOrDefault(LyricsResult.None) }
    }
    val tint = DriftColors.tile(t.id)
    Box(
        Modifier.fillMaxSize()
            .background(Brush.verticalGradient(listOf(tint.copy(alpha = 0.9f), DriftColors.bg)))
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {},
    ) {
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
            Row(Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = { UiState.showLyrics = false }) {
                    Icon(Icons.Filled.KeyboardArrowDown, contentDescription = "Close lyrics", tint = DriftColors.text)
                }
                Column(Modifier.weight(1f)) {
                    Text(t.title, color = DriftColors.text, fontSize = 15.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(t.artist, color = DriftColors.text2, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            when (val r = result) {
                null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = DriftColors.text) }
                LyricsResult.None -> Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
                    Text("No lyrics found for this song.", color = DriftColors.text2, fontSize = 16.sp)
                }
                is LyricsResult.Plain -> Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp)) {
                    Text(r.text, color = DriftColors.text, fontSize = 20.sp, fontWeight = FontWeight.Bold, lineHeight = 30.sp)
                    Source(r.source)
                }
                is LyricsResult.Synced -> SyncedLines(r)
            }
        }
    }
}

@Composable
private fun SyncedLines(r: LyricsResult.Synced) {
    val now = Playback.position / 1000.0
    // The line playing now: the last one that has started.
    val active = r.lines.indexOfLast { it.time <= now + 0.15 }
    val list = rememberLazyListState()
    LaunchedEffect(active) {
        // Keep the line playing about a third down the screen.
        if (active >= 0) list.animateScrollToItem(maxOf(0, active - 2))
    }
    LazyColumn(state = list, contentPadding = PaddingValues(horizontal = 24.dp, vertical = 16.dp), modifier = Modifier.fillMaxSize()) {
        itemsIndexed(r.lines) { i, line ->
            val color by animateColorAsState(
                when {
                    i == active -> DriftColors.text
                    i < active -> DriftColors.text.copy(alpha = 0.55f)
                    else -> DriftColors.text.copy(alpha = 0.35f)
                },
                label = "line",
            )
            Text(
                line.text.ifEmpty { "♪" },
                color = color, fontSize = 24.sp, fontWeight = FontWeight.ExtraBold, lineHeight = 32.sp,
                modifier = Modifier.fillMaxWidth().clickable { Playback.seek((line.time * 1000).toLong()) }.padding(vertical = 8.dp),
            )
        }
        item { Source(r.source) }
    }
}

@Composable
private fun Source(name: String) {
    Text("Lyrics from $name", color = DriftColors.text2, fontSize = 12.sp, modifier = Modifier.padding(top = 24.dp, bottom = 40.dp))
}
