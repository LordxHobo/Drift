package com.lordxhobo.drift.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lordxhobo.drift.data.AlbumRef
import com.lordxhobo.drift.data.ArtistRef
import com.lordxhobo.drift.data.Library
import com.lordxhobo.drift.playback.Playback
import com.lordxhobo.drift.youtube.YouTube

@Composable
private fun Loading() {
    Box(Modifier.fillMaxWidth().padding(48.dp), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(color = DriftColors.accent)
    }
}

@Composable
fun ArtistScreen(ref: ArtistRef) {
    var page by remember { mutableStateOf<YouTube.ArtistPage?>(null) }
    var failed by remember { mutableStateOf(false) }
    LaunchedEffect(ref.url) {
        failed = false
        page = runCatching { YouTube.artist(ref) }.getOrNull()
        if (page == null) failed = true
    }
    val artist = page?.artist ?: ref
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        item { BackBar() }
        item {
            Column(Modifier.fillMaxWidth().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Artwork(artist.thumbnail, artist.name, 180.dp, CircleShape)
                Spacer(Modifier.size(14.dp))
                Text(artist.name, color = DriftColors.text, fontSize = 28.sp, fontWeight = FontWeight.ExtraBold, textAlign = TextAlign.Center)
            }
        }
        val p = page
        when {
            failed -> item { EmptyText("Couldn't load this artist. Check your connection and try again.") }
            p == null -> item { Loading() }
            else -> {
                if (p.songs.isNotEmpty()) {
                    item {
                        PlayButtons(
                            onPlay = { Playback.play(p.songs, 0, p.artist.name) },
                            onShuffle = { Playback.play(p.songs, 0, p.artist.name, shuffled = true) },
                        )
                    }
                    item { SectionTitle("Popular") }
                    itemsIndexed(p.songs, key = { i, t -> "$i-${t.id}" }) { i, t ->
                        TrackRow(t, onClick = { Playback.play(p.songs, i, p.artist.name) }, onMenu = { UiState.openMenu(t) })
                    }
                }
                if (p.albums.isNotEmpty()) {
                    item { SectionTitle("Albums") }
                    item {
                        LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            itemsIndexed(p.albums, key = { i, a -> "$i-${a.url}" }) { _, a ->
                                Column(Modifier.width(140.dp).clickable { Nav.open(Screen.AlbumPage(a)) }) {
                                    Artwork(a.thumbnail, a.title, 140.dp)
                                    Text(a.title, color = DriftColors.text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 6.dp))
                                }
                            }
                        }
                    }
                }
                if (p.songs.isEmpty() && p.albums.isEmpty()) item { EmptyText("No songs found for this artist.") }
            }
        }
    }
}

@Composable
fun AlbumScreen(ref: AlbumRef) {
    var page by remember { mutableStateOf<YouTube.AlbumPage?>(null) }
    var failed by remember { mutableStateOf(false) }
    LaunchedEffect(ref.url) {
        failed = false
        page = runCatching { YouTube.album(ref) }.getOrNull()
        if (page == null) failed = true
    }
    val album = page?.album ?: ref
    val saved = Library.playlists.any { it.isAlbum == true && it.name == album.title && it.albumArtist == album.artist }
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        item { BackBar() }
        item {
            Column(Modifier.fillMaxWidth().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Artwork(album.thumbnail, album.title, 220.dp)
                Spacer(Modifier.size(16.dp))
                Text(album.title, color = DriftColors.text, fontSize = 24.sp, fontWeight = FontWeight.ExtraBold, textAlign = TextAlign.Center)
                Text(album.artist, color = DriftColors.muted, fontSize = 14.sp)
            }
        }
        val p = page
        when {
            failed -> item { EmptyText("Couldn't load this album. Check your connection and try again.") }
            p == null -> item { Loading() }
            else -> {
                item {
                    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                        OutlinedButton(
                            onClick = { if (!saved) Library.saveAlbum(p.album.title, p.album.artist, p.tracks) },
                            colors = ButtonDefaults.outlinedButtonColors(contentColor = if (saved) DriftColors.accent else DriftColors.text),
                        ) { Text(if (saved) "In your library" else "Save to your library") }
                    }
                }
                item {
                    PlayButtons(
                        onPlay = { Playback.play(p.tracks, 0, p.album.title) },
                        onShuffle = { Playback.play(p.tracks, 0, p.album.title, shuffled = true) },
                    )
                }
                itemsIndexed(p.tracks, key = { i, t -> "$i-${t.id}" }) { i, t ->
                    TrackRow(t, onClick = { Playback.play(p.tracks, i, p.album.title) }, onMenu = { UiState.openMenu(t) }, number = i + 1, showArt = false)
                }
            }
        }
    }
}
