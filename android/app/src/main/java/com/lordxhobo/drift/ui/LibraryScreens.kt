package com.lordxhobo.drift.ui

import com.lordxhobo.drift.playback.Downloads
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lordxhobo.drift.data.Library
import com.lordxhobo.drift.data.Playlist
import com.lordxhobo.drift.data.formatTotal
import com.lordxhobo.drift.playback.Playback

@Composable
private fun LikedTile(size: androidx.compose.ui.unit.Dp) {
    Box(
        Modifier.size(size).clip(RoundedCornerShape(4.dp)).background(Color(0xFF4338CA)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(Icons.Filled.Favorite, contentDescription = null, tint = Color.White, modifier = Modifier.size(size / 2.6f))
    }
}

@Composable
fun LibraryScreen() {
    var renaming by remember { mutableStateOf<Playlist?>(null) }
    var deleting by remember { mutableStateOf<Playlist?>(null) }
    Column {
        Row(Modifier.fillMaxWidth().padding(start = 16.dp, top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Your Library", color = DriftColors.text, fontSize = 26.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.weight(1f))
            var adding by remember { mutableStateOf(false) }
            Box {
                IconButton(onClick = { adding = true }) {
                    Icon(Icons.Filled.Add, contentDescription = "New playlist or import", tint = DriftColors.text)
                }
                DropdownMenu(expanded = adding, onDismissRequest = { adding = false }) {
                    DropdownMenuItem(text = { Text("New playlist") }, onClick = { adding = false; UiState.newPlaylist = NewPlaylistRequest(null) })
                    DropdownMenuItem(text = { Text("Import from Spotify") }, onClick = { adding = false; Nav.open(Screen.Import()) })
                }
            }
        }
        LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
            item {
                LibraryRow("Liked songs", "Playlist · ${Library.liked.size} songs", onClick = { Nav.open(Screen.Liked) }) { LikedTile(64.dp) }
            }
            items(Library.playlists, key = { it.id }) { p ->
                var menu by remember { mutableStateOf(false) }
                Box {
                    LibraryRow(
                        p.name,
                        if (p.isAlbum == true) "Album · ${p.albumArtist ?: ""}" else "Playlist · ${p.tracks.size} songs",
                        onClick = { Nav.open(Screen.PlaylistPage(p.id)) },
                        onLongClick = { menu = true },
                    ) { PlaylistCover(p, 64.dp) }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(text = { Text("Rename") }, onClick = { menu = false; renaming = p })
                        DropdownMenuItem(text = { Text(if (p.isAlbum == true) "Remove from library" else "Delete playlist") }, onClick = { menu = false; deleting = p })
                    }
                }
            }
            if (Library.playlists.isEmpty()) {
                item { EmptyText("Make a playlist with +, or save an album from its page.") }
            }
        }
    }
    renaming?.let { p ->
        NameDialog("Rename playlist", p.name, "Rename", onDone = { Library.rename(p.id, it) }, onDismiss = { renaming = null })
    }
    deleting?.let { p ->
        ConfirmDialog(
            title = if (p.isAlbum == true) "Remove ${p.name}?" else "Delete ${p.name}?",
            message = "This can't be undone.",
            confirm = if (p.isAlbum == true) "Remove" else "Delete",
            onConfirm = { Library.deletePlaylist(p.id) },
            onDismiss = { deleting = null },
        )
    }
}

/** A playlist's page, or Liked songs (id null). */
@Composable
fun PlaylistScreen(id: String?) {
    val p = id?.let { Library.playlist(it) }
    if (id != null && p == null) {
        Column { BackBar(); EmptyText("This playlist was deleted.") }
        return
    }
    val name = p?.name ?: "Liked songs"
    val tracks = p?.tracks ?: Library.liked
    var menu by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf(false) }
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) { BackBar() }
                if (p != null) {
                    Box {
                        IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, contentDescription = "Playlist options", tint = DriftColors.text) }
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            DropdownMenuItem(text = { Text("Rename") }, onClick = { menu = false; renaming = true })
                            DropdownMenuItem(text = { Text("Delete playlist") }, onClick = {
                                menu = false
                                Library.deletePlaylist(p.id)
                                Nav.back()
                            })
                        }
                    }
                }
            }
        }
        item {
            Column(Modifier.fillMaxWidth().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                if (p != null) PlaylistCover(p, 220.dp) else LikedTile(220.dp)
                Spacer(Modifier.size(16.dp))
                Text(name, color = DriftColors.text, fontSize = 24.sp, fontWeight = FontWeight.ExtraBold)
                Text(
                    if (p?.isAlbum == true) "${p.albumArtist ?: "Album"} · ${tracks.size} songs" else "${tracks.size} songs · ${formatTotal(tracks)}",
                    color = DriftColors.muted, fontSize = 13.sp,
                )
                // While its songs download: how many are on the phone.
                if (Downloads.isKept(p?.id ?: Downloads.LIKED)) {
                    val have = tracks.count { Downloads.isDownloaded(it.id) }
                    Text(
                        if (have >= tracks.size) "Downloaded" else "Downloading · $have of ${tracks.size}" + (Downloads.waiting?.let { " · $it" } ?: ""),
                        color = DriftColors.accent, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 4.dp),
                    )
                }
            }
        }
        if (tracks.isNotEmpty()) {
            item {
                PlayButtons(
                    onPlay = { Playback.play(tracks, 0, name) },
                    onShuffle = { Playback.play(tracks, 0, name, shuffled = true) },
                    downloadId = p?.id ?: Downloads.LIKED,
                )
            }
        }
        itemsIndexed(tracks, key = { i, t -> "$i-${t.id}" }) { i, t ->
            TrackRow(
                t,
                onClick = { Playback.play(tracks, i, name) },
                onMenu = { UiState.openMenu(t, p?.let { it.id to i }) },
            )
        }
        if (tracks.isEmpty()) {
            item { EmptyText(if (p == null) "Songs you like show up here. Tap the heart on any song." else "Add songs from a song's menu (⋮ or hold the song).") }
        }
    }
    if (renaming && p != null) {
        NameDialog("Rename playlist", p.name, "Rename", onDone = { Library.rename(p.id, it) }, onDismiss = { renaming = false })
    }
}
