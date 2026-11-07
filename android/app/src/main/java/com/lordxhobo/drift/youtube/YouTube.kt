package com.lordxhobo.drift.youtube

import com.lordxhobo.drift.data.AlbumRef
import com.lordxhobo.drift.data.ArtistRef
import com.lordxhobo.drift.data.Track
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request.Builder
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import org.schabi.newpipe.extractor.MediaFormat
import org.schabi.newpipe.extractor.ServiceList
import org.schabi.newpipe.extractor.stream.AudioStream
import org.schabi.newpipe.extractor.stream.DeliveryMethod
import org.schabi.newpipe.extractor.stream.StreamInfo
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * Search, artists, albums and audio streams from YouTube Music. Search and pages use YouTube Music's own
 * web API (the same calls as the iPhone and desktop apps); audio comes from YouTube's visionOS client,
 * with NewPipeExtractor as the fallback.
 */
object YouTube {
    private val yt get() = ServiceList.YouTube

    private val tube = InnerTube { url, headers, body ->
        val request = Builder().url(url).post(body.toRequestBody(JSON))
        for ((k, v) in headers) request.header(k, v)
        apiClient.newCall(request.build()).execute().use { r ->
            if (!r.isSuccessful) throw IOException("YouTube Music answered ${r.code}")
            r.body?.string() ?: throw IOException("YouTube Music sent nothing back")
        }
    }

    data class SearchResults(
        val songs: List<Track>,
        val artists: List<ArtistRef>,
        val albums: List<AlbumRef>,
    )

    data class ArtistPage(val artist: ArtistRef, val songs: List<Track>, val albums: List<AlbumRef>)
    data class AlbumPage(val album: AlbumRef, val tracks: List<Track>)

    /** Songs, artists and albums for a search, all at once (gives up after 25 s with a reason). */
    suspend fun search(query: String): SearchResults = limited {
        coroutineScope {
            val songs = async { runCatching { tube.songs(query) } }
            val artists = async { runCatching { tube.artists(query) } }
            val albums = async { runCatching { tube.albums(query) } }
            val s = songs.await()
            val ar = artists.await()
            val al = albums.await()
            if (s.getOrNull().isNullOrEmpty() && ar.getOrNull().isNullOrEmpty() && al.getOrNull().isNullOrEmpty()) {
                // Nothing at all: pass on the real reason instead of "no results".
                (s.exceptionOrNull() ?: ar.exceptionOrNull() ?: al.exceptionOrNull())?.let { throw it }
            }
            SearchResults(s.getOrDefault(emptyList()), ar.getOrDefault(emptyList()), al.getOrDefault(emptyList()))
        }
    }

    /** An artist: their top songs, albums and singles. */
    suspend fun artist(ref: ArtistRef): ArtistPage = limited {
        // Saved before artists were stored by ID: find them by name.
        val id = if (ref.url.startsWith("UC")) ref.url
        else tube.artists(ref.name).firstOrNull()?.url ?: throw IOException("Couldn't find ${ref.name}")
        val a = tube.artist(id, ref.name)
        ArtistPage(a.ref.copy(thumbnail = a.ref.thumbnail ?: ref.thumbnail), a.songs.take(20), a.albums)
    }

    /** An album's songs, in order. */
    suspend fun album(ref: AlbumRef): AlbumPage = limited {
        val a = tube.album(ref.url, ref)
        AlbumPage(a.ref, a.tracks)
    }

    /** Runs off the main thread and gives up after 25 s with a reason (instead of loading forever). */
    private suspend fun <T> limited(block: suspend CoroutineScope.() -> T): T = withContext(Dispatchers.IO) {
        withTimeoutOrNull(25_000) { block() } ?: throw IOException("YouTube Music didn't answer in time")
    }

    // Audio

    /** A song's audio: where it is, and when the link stops working. */
    data class Audio(val url: String, val expires: Long, val label: String)

    private val audioCache = ConcurrentHashMap<String, Audio>()

    fun forget(id: String) {
        audioCache.remove(id)
    }

    /** YouTube's visitor ID from the last answer, sent along so links keep working. */
    @Volatile private var visitorData: String? = null

    /** The best audio-only stream for a song (blocking: called from the player's loading thread). */
    fun audio(id: String): Audio {
        audioCache[id]?.let { if (it.expires > System.currentTimeMillis()) return it }
        // Quick path: one request to YouTube's visionOS client, as the iPhone does.
        runCatching { tube.quickAudio(id, visitorData) }.getOrNull()?.let { q ->
            visitorData = q.visitorData
            val label = "AAC" + if (q.kbps > 0) " · ${q.kbps} kbps" else ""
            val a = Audio(q.url, System.currentTimeMillis() + 5 * 3600_000L, label)
            audioCache[id] = a
            return a
        }
        // Fallback: NewPipeExtractor's full extraction.
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

    private val JSON = "application/json".toMediaType()

    /** For API calls only: each one gives up after 20 s (audio downloads use the main client, without a limit). */
    private val apiClient by lazy { HttpDownloader.shared.client.newBuilder().callTimeout(20, TimeUnit.SECONDS).build() }
}
