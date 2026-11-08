package com.lordxhobo.drift.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lordxhobo.drift.data.Library
import com.lordxhobo.drift.data.Track
import com.lordxhobo.drift.playback.Notice
import com.lordxhobo.drift.playback.Playback
import com.lordxhobo.drift.social.Stats
import com.lordxhobo.drift.youtube.YouTube
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/**
 * "Replace with another version": pick a different YouTube Music song or YouTube video for a song in a
 * playlist (or Liked songs). It keeps its place; the pick is played exactly as chosen, on every device.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReplaceSheet(old: Track, list: String, index: Int) {
    var query by remember(old) { mutableStateOf("${Stats.mainArtist(old.artist)} ${old.title}".trim()) }
    var youtube by remember(old) { mutableStateOf(old.upload == true) }
    var results by remember { mutableStateOf<List<Track>?>(null) }
    var failed by remember { mutableStateOf(false) }
    val close = { UiState.replacing = null }

    LaunchedEffect(query, youtube) {
        val q = query.trim()
        if (q.length < 2) return@LaunchedEffect
        results = null
        failed = false
        delay(400)
        runCatching {
            withContext(Dispatchers.IO) { if (youtube) YouTube.searchVideosBlocking(q) else YouTube.searchSongsBlocking(q) }
        }.onSuccess { results = it }.onFailure { failed = true }
    }

    fun use(v: Track) {
        // A YouTube Music song comes as it is. A YouTube video keeps the song's own name (upload titles are messy).
        val t = if (!youtube) v.copy(chosen = true)
        else old.copy(id = v.id, duration = v.duration, artworkURL = v.artworkURL, upload = true, album = null, explicit = null, chosen = true)
        Library.replace(list, index, old.id, t)
        Notice.text = "Replaced “${old.title}”"
        close()
    }

    ModalBottomSheet(onDismissRequest = close, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = DriftColors.surface) {
        Column(Modifier.fillMaxWidth().fillMaxHeight(0.92f)) {
            Text(
                "Replace with another version", color = DriftColors.text, fontSize = 20.sp, fontWeight = FontWeight.ExtraBold,
                modifier = Modifier.padding(horizontal = 20.dp),
            )
            Row(Modifier.padding(horizontal = 20.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                Artwork(old.artwork(120), old.id, 44.dp)
                Spacer(Modifier.width(12.dp))
                Column {
                    Text(old.title, color = DriftColors.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(
                        listOf(old.artist, old.durationText).filter { it.isNotEmpty() }.joinToString(" · "),
                        color = DriftColors.muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            OutlinedTextField(
                value = query, onValueChange = { query = it }, singleLine = true,
                placeholder = { Text("Search for a version") },
                modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp),
            )
            Row(Modifier.padding(horizontal = 20.dp, vertical = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for ((label, yt) in listOf("YouTube Music" to false, "YouTube" to true)) {
                    val on = youtube == yt
                    Text(
                        label, color = if (on) DriftColors.onAccent else DriftColors.text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.clip(RoundedCornerShape(16.dp)).background(if (on) DriftColors.accent else DriftColors.surface2)
                            .clickable { youtube = yt }.padding(horizontal = 14.dp, vertical = 7.dp),
                    )
                }
            }
            val r = results
            when {
                failed -> Text("Couldn't search. Check your connection.", color = DriftColors.muted, fontSize = 14.sp, modifier = Modifier.padding(20.dp))
                r == null -> Box(Modifier.fillMaxWidth().padding(30.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = DriftColors.accent) }
                r.isEmpty() -> Text("Nothing found. Try other words.", color = DriftColors.muted, fontSize = 14.sp, modifier = Modifier.padding(20.dp))
                else -> LazyColumn(Modifier.fillMaxWidth()) {
                    items(r, key = { it.id }) { v ->
                        val current = v.id == old.id
                        val playing = Playback.current?.id == v.id && Playback.isPlaying
                        Row(
                            Modifier.fillMaxWidth().heightIn(min = 60.dp).clickable(enabled = !current) { use(v) }.padding(start = 20.dp, end = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Artwork(v.artwork(120), v.id, 44.dp)
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text(
                                    v.title, color = if (current) DriftColors.accent else DriftColors.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                                )
                                Text(
                                    listOfNotNull(
                                        if (current) "Now in your list" else null,
                                        if (v.explicit == true) "Explicit" else null,
                                        v.artist, v.album, v.durationText.ifEmpty { null },
                                    ).joinToString(" · "),
                                    color = DriftColors.muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                                )
                            }
                            // Listen first, to tell the versions apart.
                            IconButton(onClick = { if (Playback.current?.id == v.id) Playback.toggle() else Playback.play(listOf(v), 0, "Versions") }) {
                                Icon(
                                    if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                                    contentDescription = if (playing) "Pause" else "Listen", tint = DriftColors.text, modifier = Modifier.size(26.dp),
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
