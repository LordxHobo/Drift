package com.lordxhobo.drift.spotify

import com.lordxhobo.drift.data.Track
import com.lordxhobo.drift.lyrics.LyricsService
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import java.text.Normalizer
import android.util.Base64
import java.time.Instant

/** A song as Spotify lists it. */
data class SpotifySong(
    val title: String,
    val artist: String,
    /** Seconds. */
    val duration: Double? = null,
    /** When it was added on Spotify (seconds since 2001-01-01, like the iPhone). */
    val added: Double? = null,
)

data class SpotifyList(val name: String, val songs: List<SpotifySong>, val total: Int? = null, val limited: Boolean = false)

class ImportException(message: String) : Exception(message)

/** One page of a playlist from Spotify's own page: songs from `offset` on (null = not a song). */
data class SpotifyPage(val name: String?, val total: Int?, val items: List<SpotifySong?>)

/** Reading Spotify links, its embed page and its playlist answers. The same rules as the computer. */
object Spotify {
    const val CHROME_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
    /** The embed page lists only the first 100 songs. */
    const val EMBED_LIMIT = 100
    private const val APPLE_EPOCH = 978_307_200.0

    /** ("playlist" | "album", id) from a link, or shared text with a link in it. */
    fun parseLink(text: String): Pair<String, String>? {
        val m = Regex("(playlist|album)[/:]([A-Za-z0-9]{10,})").find(text) ?: return null
        return m.groupValues[1] to m.groupValues[2]
    }

    /** The first link in shared text. */
    fun firstLink(text: String): String = Regex("https?://\\S+").find(text.trim())?.value ?: text.trim()

    fun isShortLink(url: String) = url.contains("spotify.link") || url.contains("spoti.fi")

    // MARK: Embed page (public playlists and albums, first 100 songs)

    fun parseEmbed(html: String): SpotifyList? {
        val e = findEntity(html) ?: return null
        val name = str(e["name"]) ?: str(e["title"]) ?: "Spotify import"
        val songs = (e["trackList"] as? JsonArray).orEmpty().mapNotNull { item ->
            val t = item as? JsonObject ?: return@mapNotNull null
            val title = str(t["title"]) ?: return@mapNotNull null
            var artist = str(t["subtitle"]) ?: ""
            if (artist.isEmpty()) {
                artist = (t["artists"] as? JsonArray).orEmpty().mapNotNull { str((it as? JsonObject)?.get("name")) }.joinToString(", ")
            }
            val ms = (t["duration"] as? JsonPrimitive)?.doubleOrNull
            SpotifySong(title, artist.replace(' ', ' '), ms?.let { it / 1000 })
        }
        return if (songs.isEmpty()) null else SpotifyList(name, songs, limited = songs.size >= EMBED_LIMIT - 5)
    }

    /** The page keeps its data as JSON in a <script>; Spotify has used three formats for it. */
    fun findEntity(html: String): JsonObject? {
        val re = Regex("<script([^>]*)>([\\s\\S]*?)</script>")
        fun json(s: String): JsonElement? = runCatching { Json.parseToJsonElement(s) }.getOrNull()
        fun b64(s: String): JsonElement? = runCatching { String(Base64.decode(s.trim(), Base64.DEFAULT)) }.getOrNull()?.let { json(it) }
        for (m in re.findAll(html)) {
            val attrs = m.groupValues[1]
            val body = m.groupValues[2].trim()
            val found = when {
                attrs.contains("__NEXT_DATA__") -> dig(json(body), "props", "pageProps", "state", "data", "entity")
                attrs.contains("initial-state") -> dig(b64(body), "data", "entity")
                attrs.contains("\"resource\"") || attrs.contains("id=resource") -> b64(body)
                else -> null
            }
            if (found is JsonObject) return found
        }
        return null
    }

    // MARK: Spotify's own playlist answers (the page's "pathfinder" requests)

    fun parsePage(json: JsonElement?): SpotifyPage? {
        val pl = (dig(json, "data", "playlistV2") ?: dig(json, "data", "playlist")) as? JsonObject ?: return null
        val content = pl["content"] as? JsonObject ?: return null
        val items = content["items"] as? JsonArray ?: return null
        return SpotifyPage(
            name = str(pl["name"]),
            total = (content["totalCount"] as? JsonPrimitive)?.doubleOrNull?.toInt(),
            items = items.map { it ->
                val d = (dig(it, "itemV2", "data") ?: dig(it, "item", "data")) as? JsonObject ?: return@map null
                val name = str(d["name"]) ?: return@map null
                val type = str(d["__typename"])
                if (type != null && type != "Track") return@map null
                val artist = (dig(d, "artists", "items") as? JsonArray).orEmpty()
                    .mapNotNull { str(dig(it, "profile", "name")) }.firstOrNull() ?: ""
                val ms = ((dig(d, "trackDuration", "totalMilliseconds") ?: dig(d, "duration", "totalMilliseconds")) as? JsonPrimitive)?.doubleOrNull ?: 0.0
                val added = str(dig(it, "addedAt", "isoString"))?.let { iso ->
                    runCatching { Instant.parse(iso).toEpochMilli() / 1000.0 - APPLE_EPOCH }.getOrNull()
                }
                SpotifySong(name, artist, if (ms > 0) ms / 1000 else null, added)
            },
        )
    }

    /** The request's name ("fetchPlaylist", "fetchPlaylistContents"…), from its body or address. */
    fun operation(url: String, body: String?): String {
        body?.let { b -> str(dig(runCatching { Json.parseToJsonElement(b) }.getOrNull(), "operationName"))?.let { return it } }
        return Regex("[?&]operationName=([^&]+)").find(url)?.groupValues?.get(1) ?: ""
    }

    /** Where a request starts in the playlist. */
    fun offsetOf(url: String, body: String?): Int {
        val vars = if (body != null) dig(runCatching { Json.parseToJsonElement(body) }.getOrNull(), "variables")
        else Regex("[?&]variables=([^&]+)").find(url)?.groupValues?.get(1)
            ?.let { runCatching { Json.parseToJsonElement(java.net.URLDecoder.decode(it, "UTF-8")) }.getOrNull() }
        return ((vars as? JsonObject)?.get("offset") as? JsonPrimitive)?.doubleOrNull?.toInt() ?: 0
    }

    // MARK: JSON helpers

    fun str(e: JsonElement?): String? = (e as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content

    fun dig(e: JsonElement?, vararg path: String): JsonElement? {
        var cur = e
        for (k in path) cur = (cur as? JsonObject)?.get(k) ?: return null
        return cur
    }
}

/**
 * Finding a Spotify song on YouTube: the YouTube Music song first, else a regular upload (preferably
 * from the artist's own channel). The same scoring as the iPhone's and the computer's.
 */
class SongMatcher(
    private val songs: (String) -> List<Track>,
    private val videos: (String) -> List<Track>,
) {
    fun match(s: SpotifySong): Track? = official(s) ?: upload(s)

    private fun <T> twice(block: () -> T): T? =
        runCatching(block).getOrNull() ?: run {
            // Big imports can hit YouTube's limit: wait and try once more.
            Thread.sleep(2000)
            runCatching(block).getOrNull()
        }

    private fun official(s: SpotifySong): Track? {
        val artist = LyricsService.mainArtist(s.artist)
        val results = twice { songs("${s.title} $artist") } ?: return null
        val wantTitle = normalize(s.title)
        val wantArtist = normalize(artist)
        var best: Pair<Track, Double>? = null
        results.take(6).forEachIndexed { i, t ->
            var score = -0.2 * i
            val title = normalize(t.title)
            if (wantTitle.isNotEmpty() && title == wantTitle) score += 3
            else if (wantTitle.isNotEmpty() && (title.contains(wantTitle) || wantTitle.contains(title))) score += 2
            if (wantArtist.isNotEmpty() && normalize(t.artist).contains(wantArtist)) score += 2
            if (s.duration != null && t.duration != null) {
                val diff = kotlin.math.abs(s.duration - t.duration)
                if (diff <= 3) score += 2 else if (diff <= 10) score += 1 else if (diff > 30) score -= 3
            }
            if (best == null || score > best!!.second) best = t to score
        }
        return best?.takeIf { it.second >= 1 }?.first
    }

    private fun upload(s: SpotifySong): Track? {
        val artist = LyricsService.mainArtist(s.artist)
        val results = twice { videos("$artist ${s.title}") } ?: return null
        val wantTitle = normalize(s.title)
        val wantArtist = normalize(artist)
        if (wantTitle.isEmpty()) return null
        val songWords = loose(s.title)
        var best: Pair<Track, Double>? = null
        results.take(8).forEachIndexed { i, v ->
            val title = loose(v.title)
            if (!title.contains(wantTitle)) return@forEachIndexed
            var score = 3 - 0.2 * i
            // The artist's own channel, its "- Topic" channel or VEVO.
            val channel = loose(v.artist).replace("topic", "").replace("vevo", "").replace("official", "")
            score += when {
                wantArtist.isNotEmpty() && channel.isNotEmpty() && (channel.contains(wantArtist) || wantArtist.contains(channel)) -> 3.0
                wantArtist.isNotEmpty() && title.contains(wantArtist) -> 1.0
                else -> -1.0
            }
            if (s.duration != null && v.duration != null) {
                val diff = kotlin.math.abs(s.duration - v.duration)
                if (diff > 60) return@forEachIndexed
                if (diff <= 3) score += 3 else if (diff <= 10) score += 1 else if (diff > 30) score -= 3
            }
            for (w in OTHER_VERSIONS) if (title.contains(w) && !songWords.contains(w)) score -= 3
            if (best == null || score > best!!.second) best = v to score
        }
        val v = best?.takeIf { it.second >= 4 }?.first ?: return null
        return Track(
            id = v.id, title = s.title, artist = s.artist, duration = v.duration,
            artworkURL = "https://i.ytimg.com/vi/${v.id}/hqdefault.jpg", upload = true,
        )
    }

    companion object {
        /** Words that mean a different version, unless the song title itself has them. */
        private val OTHER_VERSIONS = listOf("live", "cover", "remix", "reaction", "karaoke", "instrumental", "slowed", "spedup", "nightcore", "8d", "1hour", "tutorial", "lesson")

        private fun plain(s: String): String =
            Normalizer.normalize(s, Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "").lowercase().replace(Regex("[^\\p{L}\\p{N}]"), "")

        /** For comparing titles: without anything in brackets or after " - ". */
        fun normalize(s: String): String = plain(s.replace(Regex("\\s*[(\\[][^)\\]]*[)\\]]"), "").replace(Regex("\\s+-\\s+.*$"), ""))

        /** Letters and digits only, keeping words in brackets (for whole video titles). */
        fun loose(s: String): String = plain(s)

        /** Same song for matching against your library: title and main artist. */
        fun key(title: String, artist: String) = normalize(title) + "|" + normalize(LyricsService.mainArtist(artist))
    }
}
