package com.lordxhobo.drift.playback

import android.content.Context
import android.net.Uri
import android.os.Bundle
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaLibraryService.LibraryParams
import androidx.media3.session.MediaLibraryService.MediaLibrarySession
import androidx.media3.session.MediaSession
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.lordxhobo.drift.R
import com.lordxhobo.drift.data.Library
import com.lordxhobo.drift.data.Track
import com.lordxhobo.drift.podcasts.PodcastStore
import com.lordxhobo.drift.youtube.YouTube
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.guava.future
import kotlinx.coroutines.withContext

/**
 * What Android Auto shows: four tabs (Recently played, Liked songs, Your playlists, Podcasts), search, and
 * "Hey Google, play … on Drift". Tapping a song plays its whole list from there; an episode plays on its own,
 * from where it was left.
 *
 * Playable items are "<list>|<index>|<song id>", so the list can be found again when one is picked.
 */
@UnstableApi
class CarLibrary(private val context: Context) : MediaLibrarySession.Callback {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    /** The last search's songs (for the search results page and playing one of them). */
    private var searchQuery = ""
    private var searchResults: List<Track> = emptyList()

    // MARK: Lists

    private fun tracks(list: String): List<Track>? = when {
        list == RECENT -> Library.recent
        list == LIKED -> Library.liked
        list == DOWNLOADS -> Downloads.songs.values.map { it.track }.filter { !it.isEpisode }
        list.startsWith("pl:") -> Library.playlist(list.removePrefix("pl:"))?.tracks
        list == CONTINUE -> PodcastStore.continueListening.map { it.track }
        list == NEW -> PodcastStore.newEpisodes
        list.startsWith("show:") -> PodcastStore.feeds[list.removePrefix("show:")]
        list == SEARCH -> searchResults
        else -> null
    }

    private fun title(list: String): String? = when {
        list == RECENT -> "Recently played"
        list == LIKED -> "Liked songs"
        list == PLAYLISTS -> "Your playlists"
        list == PODCASTS -> "Podcasts"
        list == DOWNLOADS -> "Downloaded"
        list.startsWith("pl:") -> Library.playlist(list.removePrefix("pl:"))?.name
        list == CONTINUE -> "Continue listening"
        list == NEW -> "New episodes"
        list.startsWith("show:") -> PodcastStore.subscriptions.firstOrNull { "show:" + it.id == list }?.name
        list == SEARCH -> "Results for “$searchQuery”"
        else -> null
    }

    private fun icon(name: Int): Uri = Uri.parse("android.resource://${context.packageName}/$name")

    private fun folder(id: String, title: String, art: Uri?, subtitle: String? = null, type: Int = MediaMetadata.MEDIA_TYPE_FOLDER_MIXED): MediaItem =
        MediaItem.Builder()
            .setMediaId(id)
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle(title)
                    .setSubtitle(subtitle)
                    .setArtworkUri(art)
                    .setIsBrowsable(true)
                    .setIsPlayable(false)
                    .setMediaType(type)
                    .build(),
            )
            .build()

    private fun playable(list: String, i: Int, t: Track): MediaItem =
        MediaItem.Builder()
            .setMediaId("$list|$i|${t.id}")
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle(t.title)
                    .setArtist(t.artist)
                    .setSubtitle(t.artist)
                    .setAlbumTitle(t.album)
                    .setArtworkUri(CarArt.uri(context, t.artwork(300)))
                    .setIsBrowsable(false)
                    .setIsPlayable(true)
                    .setMediaType(if (t.isEpisode) MediaMetadata.MEDIA_TYPE_PODCAST_EPISODE else MediaMetadata.MEDIA_TYPE_MUSIC)
                    .build(),
            )
            .build()

    private fun children(parent: String): List<MediaItem>? = when (parent) {
        ROOT -> listOf(
            folder(RECENT, "Recently played", icon(R.drawable.ic_car_recent)),
            folder(LIKED, "Liked songs", icon(R.drawable.ic_car_liked)),
            folder(PLAYLISTS, "Playlists", icon(R.drawable.ic_car_playlists)),
            folder(PODCASTS, "Podcasts", icon(R.drawable.ic_car_podcasts)),
        )
        PLAYLISTS -> buildList {
            if (Downloads.songs.values.any { !it.track.isEpisode }) add(folder(DOWNLOADS, "Downloaded", icon(R.drawable.ic_car_downloads), type = MediaMetadata.MEDIA_TYPE_PLAYLIST))
            for (p in Library.playlists) {
                val art = p.tracks.firstOrNull()?.let { CarArt.uri(context, it.artwork(300)) }
                add(folder("pl:${p.id}", p.name, art, "${p.tracks.size} songs", MediaMetadata.MEDIA_TYPE_PLAYLIST))
            }
        }
        PODCASTS -> buildList {
            if (PodcastStore.continueListening.isNotEmpty()) add(folder(CONTINUE, "Continue listening", icon(R.drawable.ic_car_recent)))
            if (PodcastStore.newEpisodes.isNotEmpty()) add(folder(NEW, "New episodes", icon(R.drawable.ic_car_podcasts)))
            for (c in PodcastStore.subscriptions) {
                add(folder("show:${c.id}", c.name, c.avatarURL?.let { CarArt.uri(context, it) }, type = MediaMetadata.MEDIA_TYPE_PODCAST))
            }
        }
        else -> tracks(parent)?.take(MAX)?.mapIndexed { i, t -> playable(parent, i, t) }
    }

    // MARK: Browsing

    override fun onGetLibraryRoot(session: MediaLibrarySession, browser: MediaSession.ControllerInfo, params: LibraryParams?): ListenableFuture<LibraryResult<MediaItem>> {
        val extras = Bundle().apply {
            // Folders as a grid, songs as a list; search allowed.
            putInt("android.media.browse.CONTENT_STYLE_BROWSABLE_HINT", 2)
            putInt("android.media.browse.CONTENT_STYLE_PLAYABLE_HINT", 1)
            putBoolean("android.media.browse.SEARCH_SUPPORTED", true)
        }
        val root = folder(ROOT, "Drift", null)
        return Futures.immediateFuture(LibraryResult.ofItem(root, LibraryParams.Builder().setExtras(extras).build()))
    }

    override fun onGetChildren(
        session: MediaLibrarySession, browser: MediaSession.ControllerInfo, parentId: String, page: Int, pageSize: Int, params: LibraryParams?,
    ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> {
        val all = children(parentId) ?: return Futures.immediateFuture(LibraryResult.ofError(LibraryResult.RESULT_ERROR_BAD_VALUE))
        return Futures.immediateFuture(LibraryResult.ofItemList(paged(all, page, pageSize), params))
    }

    private fun paged(all: List<MediaItem>, page: Int, size: Int): List<MediaItem> {
        if (size <= 0 || size == Int.MAX_VALUE) return all
        val from = page.toLong() * size
        if (from >= all.size) return emptyList()
        return all.subList(from.toInt(), minOf(all.size, from.toInt() + size))
    }

    override fun onGetItem(session: MediaLibrarySession, browser: MediaSession.ControllerInfo, mediaId: String): ListenableFuture<LibraryResult<MediaItem>> {
        val item = picked(mediaId)?.let { (list, i, t) -> playable(list, i, t) }
            ?: title(mediaId)?.let { folder(mediaId, it, null) }
            ?: return Futures.immediateFuture(LibraryResult.ofError(LibraryResult.RESULT_ERROR_BAD_VALUE))
        return Futures.immediateFuture(LibraryResult.ofItem(item, null))
    }

    override fun onSearch(session: MediaLibrarySession, browser: MediaSession.ControllerInfo, query: String, params: LibraryParams?): ListenableFuture<LibraryResult<Void>> =
        scope.future {
            val found = search(query)
            session.notifySearchResultChanged(browser, query, found.size, params)
            LibraryResult.ofVoid()
        }

    override fun onGetSearchResult(
        session: MediaLibrarySession, browser: MediaSession.ControllerInfo, query: String, page: Int, pageSize: Int, params: LibraryParams?,
    ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> = scope.future {
        val found = if (query == searchQuery) searchResults else search(query)
        LibraryResult.ofItemList(paged(found.mapIndexed { i, t -> playable(SEARCH, i, t) }, page, pageSize), params)
    }

    private suspend fun search(query: String): List<Track> {
        val q = query.trim()
        if (q.isEmpty()) return emptyList()
        if (q == searchQuery && searchResults.isNotEmpty()) return searchResults
        val found = withContext(Dispatchers.IO) { runCatching { YouTube.searchSongsBlocking(q) }.getOrDefault(emptyList()) }
        searchQuery = q
        searchResults = found
        return found
    }

    // MARK: Playing

    /** A playable item's list, place in it and song (still there, in the same place). */
    private fun picked(mediaId: String): Triple<String, Int, Track>? {
        val parts = mediaId.split('|')
        if (parts.size != 3) return null
        val i = parts[1].toIntOrNull() ?: return null
        val list = tracks(parts[0]) ?: return null
        val t = list.getOrNull(i)?.takeIf { it.id == parts[2] } ?: list.firstOrNull { it.id == parts[2] } ?: return null
        return Triple(parts[0], list.indexOf(t), t)
    }

    private fun queued(t: Track): MediaItem = PlaybackService.songItem(Playback.itemOf(t))

    override fun onSetMediaItems(
        mediaSession: MediaSession, controller: MediaSession.ControllerInfo, mediaItems: MutableList<MediaItem>, startIndex: Int, startPositionMs: Long,
    ): ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
        val one = mediaItems.singleOrNull()
        // Picked in the car: its whole list from there (an episode on its own, from where it was left).
        val pick = one?.let { picked(it.mediaId) }
        if (pick != null) {
            val (list, i, t) = pick
            if (t.isEpisode) {
                PodcastStore.started(t.id)
                Playback.cameFrom(t.artist, listOf(t))
                val at = (PodcastStore.resumePosition(t.id) * 1000).toLong()
                return Futures.immediateFuture(MediaSession.MediaItemsWithStartPosition(listOf(queued(t)), 0, at))
            }
            val songs = tracks(list).orEmpty().take(MAX)
            Playback.cameFrom(title(list) ?: "Android Auto", songs)
            return Futures.immediateFuture(MediaSession.MediaItemsWithStartPosition(songs.map { queued(it) }, i.coerceIn(0, maxOf(0, songs.size - 1)), 0))
        }
        // "Hey Google, play … on Drift".
        val spoken = one?.requestMetadata?.searchQuery
        if (one != null && one.mediaId.isEmpty() && spoken != null) {
            return scope.future {
                val songs = if (spoken.isBlank()) Library.liked.shuffled().ifEmpty { Library.recent } else search(spoken)
                val list = songs.take(MAX)
                Playback.cameFrom(if (spoken.isBlank()) "Liked songs" else "“$spoken”", list)
                MediaSession.MediaItemsWithStartPosition(list.map { queued(it) }, 0, 0)
            }
        }
        // From the app (or anything else): as sent.
        return Futures.immediateFuture(MediaSession.MediaItemsWithStartPosition(mediaItems.map { PlaybackService.songItem(it) }, startIndex, startPositionMs))
    }

    override fun onAddMediaItems(
        mediaSession: MediaSession, controller: MediaSession.ControllerInfo, mediaItems: MutableList<MediaItem>,
    ): ListenableFuture<MutableList<MediaItem>> =
        Futures.immediateFuture(
            mediaItems.map { item -> picked(item.mediaId)?.let { queued(it.third) } ?: PlaybackService.songItem(item) }.toMutableList(),
        )

    companion object {
        const val ROOT = "root"
        const val RECENT = "recent"
        const val LIKED = "liked"
        const val PLAYLISTS = "playlists"
        const val PODCASTS = "podcasts"
        const val DOWNLOADS = "downloads"
        const val CONTINUE = "continue"
        const val NEW = "new"
        const val SEARCH = "search"
        /** At most this many songs in a list (Android Auto doesn't need more). */
        const val MAX = 300
    }
}
