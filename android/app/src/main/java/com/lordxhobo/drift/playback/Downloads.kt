package com.lordxhobo.drift.playback

import android.content.Context
import android.content.SharedPreferences
import android.net.ConnectivityManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSpec
import com.lordxhobo.drift.data.Library
import com.lordxhobo.drift.data.Track
import com.lordxhobo.drift.youtube.HttpDownloader
import com.lordxhobo.drift.youtube.YouTube
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import java.io.File
import java.io.FileOutputStream

/**
 * Songs saved on the phone for listening offline. Whole playlists (or Liked songs) can be kept
 * downloaded: songs added to them later download too, and songs taken out are removed. Single songs can
 * be downloaded on their own from the song menu. Files live in the app's own storage.
 */
@androidx.annotation.OptIn(UnstableApi::class)
object Downloads {
    @Serializable
    data class Entry(val track: Track, val size: Long, val manual: Boolean = false)

    @Serializable
    private data class Stored(val songs: Map<String, Entry> = emptyMap(), val kept: List<String> = emptyList(), val manual: List<String> = emptyList())

    /** Downloaded songs by video ID. */
    var songs by mutableStateOf(mapOf<String, Entry>())
        private set
    /** Playlist IDs kept downloaded ("liked" = Liked songs). */
    var kept by mutableStateOf(setOf<String>())
        private set
    /** Songs downloaded on their own (also the ones still waiting). */
    private var manual = setOf<String>()

    /** The song downloading now, and how far along (0–1). */
    var current by mutableStateOf<Track?>(null)
        private set
    var progress by mutableStateOf(0f)
        private set
    /** Why downloads are waiting, if they are (e.g. no Wi-Fi). */
    var waiting by mutableStateOf<String?>(null)
        private set

    var overMobileData by mutableStateOf(false)
        private set

    const val LIKED = "liked"

    private lateinit var appContext: Context
    private lateinit var dir: File
    private lateinit var prefs: SharedPreferences
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var worker: Job? = null
    /** Songs that failed this session (tried again next launch). */
    private val failed = mutableSetOf<String>()

    fun init(context: Context) {
        appContext = context.applicationContext
        dir = File(context.filesDir, "downloads").apply { mkdirs() }
        prefs = context.getSharedPreferences("drift.settings", Context.MODE_PRIVATE)
        overMobileData = prefs.getBoolean("downloadOverMobile", false)
        val s = runCatching { Library.json.decodeFromString(Stored.serializer(), File(dir, "downloads.json").readText()) }.getOrNull()
        if (s != null) {
            // Only songs whose file is really there.
            songs = s.songs.filter { (id, _) -> fileFor(id).exists() }
            kept = s.kept.toSet()
            manual = s.manual.toSet()
        }
        Library.onAnyChange.add { update() }
        update()
    }

    private fun save() {
        val text = Library.json.encodeToString(Stored.serializer(), Stored(songs, kept.toList(), manual.toList()))
        runCatching {
            val tmp = File(dir, "downloads.json.tmp")
            tmp.writeText(text)
            tmp.renameTo(File(dir, "downloads.json"))
        }
    }

    private fun fileFor(id: String) = File(dir, "$id.audio")

    /** The downloaded file for a song, or null. Safe from any thread. */
    fun file(id: String): File? = fileFor(id).takeIf { songs.containsKey(id) && it.exists() }

    fun isDownloaded(id: String): Boolean = songs.containsKey(id)
    fun isManual(id: String): Boolean = id in manual
    fun isKept(listId: String): Boolean = listId in kept

    val totalBytes: Long get() = songs.values.sumOf { it.size }

    // MARK: Choices

    fun keep(listId: String, on: Boolean) {
        kept = if (on) kept + listId else kept - listId
        save()
        update()
    }

    fun download(t: Track) {
        manual = manual + t.id
        save()
        update()
    }

    fun remove(id: String) {
        manual = manual - id
        save()
        update()
    }

    fun removeAll() {
        kept = emptySet()
        manual = emptySet()
        worker?.cancel()
        worker = null
        current = null
        for (id in songs.keys) fileFor(id).delete()
        songs = emptyMap()
        save()
    }

    fun allowMobileData(on: Boolean) {
        overMobileData = on
        prefs.edit().putBoolean("downloadOverMobile", on).apply()
        update()
    }

    // MARK: What should be on the phone

    /** Every song that should be downloaded, in order: single songs first, then kept lists. */
    private fun wanted(): List<Track> {
        val out = LinkedHashMap<String, Track>()
        // Single songs keep their track details from the library when they're in it.
        val known = (Library.liked + Library.playlists.flatMap { it.tracks }).associateBy { it.id }
        for (id in manual) (known[id] ?: songs[id]?.track ?: pendingManual[id] ?: com.lordxhobo.drift.podcasts.PodcastStore.find(id))?.let { out[id] = it }
        // Episodes download only when asked for (not with a kept playlist), like on the other devices.
        if (LIKED in kept) for (t in Library.liked) if (!t.isEpisode) out.putIfAbsent(t.id, t)
        for (p in Library.playlists) if (p.id in kept) for (t in p.tracks) if (!t.isEpisode) out.putIfAbsent(t.id, t)
        return out.values.toList()
    }

    /** Songs downloaded from search or an album, before they're anywhere in the library. */
    private val pendingManual = mutableMapOf<String, Track>()

    /** Starts a single song's download (from the song menu), wherever it was found. */
    fun downloadSong(t: Track) {
        pendingManual[t.id] = t
        download(t)
    }

    /** Removes what's no longer wanted and starts downloading what's missing. */
    fun update() {
        val want = wanted().map { it.id }.toSet()
        val extra = songs.keys - want
        if (extra.isNotEmpty()) {
            for (id in extra) fileFor(id).delete()
            songs = songs - extra
            save()
        }
        if (worker?.isActive != true && wanted().any { it.id !in songs && it.id !in failed }) {
            worker = scope.launch { work() }
        }
    }

    private fun allowedNow(): Boolean {
        if (overMobileData) return true
        val cm = appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        return !cm.isActiveNetworkMetered
    }

    private suspend fun work() {
        while (scope.isActive) {
            val next = wanted().firstOrNull { it.id !in songs && it.id !in failed } ?: break
            if (!allowedNow()) {
                // Wait for Wi-Fi (checked every 30 s while Drift runs).
                waiting = "Waiting for Wi-Fi"
                delay(30_000)
                continue
            }
            waiting = null
            current = next
            progress = 0f
            val size = withContext(Dispatchers.IO) {
                runCatching { fetch(next) }.recoverCatching {
                    // Often an expired link: one more try with a fresh one.
                    YouTube.forget(next.id)
                    fetch(next)
                }.getOrNull()
            }
            current = null
            // Still wanted? (It may have been removed while downloading.)
            if (size == null) {
                failed.add(next.id)
            } else if (wanted().any { it.id == next.id }) {
                songs = songs + (next.id to Entry(next, size, next.id in manual))
                save()
            } else {
                fileFor(next.id).delete()
            }
        }
        waiting = null
    }

    /** Downloads one song to its file. Returns its size. Blocking. */
    private suspend fun fetch(t: Track): Long {
        // An episode from a show's feed: its own file; anything else: YouTube's audio.
        val url = t.audioURL ?: YouTube.audio(t.id).url
        val total = Regex("[?&]clen=(\\d+)").find(url)?.groupValues?.get(1)?.toLongOrNull()
        val tmp = File(dir, "${t.id}.part")
        val source = YouTubeDataSource(HttpDownloader.shared.client)
        val buffer = ByteArray(64 * 1024)
        var written = 0L
        FileOutputStream(tmp).use { out ->
            if (total == null) {
                // Size unknown: one request for everything.
                source.open(DataSpec.Builder().setUri(url).build())
                try {
                    while (true) {
                        val n = source.read(buffer, 0, buffer.size)
                        if (n == C.RESULT_END_OF_INPUT) break
                        out.write(buffer, 0, n)
                        written += n
                    }
                } finally {
                    source.close()
                }
            } else {
                // In pieces, as YouTube's own players fetch (one long request gets slowed down).
                while (written < total) {
                    val length = minOf(CHUNK, total - written)
                    source.open(DataSpec.Builder().setUri(url).setPosition(written).setLength(length).build())
                    try {
                        while (true) {
                            val n = source.read(buffer, 0, buffer.size)
                            if (n == C.RESULT_END_OF_INPUT) break
                            out.write(buffer, 0, n)
                            written += n
                        }
                    } finally {
                        source.close()
                    }
                    val p = written.toFloat() / total
                    withContext(Dispatchers.Main) { progress = p }
                }
            }
        }
        if (written == 0L || (total != null && written != total)) {
            tmp.delete()
            throw IllegalStateException("Incomplete download")
        }
        if (!tmp.renameTo(fileFor(t.id))) throw IllegalStateException("Couldn't save the download")
        return written
    }

    private const val CHUNK = 2L * 1024 * 1024
}
