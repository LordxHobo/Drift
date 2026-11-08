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

    /** Songs only (blocking; for Spotify import). */
    fun searchSongsBlocking(query: String): List<Track> = tube.songs(query)

    /** Videos and uploads (blocking; for Spotify import). */
    fun searchVideosBlocking(query: String): List<Track> = tube.videos(query)

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

    // Video (episodes)

    /** An episode's picture (no sound): the version picked, and every height it comes in. */
    data class Video(val url: String, val height: Int, val heights: List<Int>)

    private val videoCache = ConcurrentHashMap<String, Pair<List<InnerTube.VideoFormat>, Long>>()

    /**
     * The sharpest picture up to `maxHeight` (blocking), H.264 first, then VP9, then AV1 (only on phones
     * that can play it). Null when YouTube gave none. The quick path first; when it has no picture, the
     * full extraction (NewPipeExtractor), as the computer does.
     */
    fun video(id: String, maxHeight: Int): Video? {
        val list = videoCache[id]?.takeIf { it.second > System.currentTimeMillis() }?.first ?: run {
            val quick = runCatching { tube.quickAudio(id, visitorData) }.getOrNull()
            quick?.visitorData?.let { visitorData = it }
            val found = quick?.videos.orEmpty().filter { playable(it.codec) }.ifEmpty { fullVideo(id) }
            if (found.isNotEmpty()) videoCache[id] = found to System.currentTimeMillis() + 3 * 3600_000L
            found
        }
        val lowest = list.minByOrNull { it.height } ?: return null
        val pool = list.filter { it.height <= maxHeight }.ifEmpty { listOf(lowest) }
        val pick = pool.maxWithOrNull(compareBy<InnerTube.VideoFormat>({ it.height }, { -it.codec }, { it.rate })) ?: lowest
        return Video(pick.url, pick.height, list.map { it.height }.distinct().sorted())
    }

    /** Picture-only versions from the full extraction. */
    private fun fullVideo(id: String): List<InnerTube.VideoFormat> = runCatching {
        val info = StreamInfo.getInfo(yt, "https://www.youtube.com/watch?v=$id")
        info.videoOnlyStreams
            .filter { it.isUrl && it.deliveryMethod == DeliveryMethod.PROGRESSIVE_HTTP && it.height > 0 }
            .map { InnerTube.VideoFormat(it.height, it.content, it.bitrate, InnerTube.codecRank(it.codec ?: it.format?.mimeType.orEmpty())) }
            .filter { playable(it.codec) }
    }.getOrDefault(emptyList())

    /** H.264 and VP9 play on every phone; AV1 only on ones with a decoder for it. */
    private fun playable(codec: Int): Boolean = when (codec) {
        0, 1 -> true
        2 -> av1
        else -> false
    }

    private val av1: Boolean by lazy {
        runCatching {
            android.media.MediaCodecList(android.media.MediaCodecList.REGULAR_CODECS).codecInfos
                .any { !it.isEncoder && it.supportedTypes.any { t -> t.equals("video/av01", ignoreCase = true) } }
        }.getOrDefault(false)
    }

    private val JSON = "application/json".toMediaType()

    /** For API calls only: each one gives up after 20 s (audio downloads use the main client, without a limit). */
    private val apiClient by lazy { HttpDownloader.shared.client.newBuilder().callTimeout(20, TimeUnit.SECONDS).build() }
}
