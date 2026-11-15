package com.lordxhobo.drift.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.lordxhobo.drift.data.AlbumRef
import com.lordxhobo.drift.data.ArtistRef
import com.lordxhobo.drift.data.Track

/** The pages, each tab keeping its own stack (like the iPhone app). */
sealed interface Screen {
    data object Home : Screen
    data object Search : Screen
    data object Library : Screen
    data object Liked : Screen
    data class PlaylistPage(val id: String) : Screen
    data class ArtistPage(val ref: ArtistRef) : Screen
    data class AlbumPage(val ref: AlbumRef) : Screen
    data object Settings : Screen
    data object Account : Screen
    data object LinkComputer : Screen
    data object Storage : Screen
    data object PlaybackSettings : Screen
    data object Equalizer : Screen
    /** Spotify import; `link` when one was shared into Drift. */
    data class Import(val link: String? = null) : Screen
    data class Folder(val id: String) : Screen
    data class EditPlaylist(val id: String) : Screen
    data class EditSongs(val id: String) : Screen
    data object Friends : Screen
    data object Stats : Screen
    data object Notifications : Screen
    data object Podcasts : Screen
    data class Show(val channel: com.lordxhobo.drift.podcasts.PodcastChannel) : Screen
    data object NotificationSettings : Screen
    data class User(val id: String) : Screen
    data class SharedList(val ownerId: String, val id: String, val name: String, val ownerName: String) : Screen
    // The YouTube viewer
    data object YTSignIn : Screen
    data object YTHome : Screen
    data object YTSubscriptions : Screen
    data object YTLibrary : Screen
    data object YTSearch : Screen
    data class YTFeed(val feed: com.lordxhobo.drift.youtube.YTViewer.Feed) : Screen
    data class YTChannel(val id: String) : Screen
    data class YTWatch(val id: String) : Screen
}

enum class Tab { HOME, SEARCH, PODCASTS, LIBRARY, YT_HOME, YT_SUBS, YT_LIBRARY, YT_SEARCH }

object Nav {
    var tab by mutableStateOf(Tab.HOME)
    private val stacks = mapOf(
        Tab.HOME to mutableStateListOf<Screen>(Screen.Home),
        Tab.SEARCH to mutableStateListOf<Screen>(Screen.Search),
        Tab.PODCASTS to mutableStateListOf<Screen>(Screen.Podcasts),
        Tab.LIBRARY to mutableStateListOf<Screen>(Screen.Library),
        Tab.YT_HOME to mutableStateListOf<Screen>(Screen.YTHome),
        Tab.YT_SUBS to mutableStateListOf<Screen>(Screen.YTSubscriptions),
        Tab.YT_LIBRARY to mutableStateListOf<Screen>(Screen.YTLibrary),
        Tab.YT_SEARCH to mutableStateListOf<Screen>(Screen.YTSearch),
    )

    /** The first tab: Home, or the YouTube viewer's Home. */
    val homeTab: Tab get() = if (com.lordxhobo.drift.youtube.YTViewer.on) Tab.YT_HOME else Tab.HOME

    val stack get() = stacks.getValue(tab)
    val top: Screen get() = stack.last()

    fun open(s: Screen) {
        UiState.showPlayer = false
        stack.add(s)
    }

    /** Back one page. False when already at the start of the tab. */
    fun back(): Boolean {
        val st = stack
        if (st.size <= 1) return false
        st.removeAt(st.lastIndex)
        return true
    }

    /** Tapping the tab you're on goes back to its start. */
    fun select(t: Tab) {
        if (t == tab) {
            val st = stack
            while (st.size > 1) st.removeAt(st.lastIndex)
        }
        tab = t
    }
}

/** What's open over the pages: the player, the queue, a song's menu, dialogs. */
object UiState {
    var showPlayer by mutableStateOf(false)
    var showQueue by mutableStateOf(false)
    var menuTrack by mutableStateOf<Track?>(null)
    /** The playlist a song menu was opened from (so it can offer "Remove from this playlist"). */
    var menuPlace by mutableStateOf<Pair<String, Int>?>(null)
    var addToPlaylist by mutableStateOf<Track?>(null)
    /** Asking for a new playlist's name (with a song to put in it, or none). */
    var newPlaylist by mutableStateOf<NewPlaylistRequest?>(null)
    /** Every What's new note (opened from Settings). */
    var showAllNotes by mutableStateOf(false)
    /** Lyrics over the player. */
    var showLyrics by mutableStateOf(false)
    /** "Play on": this phone or another device. */
    var showDevices by mutableStateOf(false)
    /** Listen Together (start, join, who's in it). */
    var showJam by mutableStateOf(false)
    /** The song friends are being invited to listen to. */
    var inviteTrack by mutableStateOf<Track?>(null)

    /** The song being shared (link or picture). */
    var sharing by mutableStateOf<Track?>(null)
    /** "Replace with another version": the song, and its list and place in it. */
    var replacing by mutableStateOf<Triple<Track, String, Int>?>(null)

    fun openMenu(t: Track, place: Pair<String, Int>? = null) {
        menuPlace = place
        menuTrack = t
    }
}

data class NewPlaylistRequest(val track: Track?)
