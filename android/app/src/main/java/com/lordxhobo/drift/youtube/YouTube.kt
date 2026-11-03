package com.lordxhobo.drift.youtube

import com.lordxhobo.drift.data.AlbumRef
import com.lordxhobo.drift.data.ArtistRef
import com.lordxhobo.drift.data.Track
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import org.schabi.newpipe.extractor.Image
import org.schabi.newpipe.extractor.InfoItem
import org.schabi.newpipe.extractor.MediaFormat
import org.schabi.newpipe.extractor.ServiceList
import org.schabi.newpipe.extractor.channel.ChannelInfo
import org.schabi.newpipe.extractor.channel.ChannelInfoItem
import org.schabi.newpipe.extractor.playlist.PlaylistInfo
import org.schabi.newpipe.extractor.playlist.PlaylistInfoItem
import org.schabi.newpipe.extractor.search.SearchInfo
import org.schabi.newpipe.extractor.stream.AudioStream
import org.schabi.newpipe.extractor.stream.DeliveryMethod
import org.schabi.newpipe.extractor.stream.StreamInfo
import org.schabi.newpipe.extractor.stream.StreamInfoItem
import java.util.concurrent.ConcurrentHashMap

/** Search, artists, albums and audio streams from YouTube Music (through NewPipeExtractor). */
object YouTube {
    private val yt get() = ServiceList.YouTube

    data class SearchResults(
        val songs: List<Track>,
        val artists: List<ArtistRef>,
        val albums: List<AlbumRef>,
    )

    data class ArtistPage(val artist: ArtistRef, val songs: List<Track>, val albums: List<AlbumRef>)
    data class AlbumPage(val album: AlbumRef, val tracks: List<Track>)

    private fun best(images: List<Image>): String? = images.maxByOrNull { it.height }?.url

    private fun videoId(url: String): String? =
        Regex("[?&]v=([\\w-]{11})").find(url)?.groupValues?.get(1)
            ?: Regex("youtu\\.be/([\\w-]{11})").find(url)?.groupValues?.get(1)

    /** "Song Name" by "Artist - Topic" → the artist's own name. */
    private fun cleanArtist(name: String?): String = (name ?: "").removeSuffix(" - Topic").trim()

    private fun track(item: StreamInfoItem, album: String? = null): Track? {
        val id = videoId(item.url) ?: return null
        return Track(
            id = id,
            title = item.name,
            artist = cleanArtist(item.uploaderName),
            album = album,
            duration = item.duration.takeIf { it > 0 }?.toDouble(),
            artworkURL = best(item.thumbnails),
        )
    }

    private fun search(query: String, filter: String): List<InfoItem> {
        val handler = yt.searchQHFactory.fromQuery(query, listOf(filter), "")
        return SearchInfo.getInfo(yt, handler).relatedItems
    }

    /** Songs, artists and albums for a search, all at once. */
    suspend fun search(query: String): SearchResults = withContext(Dispatchers.IO) {
        coroutineScope {
            val songs = async { runCatching { search(query, "music_songs") }.getOrDefault(emptyList()) }
            val artists = async { runCatching { search(query, "music_artists") }.getOrDefault(emptyList()) }
            val albums = async { runCatching { search(query, "music_albums") }.getOrDefault(emptyList()) }
            val songList = songs.await()
            if (songList.isEmpty() && artists.await().isEmpty() && albums.await().isEmpty()) {
                // Nothing at all usually means no connection: say so instead of "no results".
                search(query, "music_songs")
            }
            SearchResults(
                songs = songList.filterIsInstance<StreamInfoItem>().mapNotNull { track(it) },
                artists = artists.await().filterIsInstance<ChannelInfoItem>()
                    .map { ArtistRef(it.url, it.name, best(it.thumbnails)) },
                albums = albums.await().filterIsInstance<PlaylistInfoItem>()
                    .map { AlbumRef(it.url, it.name, cleanArtist(it.uploaderName), best(it.thumbnails)) },
            )
        }
    }

    /** An artist: their songs and albums (found by name, kept to the ones that are theirs). */
    suspend fun artist(ref: ArtistRef): ArtistPage = withContext(Dispatchers.IO) {
        coroutineScope {
            val info = async { runCatching { ChannelInfo.getInfo(yt, ref.url) }.getOrNull() }
            val songs = async { runCatching { search(ref.name, "music_songs") }.getOrDefault(emptyList()) }
            val albums = async { runCatching { search(ref.name, "music_albums") }.getOrDefault(emptyList()) }
            val name = info.await()?.name?.takeIf { it.isNotBlank() } ?: ref.name
            val theirs = { artist: String -> artist.contains(name, ignoreCase = true) }
            ArtistPage(
                artist = ArtistRef(ref.url, name, info.await()?.avatars?.let { best(it) } ?: ref.thumbnail),
                songs = songs.await().filterIsInstance<StreamInfoItem>().mapNotNull { track(it) }
                    .filter { theirs(it.artist) }.take(20),
                albums = albums.await().filterIsInstance<PlaylistInfoItem>()
                    .map { AlbumRef(it.url, it.name, cleanArtist(it.uploaderName), best(it.thumbnails)) }
                    .filter { theirs(it.artist) },
            )
        }
    }

    /** An album's songs, in order. */
    suspend fun album(ref: AlbumRef): AlbumPage = withContext(Dispatchers.IO) {
        val info = PlaylistInfo.getInfo(yt, ref.url)
        val cover = best(info.thumbnails) ?: ref.thumbnail
        val artist = cleanArtist(info.uploaderName).ifEmpty { ref.artist }
        val tracks = info.relatedItems.filterIsInstance<StreamInfoItem>().mapNotNull { item ->
            // Album songs show the album's cover (their own pictures are often video stills).
            track(item, album = info.name)?.let { t -> t.copy(artworkURL = cover ?: t.artworkURL, artist = t.artist.ifEmpty { artist }) }
        }
        AlbumPage(AlbumRef(ref.url, info.name, artist, cover), tracks)
    }

    // Audio

    /** A song's audio: where it is, and when the link stops working. */
    data class Audio(val url: String, val expires: Long, val label: String)

    private val audioCache = ConcurrentHashMap<String, Audio>()

    fun forget(id: String) {
        audioCache.remove(id)
    }

    /** The best audio-only stream for a song (blocking: called from the player's loading thread). */
    fun audio(id: String): Audio {
        audioCache[id]?.let { if (it.expires > System.currentTimeMillis()) return it }
        val info = StreamInfo.getInfo(yt, "https://www.youtube.com/watch?v=$id")
        val streams = info.audioStreams.filter { it.isUrl && it.deliveryMethod == DeliveryMethod.PROGRESSIVE_HTTP }
        // AAC (M4A) plays everywhere; Opus (WebM) is a little better, and fine on Android 5 and later.
        val pick: AudioStream = streams.maxWithOrNull(compareBy<AudioStream>({ if (it.format == MediaFormat.M4A) 1 else 0 }, { it.averageBitrate }))
            ?: streams.maxByOrNull { it.averageBitrate }
            ?: throw IllegalStateException("No audio for this song")
        val kind = if (pick.format == MediaFormat.M4A) "AAC" else "Opus"
        val kbps = if (pick.averageBitrate > 0) " · ${pick.averageBitrate / 1000} kbps" else ""
        // YouTube links last about 6 hours: use them for 5.
        val a = Audio(pick.content, System.currentTimeMillis() + 5 * 3600_000L, kind + kbps)
        audioCache[id] = a
        return a
    }
}
