package com.lordxhobo.drift.ui

import androidx.compose.material.icons.filled.ArrowCircleDown
import androidx.compose.material.icons.outlined.ArrowCircleDown
import com.lordxhobo.drift.playback.Downloads
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.PlaylistAdd
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.automirrored.filled.PlaylistPlay
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lordxhobo.drift.data.ArtistRef
import com.lordxhobo.drift.data.Library
import com.lordxhobo.drift.data.Track
import com.lordxhobo.drift.playback.Playback
import com.lordxhobo.drift.social.Social
import com.lordxhobo.drift.youtube.YouTube
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/** Everything that opens over the pages: the song menu, Add to playlist, New playlist, the queue. */
@Composable
fun SongSheets() {
    UiState.menuTrack?.let { SongMenu(it) }
    UiState.addToPlaylist?.let { AddToPlaylistSheet(it) }
    UiState.replacing?.let { (t, list, index) -> ReplaceSheet(t, list, index) }
    UiState.sharing?.let { ShareSheet(it) }
    UiState.newPlaylist?.let { req ->
        NameDialog(
            title = "New playlist",
            initial = "",
            confirm = "Create",
            onDone = { name ->
                val p = Library.createPlaylist(name, listOfNotNull(req.track))
                if (req.track == null) Nav.open(Screen.PlaylistPage(p.id))
            },
            onDismiss = { UiState.newPlaylist = null },
        )
    }
    if (UiState.showQueue) QueueSheet()
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SongMenu(t: Track) {
    val close = { UiState.menuTrack = null }
    ModalBottomSheet(onDismissRequest = close, sheetState = rememberModalBottomSheetState(), containerColor = DriftColors.surface) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Artwork(t.artwork(120), t.id, 48.dp)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(t.title, color = DriftColors.text, fontSize = 16.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(t.artist, color = DriftColors.muted, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        val liked = Library.isLiked(t.id)
        MenuItem(if (liked) "Remove from Liked songs" else "Like", if (liked) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder) {
            Library.toggleLike(t); close()
        }
        MenuItem("Play next", Icons.AutoMirrored.Filled.PlaylistPlay) { Playback.playNext(t); close() }
        MenuItem("Add to queue", Icons.AutoMirrored.Filled.QueueMusic) { Playback.addToQueue(t); close() }
        MenuItem("Add to playlist", Icons.AutoMirrored.Filled.PlaylistAdd) { close(); UiState.addToPlaylist = t }
        MenuItem("Share", Icons.Filled.Share) { close(); UiState.sharing = t }
        if (Social.me != null) MenuItem("Invite to listen together", Icons.Filled.Groups) { close(); UiState.inviteTrack = t }
        if (Social.me != null) MenuItem("Send to a friend", Icons.AutoMirrored.Filled.Send) { close(); com.lordxhobo.drift.social.Inbox.sending = t }
        UiState.menuPlace?.let { (playlistId, index) ->
            MenuItem("Replace with another version", Icons.Filled.SwapHoriz) { close(); UiState.replacing = Triple(t, playlistId, index) }
            if (playlistId != Library.LIKED) MenuItem("Remove from this playlist", Icons.Filled.Delete) { Library.remove(index, playlistId); close() }
        }
        // Single songs; songs in a downloaded playlist come and go with it.
        when {
            !Downloads.isDownloaded(t.id) && !Downloads.isManual(t.id) ->
                MenuItem("Download", Icons.Outlined.ArrowCircleDown) { Downloads.downloadSong(t); close() }
            Downloads.isManual(t.id) ->
                MenuItem("Remove download", Icons.Filled.ArrowCircleDown) { Downloads.remove(t.id); close() }
        }
        if (t.artist.isNotBlank()) {
            MenuItem("Go to artist", Icons.Filled.Person) {
                close()
                UiState.showPlayer = false
                // Finds the artist by name (songs don't carry their artist's page).
                CoroutineScope(Dispatchers.Main).launch {
                    val found = runCatching { YouTube.search(t.artist).artists.firstOrNull() }.getOrNull()
                    Nav.open(Screen.ArtistPage(found ?: ArtistRef("", t.artist, null)))
                }
            }
        }
        Spacer(Modifier.size(24.dp))
    }
}

@Composable
private fun MenuItem(label: String, icon: ImageVector, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 52.dp).clickable(onClick = onClick).padding(horizontal = 20.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        Icon(icon, contentDescription = null, tint = DriftColors.text2)
        Text(label, color = DriftColors.text, fontSize = 16.sp)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AddToPlaylistSheet(t: Track) {
    val close = { UiState.addToPlaylist = null }
    ModalBottomSheet(onDismissRequest = close, sheetState = rememberModalBottomSheetState(), containerColor = DriftColors.surface) {
        Text("Add to playlist", color = DriftColors.text, fontSize = 18.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp))
        LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
            item {
                LibraryRow("New playlist", "", onClick = { close(); UiState.newPlaylist = NewPlaylistRequest(t) }) {
                    Box(
                        Modifier.size(48.dp).clip(RoundedCornerShape(4.dp)).background(DriftColors.surface2),
                        contentAlignment = Alignment.Center,
                    ) { Icon(Icons.Filled.Add, contentDescription = null, tint = DriftColors.text) }
                }
            }
            items(Library.playlists.filter { it.isAlbum != true }, key = { it.id }) { p ->
                val has = p.tracks.any { it.id == t.id }
                LibraryRow(p.name, if (has) "Already in it" else "${p.tracks.size} songs", onClick = { Library.add(t, p.id); close() }) {
                    PlaylistCover(p, 48.dp)
                }
            }
        }
    }
}

/** The queue: what's playing and what's next. Tap a song to play it; arrows move it; × removes it. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun QueueSheet() {
    val close = { UiState.showQueue = false }
    ModalBottomSheet(onDismissRequest = close, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = DriftColors.bg) {
        val now = Playback.index
        val next = Playback.upNext
        LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
            Playback.current?.let { t ->
                item { SectionTitle("Now playing") }
                item { TrackRow(t, onClick = {}, onMenu = { UiState.openMenu(t) }) }
            }
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    SectionTitle(if (Playback.playingFrom.isEmpty()) "Next" else "Next from ${Playback.playingFrom}", Modifier.weight(1f))
                    if (next.isNotEmpty()) TextButton(onClick = { Playback.clearUpNext() }) { Text("Clear", color = DriftColors.accent) }
                }
            }
            if (next.isEmpty()) item { EmptyText("Nothing's next. Add songs with Play next or Add to queue in a song's menu.") }
            itemsIndexed(next, key = { i, t -> "${now + 1 + i}-${t.id}" }) { i, t ->
                val at = now + 1 + i
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(start = 16.dp, end = 4.dp)) {
                    Column(Modifier.weight(1f).clickable { Playback.jump(at) }.padding(vertical = 8.dp)) {
                        Text(t.title, color = DriftColors.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(t.artist, color = DriftColors.muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    IconButton(onClick = { Playback.move(at, -1) }, enabled = i > 0) {
                        Icon(Icons.Filled.KeyboardArrowUp, contentDescription = "Move up", tint = if (i > 0) DriftColors.text2 else DriftColors.line)
                    }
                    IconButton(onClick = { Playback.move(at, 1) }, enabled = i < next.size - 1) {
                        Icon(Icons.Filled.KeyboardArrowDown, contentDescription = "Move down", tint = if (i < next.size - 1) DriftColors.text2 else DriftColors.line)
                    }
                    IconButton(onClick = { Playback.removeFromQueue(at) }) {
                        Icon(Icons.Filled.Close, contentDescription = "Remove from queue", tint = DriftColors.muted)
                    }
                }
            }
        }
    }
}

@Composable
fun NameDialog(title: String, initial: String, confirm: String, onDone: (String) -> Unit, onDismiss: () -> Unit) {
    var text by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { OutlinedTextField(value = text, onValueChange = { text = it }, singleLine = true, placeholder = { Text("Name") }) },
        confirmButton = { TextButton(onClick = { onDone(text); onDismiss() }) { Text(confirm) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        containerColor = DriftColors.surface,
    )
}

@Composable
fun ConfirmDialog(title: String, message: String, confirm: String, onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(message) },
        confirmButton = { TextButton(onClick = { onConfirm(); onDismiss() }) { Text(confirm, color = DriftColors.error) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        containerColor = DriftColors.surface,
    )
}
