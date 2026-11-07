package com.lordxhobo.drift.spotify

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.lordxhobo.drift.data.Library
import com.lordxhobo.drift.data.Track
import com.lordxhobo.drift.youtube.HttpDownloader
import com.lordxhobo.drift.youtube.YouTube
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import okhttp3.Request

/** Importing a public Spotify playlist or album into a new Drift playlist (one import at a time). */
object SpotifyImport {
    enum class Phase { IDLE, READING, MATCHING, DONE, FAILED }

    var phase by mutableStateOf(Phase.IDLE)
        private set
    var listName by mutableStateOf<String?>(null)
        private set
    var total by mutableStateOf(0)
        private set
    var processed by mutableStateOf(0)
        private set
    /** Songs read from Spotify so far (while reading a long playlist). */
    var read by mutableStateOf(0)
        private set
    var missing by mutableStateOf(listOf<SpotifySong>())
        private set
    var error by mutableStateOf<String?>(null)
        private set
    /** Only the first 100 songs could be read. */
    var limited by mutableStateOf(false)
        private set
    /** Spotify said there are more songs than could be read. */
    var spotifyTotal by mutableStateOf<Int?>(null)
        private set
    var playlistId by mutableStateOf<String?>(null)
        private set
    var retrying by mutableStateOf(false)
        private set
    var foundAgain by mutableStateOf<Int?>(null)
        private set

    val busy: Boolean get() = phase == Phase.READING || phase == Phase.MATCHING

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val matcher = SongMatcher(
        songs = { YouTube.searchSongsBlocking(it) },
        videos = { YouTube.searchVideosBlocking(it) },
    )

    fun clear() {
        if (busy) return
        phase = Phase.IDLE
        listName = null
        total = 0
        processed = 0
        read = 0
        missing = emptyList()
        error = null
        limited = false
        spotifyTotal = null
        playlistId = null
        foundAgain = null
    }

    fun start(context: Context, link: String) {
        if (busy) return
        clear()
        phase = Phase.READING
        scope.launch {
            try {
                run(context.applicationContext, link)
            } catch (e: ImportException) {
                error = e.message
                phase = Phase.FAILED
            } catch (e: Exception) {
                error = "Couldn't import: " + (e.message ?: "something went wrong.")
                phase = Phase.FAILED
            }
        }
    }

    // MARK: Reading

    private fun get(url: String): Triple<Int, String, String> {
        val r = Request.Builder().url(url).header("User-Agent", Spotify.CHROME_AGENT).header("Accept-Language", "en").build()
        HttpDownloader.shared.client.newCall(r).execute().use { res ->
            return Triple(res.code, res.body?.string() ?: "", res.request.url.toString())
        }
    }

    private suspend fun readList(context: Context, link: String): SpotifyList {
        var text = Spotify.firstLink(link)
        // Short links (spotify.link / spoti.fi) lead to open.spotify.com.
        if (Spotify.isShortLink(text)) {
            text = withContext(Dispatchers.IO) { runCatching { get(text).third }.getOrNull() } ?: text
        }
        val (kind, id) = Spotify.parseLink(text) ?: throw ImportException("That doesn't look like a Spotify playlist or album link.")

        // Playlists: the whole thing through Spotify's own page; the embed page stops at 100.
        if (kind == "playlist") {
            val full = runCatching { SpotifyPageReader(context).read(id) { n, _ -> read = n } }.getOrNull()
            if (full != null && full.songs.isNotEmpty()) return full
        }
        val (status, html) = withContext(Dispatchers.IO) {
            runCatching { get("https://open.spotify.com/embed/$kind/$id") }.getOrNull()?.let { it.first to it.second }
        } ?: throw ImportException("Couldn't reach Spotify. Check your connection.")
        if (status != 200) throw ImportException("Couldn't open that playlist. Make sure it's public, then try again.")
        return Spotify.parseEmbed(html) ?: throw ImportException("Couldn't open that playlist. Make sure it's public, then try again.")
    }

    // MARK: Matching

    /** Songs you already have, by title and main artist (no search needed). */
    private fun localIndex(): Map<String, List<Track>> {
        val index = mutableMapOf<String, MutableList<Track>>()
        val seen = mutableSetOf<String>()
        for (t in Library.liked + Library.playlists.flatMap { it.tracks }) {
            if (!seen.add(t.id)) continue
            index.getOrPut(SongMatcher.key(t.title, t.artist)) { mutableListOf() }.add(t)
        }
        return index
    }

    private fun lookup(s: SpotifySong, index: Map<String, List<Track>>): Track? =
        index[SongMatcher.key(s.title, s.artist)]?.firstOrNull { t ->
            s.duration == null || t.duration == null || kotlin.math.abs(s.duration - t.duration) <= 10
        }

    /** Six searches at a time, results in the original order. */
    private suspend fun matchAll(list: List<SpotifySong>, onEach: () -> Unit): List<Track?> = coroutineScope {
        val gate = Semaphore(6)
        list.map { s ->
            async(Dispatchers.IO) {
                gate.withPermit {
                    val t = runCatching { matcher.match(s) }.getOrNull()
                    withContext(Dispatchers.Main) { onEach() }
                    t
                }
            }
        }.awaitAll()
    }

    private suspend fun run(context: Context, link: String) {
        val list = readList(context, link)
        val local = localIndex()
        val p = Library.createPlaylist(list.name)
        playlistId = p.id
        listName = list.name
        total = list.songs.size
        limited = list.limited
        spotifyTotal = list.total
        phase = Phase.MATCHING

        // In batches of 30, so a big import keeps what it found if Drift is closed.
        val notFound = mutableListOf<SpotifySong>()
        for (start in list.songs.indices step 30) {
            val slice = list.songs.subList(start, minOf(start + 30, list.songs.size))
            val matched = arrayOfNulls<Track>(slice.size)
            val toSearch = mutableListOf<Int>()
            slice.forEachIndexed { i, s ->
                val mine = lookup(s, local)
                if (mine != null) {
                    matched[i] = mine
                    processed++
                } else {
                    toSearch.add(i)
                }
            }
            val searched = matchAll(toSearch.map { slice[it] }) { processed++ }
            toSearch.forEachIndexed { k, i -> matched[i] = searched[k] }
            val found = mutableListOf<Track>()
            matched.forEachIndexed { i, t ->
                if (t != null) found.add(t.copy(added = slice[i].added ?: t.added)) else notFound.add(slice[i])
            }
            if (Library.playlist(p.id) != null) Library.addAll(found, p.id)
        }
        missing = notFound
        processed = list.songs.size
        phase = Phase.DONE
    }

    /** Looks for the songs that weren't found once more, and adds what turns up. */
    fun retryMissing() {
        val id = playlistId ?: return
        if (phase != Phase.DONE || missing.isEmpty() || retrying) return
        retrying = true
        scope.launch {
            val songs = missing
            val results = matchAll(songs) {}
            val found = results.filterNotNull()
            if (found.isNotEmpty() && Library.playlist(id) != null) Library.addAll(found, id)
            missing = songs.filterIndexed { i, _ -> results[i] == null }
            foundAgain = found.size
            retrying = false
        }
    }
}
