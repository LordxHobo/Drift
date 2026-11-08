package com.lordxhobo.drift.ui

import androidx.compose.material.icons.filled.People
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Equalizer
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lordxhobo.drift.data.Library
import com.lordxhobo.drift.data.Track
import com.lordxhobo.drift.playback.Playback
import com.lordxhobo.drift.social.Friends
import com.lordxhobo.drift.social.Jam
import androidx.compose.material.icons.filled.Groups
import com.lordxhobo.drift.social.SharedPlaylist
import com.lordxhobo.drift.social.Social
import com.lordxhobo.drift.social.UserProfile
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** "2 min ago", "3 h ago", "yesterday"… for seconds since 1970. */
private fun since(seconds: Long?): String {
    val s = seconds ?: return ""
    val d = System.currentTimeMillis() / 1000 - s
    return when {
        d < 60 -> "just now"
        d < 3600 -> "${d / 60} min ago"
        d < 86400 -> "${d / 3600} h ago"
        d < 2 * 86400 -> "yesterday"
        else -> "${d / 86400} days ago"
    }
}

/** A person in a list: picture, name, and what they're listening to. */
@Composable
private fun PersonRow(u: UserProfile, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 64.dp).clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Avatar(u, 48.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(u.name, color = DriftColors.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            val np = u.nowPlaying
            when {
                u.listeningNow && np != null -> Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Equalizer, contentDescription = "Listening now", tint = DriftColors.accent, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(4.dp))
                    Text("${np.title} · ${np.artist}", color = DriftColors.accent, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                np != null -> Text("${np.title} · ${since(u.updatedAt)}", color = DriftColors.muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                else -> Text("@${u.username}", color = DriftColors.muted, fontSize = 12.sp)
            }
        }
    }
}

// MARK: Friends

@Composable
fun FriendsScreen() {
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<UserProfile>?>(null) }
    LaunchedEffect(Unit) {
        // Refreshed while the page is open (activity changes as people play).
        while (true) {
            Friends.refresh()
            delay(30_000)
        }
    }
    LaunchedEffect(query) {
        if (query.isBlank()) {
            results = null
            return@LaunchedEffect
        }
        delay(350)
        results = Friends.search(query)
    }
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        item { BackBar() }
        item {
            Text("Friends", color = DriftColors.text, fontSize = 26.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 12.dp))
        }
        if (Social.me == null) {
            item {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Make a Drift profile to follow friends and see what they're listening to.", color = DriftColors.text2, fontSize = 15.sp)
                    Button(
                        onClick = { Nav.open(Screen.Account) },
                        colors = ButtonDefaults.buttonColors(containerColor = DriftColors.accent, contentColor = DriftColors.onAccent),
                    ) { Text("Create a profile", fontWeight = FontWeight.Bold) }
                }
            }
            return@LazyColumn
        }
        item {
            OutlinedTextField(
                value = query, onValueChange = { query = it },
                placeholder = { Text("Find people by name or username") },
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }
        val r = results
        if (r != null) {
            if (r.isEmpty()) item { EmptyText("No one found.") }
            items(r, key = { "search-" + it.id }) { u -> PersonRow(u) { Nav.open(Screen.User(u.id)) } }
            return@LazyColumn
        }
        if (Friends.friends.isEmpty()) {
            item {
                when {
                    Friends.loading -> Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = DriftColors.accent) }
                    Friends.error != null -> EmptyText(Friends.error!!)
                    else -> EmptyText("Search for friends above and follow them to see what they're listening to.")
                }
            }
        }
        items(Friends.friends, key = { it.id }) { u -> PersonRow(u) { Nav.open(Screen.User(u.id)) } }
        item {
            Text(
                if (Social.me?.shareActivity == false) "You're not sharing what you listen to. Turn it on in Settings → Profile & devices."
                else "Friends see what you're listening to. Turn it off in Settings → Profile & devices.",
                color = DriftColors.muted, fontSize = 12.sp, modifier = Modifier.padding(16.dp),
            )
        }
    }
}

// MARK: Someone's profile

@Composable
fun UserScreen(id: String) {
    val scope = rememberCoroutineScope()
    var user by remember(id) { mutableStateOf<UserProfile?>(Friends.friends.firstOrNull { it.id == id }) }
    var playlists by remember(id) { mutableStateOf<List<SharedPlaylist>?>(null) }
    var followers by remember(id) { mutableStateOf<Int?>(null) }
    var failed by remember(id) { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    LaunchedEffect(id) {
        val u = Friends.user(id)
        if (u == null) {
            failed = user == null
            return@LaunchedEffect
        }
        user = u
        playlists = runCatching { Friends.sharedPlaylists(u) }.getOrDefault(emptyList())
        followers = Friends.followers(id).size
    }
    val u = user
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        item { BackBar() }
        if (u == null) {
            item {
                if (failed) EmptyText("Couldn't load this profile.")
                else Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = DriftColors.accent) }
            }
            return@LazyColumn
        }
        item {
            Column(Modifier.fillMaxWidth().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Avatar(u, 110.dp)
                Spacer(Modifier.size(12.dp))
                Text(u.name, color = DriftColors.text, fontSize = 26.sp, fontWeight = FontWeight.ExtraBold, textAlign = TextAlign.Center)
                Text("@${u.username}", color = DriftColors.muted, fontSize = 14.sp)
                val counts = listOfNotNull(followers?.let { "$it ${if (it == 1) "follower" else "followers"}" }, "${u.following.size} following")
                Text(counts.joinToString(" · "), color = DriftColors.text2, fontSize = 13.sp, modifier = Modifier.padding(top = 4.dp))
                if (u.id != Social.me?.id && Social.me != null) {
                    val following = Friends.isFollowing(u.id)
                    Spacer(Modifier.size(12.dp))
                    if (following) {
                        OutlinedButton(enabled = !working, onClick = {
                            working = true
                            scope.launch { runCatching { Friends.follow(u.id, false) }; working = false }
                        }) { Text("Following", color = DriftColors.text, fontWeight = FontWeight.Bold) }
                    } else {
                        Button(
                            enabled = !working,
                            onClick = {
                                working = true
                                scope.launch { runCatching { Friends.follow(u.id, true) }; working = false }
                            },
                            colors = ButtonDefaults.buttonColors(containerColor = DriftColors.accent, contentColor = DriftColors.onAccent),
                        ) { Text("Follow", fontWeight = FontWeight.Bold) }
                    }
                }
            }
        }
        val jam = u.jam
        if (jam != null && u.id != Social.me?.id && Social.me != null) {
            item {
                val inIt = Jam.state?.code == jam
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp).clip(RoundedCornerShape(10.dp)).background(DriftColors.surface)
                        .clickable(enabled = !working && !inIt) {
                            working = true
                            scope.launch { runCatching { joinFriend(u) }.onFailure { Jam.notice = it.message ?: "Couldn't join." }; working = false }
                        }
                        .padding(14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Filled.Groups, contentDescription = null, tint = DriftColors.accent)
                    Spacer(Modifier.width(12.dp))
                    Text(
                        if (inIt) "You're listening together" else "${u.name} is in a Listen Together session",
                        color = DriftColors.text, fontSize = 14.sp, modifier = Modifier.weight(1f),
                    )
                    if (!inIt) Text("Join", color = DriftColors.accent, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                }
            }
        }
        u.nowPlaying?.let { np ->
            item { SectionTitle(if (u.listeningNow) "Listening now" else "Last played · ${since(u.updatedAt)}") }
            item {
                TrackRow(np, onClick = { Playback.play(listOf(np), 0, u.name) }, onMenu = { UiState.openMenu(np) })
            }
        }
        val list = playlists
        if (list != null && list.isNotEmpty()) {
            item { SectionTitle("Playlists") }
            items(list, key = { it.id }) { p ->
                LibraryRow(p.name, p.subtitle, onClick = { Nav.open(Screen.SharedList(p.ownerId, p.id, p.name, p.ownerName)) }) {
                    SharedCover(p.preview, p.id)
                }
            }
        }
    }
}

/** Up to four covers, like a playlist's. */
@Composable
private fun SharedCover(preview: List<Track>, seed: String) {
    val arts = preview.map { it.artwork(226) }.distinct()
    if (arts.size >= 4) {
        Column(Modifier.size(64.dp).clip(RoundedCornerShape(4.dp))) {
            Row { Artwork(arts[0], seed, 32.dp, RoundedCornerShape(0.dp)); Artwork(arts[1], seed, 32.dp, RoundedCornerShape(0.dp)) }
            Row { Artwork(arts[2], seed, 32.dp, RoundedCornerShape(0.dp)); Artwork(arts[3], seed, 32.dp, RoundedCornerShape(0.dp)) }
        }
    } else {
        Artwork(arts.firstOrNull(), seed, 64.dp)
    }
}

// MARK: A playlist someone shows

@Composable
fun SharedListScreen(ownerId: String, id: String, name: String, ownerName: String) {
    var tracks by remember(id) { mutableStateOf<List<Track>?>(null) }
    var saved by remember(id) { mutableStateOf(false) }
    LaunchedEffect(id) { tracks = runCatching { Friends.sharedTracks(ownerId, id) }.getOrDefault(emptyList()) }
    val list = tracks
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        item { BackBar() }
        item {
            Column(Modifier.fillMaxWidth().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                SharedCover(list.orEmpty().take(4), id)
                Spacer(Modifier.size(12.dp))
                Text(name, color = DriftColors.text, fontSize = 24.sp, fontWeight = FontWeight.ExtraBold, textAlign = TextAlign.Center)
                Text("By $ownerName · ${list?.size ?: 0} songs", color = DriftColors.muted, fontSize = 13.sp)
            }
        }
        if (list == null) {
            item { Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = DriftColors.accent) } }
            return@LazyColumn
        }
        if (list.isNotEmpty()) {
            item {
                PlayButtons(onPlay = { Playback.play(list, 0, name) }, onShuffle = { Playback.play(list, 0, name, shuffled = true) })
            }
            item {
                // A copy in your library (it doesn't follow their changes).
                Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
                    OutlinedButton(enabled = !saved, onClick = {
                        Library.createPlaylist(name, list)
                        saved = true
                    }) { Text(if (saved) "Saved to Your Library" else "Save a copy", color = DriftColors.text) }
                }
            }
        }
        itemsIndexed(list, key = { i, t -> "$i-${t.id}" }) { i, t ->
            TrackRow(t, onClick = { Playback.play(list, i, name) }, onMenu = { UiState.openMenu(t) })
        }
    }
}

/** The people button on Home: friends listening now show as a green dot. */
@Composable
fun FriendsButton() {
    LaunchedEffect(Social.me?.id) { if (Social.me != null) Friends.refresh() }
    val listening = Friends.friends.count { it.listeningNow }
    Box(
        Modifier.clip(CircleShape).clickable { Nav.open(Screen.Friends) }.padding(8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Icon(Icons.Filled.People, contentDescription = "Friends", tint = DriftColors.text)
        if (listening > 0) {
            Box(Modifier.align(Alignment.TopEnd).size(9.dp).clip(CircleShape).background(DriftColors.accent))
        }
    }
}
