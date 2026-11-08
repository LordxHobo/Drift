package com.lordxhobo.drift.ui

import com.lordxhobo.drift.social.CollabSync
import com.lordxhobo.drift.social.Friends
import com.lordxhobo.drift.social.Social
import com.lordxhobo.drift.social.UserProfile
import androidx.compose.material3.Checkbox
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.LaunchedEffect
import kotlinx.coroutines.launch
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.TextButton
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.unit.Dp
import androidx.compose.foundation.clickable
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
    var moving by remember { mutableStateOf<Playlist?>(null) }
    var newFolder by remember { mutableStateOf(false) }
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
                    DropdownMenuItem(text = { Text("New folder") }, onClick = { adding = false; newFolder = true })
                    DropdownMenuItem(text = { Text("Import from Spotify") }, onClick = { adding = false; Nav.open(Screen.Import()) })
                }
            }
        }
        LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
            item {
                LibraryRow("Liked songs", "Playlist · ${Library.liked.size} songs", onClick = { Nav.open(Screen.Liked) }) { LikedTile(64.dp) }
            }
            items(Library.folders, key = { "folder-" + it.id }) { f ->
                val inside = Library.playlists.count { it.folder == f.id }
                LibraryRow(f.name, "Folder · $inside ${if (inside == 1) "playlist" else "playlists"}", onClick = { Nav.open(Screen.Folder(f.id)) }) { FolderTile(64.dp) }
            }
            // Playlists in a folder show inside it (and here if their folder is gone).
            val folderIds = Library.folders.map { it.id }.toSet()
            items(Library.playlists.filter { it.folder == null || it.folder !in folderIds }, key = { it.id }) { p ->
                PlaylistRow(p, onRename = { renaming = p }, onDelete = { deleting = p }, onMove = { moving = p })
            }
            if (Library.followed.isNotEmpty()) {
                item { SectionTitle("Artists") }
                items(Library.followed, key = { "artist-" + it.url }) { a ->
                    LibraryRow(a.name, "Artist", onClick = { Nav.open(Screen.ArtistPage(a)) }) { Artwork(a.thumbnail, a.name, 64.dp, CircleShape) }
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
    moving?.let { p -> MoveToFolderDialog(p) { moving = null } }
    if (newFolder) {
        NameDialog("New folder", "", "Create", onDone = { Library.createFolder(it) }, onDismiss = { newFolder = false })
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

/** A playlist in a list, with its menu on a long press. */
@Composable
private fun PlaylistRow(p: Playlist, onRename: () -> Unit, onDelete: () -> Unit, onMove: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box {
        LibraryRow(
            p.name,
            when {
                p.isAlbum == true -> "Album · ${p.albumArtist ?: ""}"
                p.collab != null -> "Shared playlist · ${p.tracks.size} songs"
                else -> "Playlist · ${p.tracks.size} songs"
            },
            onClick = { Nav.open(Screen.PlaylistPage(p.id)) },
            onLongClick = { menu = true },
        ) { PlaylistCover(p, 64.dp) }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("Rename") }, onClick = { menu = false; onRename() })
            DropdownMenuItem(text = { Text("Move to folder") }, onClick = { menu = false; onMove() })
            DropdownMenuItem(text = { Text(if (p.isAlbum == true) "Remove from library" else "Delete playlist") }, onClick = { menu = false; onDelete() })
        }
    }
}

@Composable
fun FolderTile(size: Dp) {
    Box(Modifier.size(size).clip(RoundedCornerShape(4.dp)).background(DriftColors.surface2), contentAlignment = Alignment.Center) {
        Icon(Icons.Filled.Folder, contentDescription = null, tint = DriftColors.muted, modifier = Modifier.size(size * 0.45f))
    }
}

/** Pick a folder for a playlist (or none, or a new one). */
@Composable
private fun MoveToFolderDialog(p: Playlist, onDismiss: () -> Unit) {
    var naming by remember { mutableStateOf(false) }
    if (naming) {
        NameDialog("New folder", "", "Create", onDone = { Library.createFolder(it, listOf(p.id)) }, onDismiss = onDismiss)
        return
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Move \"${p.name}\"") },
        text = {
            Column {
                for (f in Library.folders) {
                    Text(
                        (if (p.folder == f.id) "✓ " else "") + f.name, color = DriftColors.text, fontSize = 16.sp,
                        modifier = Modifier.fillMaxWidth().clickable { Library.moveToFolder(p.id, f.id); onDismiss() }.padding(vertical = 12.dp),
                    )
                }
                Text(
                    "New folder…", color = DriftColors.accent, fontSize = 16.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.fillMaxWidth().clickable { naming = true }.padding(vertical = 12.dp),
                )
                if (p.folder != null) {
                    Text(
                        "Take out of its folder", color = DriftColors.text2, fontSize = 16.sp,
                        modifier = Modifier.fillMaxWidth().clickable { Library.moveToFolder(p.id, null); onDismiss() }.padding(vertical = 12.dp),
                    )
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        containerColor = DriftColors.surface,
    )
}

/** A folder's playlists. */
@Composable
fun FolderScreen(id: String) {
    val f = Library.folders.firstOrNull { it.id == id }
    if (f == null) {
        Column { BackBar(); EmptyText("This folder was deleted.") }
        return
    }
    var menu by remember { mutableStateOf(false) }
    var renamingFolder by remember { mutableStateOf(false) }
    var deletingFolder by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf<Playlist?>(null) }
    var deleting by remember { mutableStateOf<Playlist?>(null) }
    var moving by remember { mutableStateOf<Playlist?>(null) }
    val inside = Library.playlists.filter { it.folder == id }
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) { BackBar() }
                Box {
                    IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, contentDescription = "Folder options", tint = DriftColors.text) }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(text = { Text("Rename folder") }, onClick = { menu = false; renamingFolder = true })
                        DropdownMenuItem(text = { Text("Delete folder") }, onClick = { menu = false; deletingFolder = true })
                    }
                }
            }
        }
        item {
            Text(f.name, color = DriftColors.text, fontSize = 26.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 12.dp))
        }
        items(inside, key = { it.id }) { p ->
            PlaylistRow(p, onRename = { renaming = p }, onDelete = { deleting = p }, onMove = { moving = p })
        }
        if (inside.isEmpty()) item { EmptyText("Move playlists here: hold a playlist in Your Library → Move to folder.") }
    }
    if (renamingFolder) NameDialog("Rename folder", f.name, "Rename", onDone = { Library.renameFolder(id, it) }, onDismiss = { renamingFolder = false })
    if (deletingFolder) {
        ConfirmDialog(
            title = "Delete ${f.name}?",
            message = "The folder goes; its playlists stay in Your Library.",
            confirm = "Delete",
            onConfirm = { Library.deleteFolder(id); Nav.back() },
            onDismiss = { deletingFolder = false },
        )
    }
    renaming?.let { p -> NameDialog("Rename playlist", p.name, "Rename", onDone = { Library.rename(p.id, it) }, onDismiss = { renaming = null }) }
    moving?.let { p -> MoveToFolderDialog(p) { moving = null } }
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
    var sharing by remember { mutableStateOf(false) }
    var collabError by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) { BackBar() }
                if (p != null) {
                    Box {
                        IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, contentDescription = "Playlist options", tint = DriftColors.text) }
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            DropdownMenuItem(text = { Text("Edit playlist") }, onClick = { menu = false; Nav.open(Screen.EditPlaylist(p.id)) })
                            if (p.tracks.isNotEmpty()) DropdownMenuItem(text = { Text("Edit songs") }, onClick = { menu = false; Nav.open(Screen.EditSongs(p.id)) })
                            val c = p.collab
                            val mine = c == null || c.owner == Social.me?.id
                            if (Social.me != null && p.isAlbum != true && mine) {
                                DropdownMenuItem(text = { Text(if (c == null) "Share with friends" else "Change who's in it") }, onClick = { menu = false; sharing = true })
                            }
                            when {
                                c != null && mine -> DropdownMenuItem(text = { Text("Stop sharing") }, onClick = {
                                    menu = false
                                    scope.launch { collabError = runCatching { CollabSync.stop(p.id) }.exceptionOrNull()?.let { "Couldn't stop sharing. Check your connection." } }
                                })
                                c != null -> DropdownMenuItem(text = { Text("Leave shared playlist") }, onClick = {
                                    menu = false
                                    scope.launch {
                                        val failed = runCatching { CollabSync.leave(p.id) }.isFailure
                                        if (failed) collabError = "Couldn't leave. Check your connection." else Nav.back()
                                    }
                                })
                                else -> DropdownMenuItem(text = { Text("Delete playlist") }, onClick = {
                                    menu = false
                                    Library.deletePlaylist(p.id)
                                    Nav.back()
                                })
                            }
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
                // Shared: who's in it.
                p?.collab?.let { c ->
                    val others = c.members.filter { it != Social.me?.id }.map { c.names[it] ?: "someone" }
                    Text(
                        if (others.isEmpty()) "Shared playlist" else "Shared with " + others.joinToString(", "),
                        color = DriftColors.accent, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 4.dp),
                    )
                }
                collabError?.let { Text(it, color = DriftColors.error, fontSize = 12.sp, modifier = Modifier.padding(top = 4.dp)) }
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
                onMenu = { UiState.openMenu(t, (p?.id ?: Library.LIKED) to i) },
            )
        }
        if (tracks.isEmpty()) {
            item { EmptyText(if (p == null) "Songs you like show up here. Tap the heart on any song." else "Add songs from a song's menu (⋮ or hold the song).") }
        }
    }
    if (sharing && p != null) {
        ShareDialog(p, onDismiss = { sharing = false }) { people ->
            scope.launch {
                collabError = runCatching { CollabSync.share(p.id, people) }.exceptionOrNull()?.let { it.message ?: "Couldn't share. Check your connection." }
            }
        }
    }
    if (renaming && p != null) {
        NameDialog("Rename playlist", p.name, "Rename", onDone = { Library.rename(p.id, it) }, onDismiss = { renaming = false })
    }
}

/** Pick friends to share a playlist with (everyone picked can add, remove and reorder songs). */
@Composable
private fun ShareDialog(p: Playlist, onDismiss: () -> Unit, onShare: (List<UserProfile>) -> Unit) {
    LaunchedEffect(Unit) { if (Friends.friends.isEmpty()) Friends.refresh() }
    var picked by remember { mutableStateOf(p.collab?.members?.toSet() ?: emptySet()) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Share \"${p.name}\"") },
        text = {
            Column {
                Text("Friends you pick can add, remove and reorder songs. It shows up in their library.", color = DriftColors.text2, fontSize = 13.sp)
                Spacer(Modifier.size(8.dp))
                if (Friends.friends.isEmpty()) {
                    Text("Follow friends first (the people button on Home).", color = DriftColors.muted, fontSize = 13.sp)
                }
                for (f in Friends.friends) {
                    val on = f.id in picked
                    Row(
                        Modifier.fillMaxWidth().clickable { picked = if (on) picked - f.id else picked + f.id }.padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Checkbox(checked = on, onCheckedChange = { picked = if (it) picked + f.id else picked - f.id })
                        Avatar(f, 32.dp)
                        Spacer(Modifier.size(10.dp))
                        Text(f.name, color = DriftColors.text, fontSize = 15.sp)
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = picked.any { id -> Friends.friends.any { it.id == id } } || p.collab != null,
                onClick = {
                    onShare(Friends.friends.filter { it.id in picked })
                    onDismiss()
                },
            ) { Text("Share") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        containerColor = DriftColors.surface,
    )
}
