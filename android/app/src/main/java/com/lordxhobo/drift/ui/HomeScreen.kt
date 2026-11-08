package com.lordxhobo.drift.ui

import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import com.lordxhobo.drift.social.Social
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lordxhobo.drift.data.Library
import com.lordxhobo.drift.playback.Playback
import java.util.Calendar

@Composable
fun HomeScreen() {
    val hour = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
    val greeting = when (hour) {
        in 5..11 -> "Good morning"
        in 12..17 -> "Good afternoon"
        else -> "Good evening"
    }
    val shortcuts = Library.playlists.take(5)
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        item {
            Row(
                Modifier.padding(start = 16.dp, end = 12.dp, top = 12.dp, bottom = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    greeting, color = DriftColors.text, fontSize = 26.sp, fontWeight = FontWeight.ExtraBold,
                    modifier = Modifier.weight(1f),
                )
                Box(
                    Modifier.clip(CircleShape).clickable { Nav.open(Screen.Stats) }.padding(8.dp),
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Filled.BarChart, contentDescription = "Listening stats", tint = DriftColors.text) }
                FriendsButton()
                // Your picture opens Settings (profile, linking, and the rest).
                Box(
                    Modifier.clip(CircleShape).clickable { Nav.open(Screen.Settings) }.padding(4.dp)
                        .semantics { contentDescription = "Settings" },
                ) {
                    Avatar(Social.me, 34.dp)
                }
            }
        }
        // Liked songs and your playlists, two to a row (like Spotify's home).
        item {
            Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                // null = Liked songs.
                val tiles: List<com.lordxhobo.drift.data.Playlist?> = listOf<com.lordxhobo.drift.data.Playlist?>(null) + shortcuts
                tiles.chunked(2).forEach { pair ->
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        pair.forEach { p ->
                            if (p == null) {
                                Shortcut("Liked songs", Modifier.weight(1f), onClick = { Nav.open(Screen.Liked) }) {
                                    Box(Modifier.size(56.dp).background(Color(0xFF4338CA)), contentAlignment = Alignment.Center) {
                                        Icon(Icons.Filled.Favorite, contentDescription = null, tint = Color.White)
                                    }
                                }
                            } else {
                                Shortcut(p.name, Modifier.weight(1f), onClick = { Nav.open(Screen.PlaylistPage(p.id)) }) { PlaylistCover(p, 56.dp) }
                            }
                        }
                        if (pair.size == 1) Box(Modifier.weight(1f))
                    }
                }
            }
        }
        if (Library.recent.isNotEmpty()) {
            item { SectionTitle("Recently played") }
            item {
                LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    items(Library.recent, key = { it.id }) { t ->
                        Column(Modifier.width(140.dp).clickable { Playback.play(Library.recent, Library.recent.indexOf(t), "Recently played") }) {
                            Artwork(t.artwork(300), t.id, 140.dp)
                            Text(t.title, color = DriftColors.text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 6.dp))
                            Text(t.artist, color = DriftColors.muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
            }
        }
        if (Library.playlists.isEmpty() && Library.recent.isEmpty()) {
            item { EmptyText("Search for a song to start listening. Your playlists and recently played songs show up here.") }
        }
    }
}

@Composable
private fun Shortcut(title: String, modifier: Modifier, onClick: () -> Unit, art: @Composable () -> Unit) {
    Row(
        modifier
            .height(56.dp)
            .clip(RoundedCornerShape(4.dp))
            .background(DriftColors.surface)
            .clickable(onClick = onClick),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        art()
        Text(
            title, color = DriftColors.text, fontSize = 13.sp, fontWeight = FontWeight.Bold, maxLines = 2,
            overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(horizontal = 10.dp),
        )
    }
}
