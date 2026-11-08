package com.lordxhobo.drift.ui

import com.lordxhobo.drift.AppUpdates
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lordxhobo.drift.playback.Playback
import com.lordxhobo.drift.social.Remote

/** The whole app: the current tab's page, the mini player, the tab bar, and what opens over them. */
@Composable
fun DriftRoot() {
    BackHandler(enabled = UiState.showPlayer || Nav.stack.size > 1 || Nav.tab != Tab.HOME) {
        when {
            UiState.showPlayer && UiState.showLyrics -> UiState.showLyrics = false
            UiState.showPlayer -> UiState.showPlayer = false
            !Nav.back() -> Nav.tab = Tab.HOME
        }
    }
    Box(Modifier.fillMaxSize().background(DriftColors.bg)) {
        Column(Modifier.fillMaxSize()) {
            Box(Modifier.weight(1f).fillMaxWidth().statusBarsPadding()) {
                val screen = Nav.top
                key(Nav.tab, Nav.stack.size, screen) { Page(screen) }
            }
            if (Remote.target != null) RemoteMiniBar() else if (Playback.current != null) MiniPlayer()
            TabBar()
        }
        AnimatedVisibility(
            visible = UiState.showPlayer,
            enter = slideInVertically { it },
            exit = slideOutVertically { it },
        ) {
            if (Remote.target != null) RemotePlayerScreen() else NowPlayingScreen()
        }
        SongSheets()
        if (UiState.showDevices) DevicesSheet()
        if (UiState.showJam) JamSheet()
        InviteSheet()
        IncomingInvite()
        NoticeBar()
        // The battery tip waits until What's new is closed.
        if (!WhatsNewOnLaunch()) BatteryTip()
        if (UiState.showAllNotes) AllNotes { UiState.showAllNotes = false }
        if (AppUpdates.prompt) UpdateDialog()
    }
}

@Composable
private fun Page(screen: Screen) {
    when (screen) {
        Screen.Home -> HomeScreen()
        Screen.Search -> SearchScreen()
        Screen.Library -> LibraryScreen()
        Screen.Liked -> PlaylistScreen(null)
        is Screen.PlaylistPage -> PlaylistScreen(screen.id)
        is Screen.ArtistPage -> ArtistScreen(screen.ref)
        is Screen.AlbumPage -> AlbumScreen(screen.ref)
        Screen.Settings -> SettingsScreen()
        Screen.Account -> AccountScreen()
        Screen.LinkComputer -> LinkComputerScreen()
        Screen.Storage -> StorageScreen()
        is Screen.Import -> ImportScreen(screen.link)
        is Screen.Folder -> FolderScreen(screen.id)
        Screen.Friends -> FriendsScreen()
        Screen.Stats -> StatsScreen()
        Screen.PlaybackSettings -> PlaybackSettingsScreen()
        is Screen.User -> UserScreen(screen.id)
        is Screen.SharedList -> SharedListScreen(screen.ownerId, screen.id, screen.name, screen.ownerName)
    }
}

/** A page's top row with a back arrow (pages opened from another page). */
@Composable
fun BackBar(title: String = "") {
    Row(Modifier.fillMaxWidth().height(52.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = { Nav.back() }) {
            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = DriftColors.text)
        }
        Text(title, color = DriftColors.text, fontSize = 17.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun TabBar() {
    Row(
        Modifier
            .fillMaxWidth()
            .background(DriftColors.bg)
            .navigationBarsPadding()
            .height(60.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TabItem(Tab.HOME, "Home", Icons.Filled.Home, Modifier.weight(1f))
        TabItem(Tab.SEARCH, "Search", Icons.Filled.Search, Modifier.weight(1f))
        TabItem(Tab.LIBRARY, "Your Library", Icons.Filled.LibraryMusic, Modifier.weight(1f))
    }
}

@Composable
private fun TabItem(tab: Tab, label: String, icon: ImageVector, modifier: Modifier) {
    val on = Nav.tab == tab
    Column(
        modifier.clickable { Nav.select(tab) }.padding(vertical = 6.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(icon, contentDescription = null, tint = if (on) DriftColors.text else DriftColors.muted, modifier = Modifier.size(24.dp))
        Text(label, color = if (on) DriftColors.text else DriftColors.muted, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** The bar above the tabs: what's playing, play/pause, and a tap opens the player. */
@Composable
private fun MiniPlayer() {
    val t = Playback.current ?: return
    Box(Modifier.padding(horizontal = 8.dp, vertical = 4.dp)) {
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(DriftColors.miniPlayer)
                .clickable { UiState.showPlayer = true },
        ) {
            Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Artwork(t.artwork(120), t.id, 44.dp, RoundedCornerShape(5.dp))
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(t.title, color = DriftColors.text, fontSize = 13.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(t.artist, color = DriftColors.muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                LikeButton(t)
                IconButton(onClick = { Playback.toggle() }) {
                    if (Playback.isBuffering && !Playback.isPlaying) {
                        CircularProgressIndicator(Modifier.size(22.dp), color = DriftColors.text, strokeWidth = 2.dp)
                    } else {
                        Icon(
                            if (Playback.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                            contentDescription = if (Playback.isPlaying) "Pause" else "Play",
                            tint = DriftColors.text,
                        )
                    }
                }
            }
            // How far into the song.
            val progress = if (Playback.duration > 0) (Playback.position.toFloat() / Playback.duration).coerceIn(0f, 1f) else 0f
            Box(Modifier.fillMaxWidth().padding(horizontal = 8.dp).height(2.dp).background(DriftColors.line)) {
                Box(Modifier.fillMaxWidth(progress).height(2.dp).background(DriftColors.accent))
            }
        }
    }
}
