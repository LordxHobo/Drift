package com.lordxhobo.drift.youtube

import com.lordxhobo.drift.data.AlbumRef
import com.lordxhobo.drift.data.ArtistRef
import com.lordxhobo.drift.data.Track
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import java.util.Calendar
import java.util.TimeZone

/**
 * YouTube Music's own web API (the one music.youtube.com uses): the same calls the iPhone and desktop
 * apps make, so search and pages work the same everywhere. `send` does the HTTP POST and returns the body.
 */
class InnerTube(private val send: (url: String, headers: Map<String, String>, body: String) -> String) {

    // MARK: Requests

    /** Same scheme music.youtube.com uses: "1.<today's date>.01.00". */
    private fun clientVersion(): String {
        val c = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
        return "1.%04d%02d%02d.01.00".format(c.get(Calendar.YEAR), c.get(Calendar.MONTH) + 1, c.get(Calendar.DAY_OF_MONTH))
    }

    private fun music(endpoint: String, fields: Map<String, String>): JsonElement {
        val body = buildJsonObject {
            for ((k, v) in fields) put(k, v)
            putJsonObject("context") {
                putJsonObject("client") {
                    put("clientName", "WEB_REMIX")
                    put("clientVersion", clientVersion())
                    put("hl", "en")
                }
            }
        }
        val text = send(
            "https://music.youtube.com/youtubei/v1/$endpoint?prettyPrint=false",
            mapOf(
                "Content-Type" to "application/json",
                "Origin" to "https://music.youtube.com",
                "Referer" to "https://music.youtube.com/",
                "User-Agent" to WEB_AGENT,
            ),
            body.toString(),
        )
        return Json.parseToJsonElement(text)
    }

    // MARK: Search

    fun songs(query: String): List<Track> {
        val json = music("search", mapOf("query" to query, "params" to SONGS))
        val out = mutableListOf<Track>()
        collect(json) { r -> parseTrack(r, requireDuration = true)?.let { t -> if (out.none { it.id == t.id }) out.add(t) } }
        return out
    }

    /** Music videos and uploads (for songs that aren't on YouTube Music as songs). Channel in `artist`. */
    fun videos(query: String): List<Track> {
        val json = music("search", mapOf("query" to query, "params" to VIDEOS))
        val out = mutableListOf<Track>()
        collect(json) { r -> parseTrack(r, requireDuration = false)?.let { t -> if (out.none { it.id == t.id }) out.add(t.copy(album = null)) } }
        return out
    }

    fun artists(query: String): List<ArtistRef> {
        val json = music("search", mapOf("query" to query, "params" to ARTISTS))
        val out = mutableListOf<ArtistRef>()
        collect(json) { r ->
            val id = str(dig(r, "navigationEndpoint", "browseEndpoint", "browseId")) ?: return@collect
            if (!id.startsWith("UC")) return@collect
            val cols = r["flexColumns"] as? JsonArray ?: return@collect
            val name = columnText(cols.getOrNull(0), FLEX)
            if (name.isEmpty() || out.any { it.url == id }) return@collect
            out.add(ArtistRef(id, name, thumbnail(r)))
        }
        return out
    }

    fun albums(query: String): List<AlbumRef> {
        val json = music("search", mapOf("query" to query, "params" to ALBUMS))
        val out = mutableListOf<AlbumRef>()
        collect(json) { r ->
            val id = str(dig(r, "navigationEndpoint", "browseEndpoint", "browseId")) ?: return@collect
            if (!id.startsWith("MPRE")) return@collect
            val cols = r["flexColumns"] as? JsonArray ?: return@collect
            val title = columnText(cols.getOrNull(0), FLEX)
            if (title.isEmpty() || out.any { it.url == id }) return@collect
            // "Album • Artist • 2021": keep the artist.
            val meta = columnText(cols.getOrNull(1), FLEX).split("•").map { it.trim() }.filter { it.isNotEmpty() }
            val artist = if (meta.size > 1) meta[1] else meta.firstOrNull() ?: ""
            out.add(AlbumRef(id, title, artist, thumbnail(r)))
        }
        return out
    }

    // MARK: Artist and album pages

    data class Artist(val ref: ArtistRef, val songs: List<Track>, val albums: List<AlbumRef>)
    data class Album(val ref: AlbumRef, val tracks: List<Track>)

    fun artist(id: String, fallbackName: String): Artist {
        val json = music("browse", mapOf("browseId" to id))
        val header = dig(json, "header", "musicImmersiveHeaderRenderer") ?: dig(json, "header", "musicVisualHeaderRenderer")
        val name = text(obj(header)?.get("title")) ?: fallbackName
        val sections = (dig(json, "contents", "singleColumnBrowseResultsRenderer", "tabs", 0, "tabRenderer", "content", "sectionListRenderer", "contents")
            ?: dig(json, "contents", "twoColumnBrowseResultsRenderer", "tabs", 0, "tabRenderer", "content", "sectionListRenderer", "contents"))
            as? JsonArray ?: JsonArray(emptyList())
        val songs = mutableListOf<Track>()
        val albums = mutableListOf<AlbumRef>()
        val singles = mutableListOf<AlbumRef>()
        for (section in sections) {
            val shelf = obj(dig(section, "musicShelfRenderer"))
            if (shelf != null && songs.isEmpty()) {
                for (item in (shelf["contents"] as? JsonArray).orEmpty()) {
                    val r = obj(dig(item, "musicResponsiveListItemRenderer")) ?: continue
                    parseTrack(r, requireDuration = false)?.let { songs.add(if (it.artist.isEmpty()) it.copy(artist = name) else it) }
                }
            }
            val carousel = obj(dig(section, "musicCarouselShelfRenderer")) ?: continue
            val title = (text(dig(carousel, "header", "musicCarouselShelfBasicHeaderRenderer", "title")) ?: "").lowercase()
            val items = (carousel["contents"] as? JsonArray).orEmpty().mapNotNull { i ->
                obj(dig(i, "musicTwoRowItemRenderer"))?.let { albumRef(it, name) }
            }
            when {
                title.contains("single") || title.contains(" ep") -> singles.addAll(items)
                title.contains("album") -> albums.addAll(items)
            }
        }
        return Artist(ArtistRef(id, name, thumbnail(header)), songs, albums + singles)
    }

    fun album(id: String, fallback: AlbumRef?): Album {
        val json = music("browse", mapOf("browseId" to id))
        var header: JsonObject? = null
        walk(json, "musicResponsiveHeaderRenderer") { if (header == null) header = it }
        if (header == null) walk(json, "musicDetailHeaderRenderer") { if (header == null) header = it }
        val title = text(header?.get("title")) ?: fallback?.title ?: ""
        val artist = text(header?.get("straplineTextOne")) ?: fallback?.artist ?: ""
        val art = thumbnail(header) ?: fallback?.thumbnail
        val tracks = mutableListOf<Track>()
        collect(json) { r ->
            val t = parseTrack(r, requireDuration = false) ?: return@collect
            if (tracks.any { it.id == t.id }) return@collect
            // Album songs show the album's cover (their own pictures are often video stills).
            tracks.add(t.copy(artist = t.artist.ifEmpty { artist }, album = title, artworkURL = art ?: t.artworkURL))
        }
        return Album(AlbumRef(id, title, artist, art), tracks)
    }

    // MARK: Audio links

    /** A direct audio link from YouTube's visionOS client: one request, no signature decoding. */
    /** One picture-only version of a video (H.264), for episode video. */
    data class VideoFormat(val height: Int, val url: String, val rate: Int)

    data class Quick(val url: String, val kbps: Int, val visitorData: String?, val videos: List<VideoFormat> = emptyList())

    fun quickAudio(videoId: String, visitorData: String?): Quick {
        val body = buildJsonObject {
            putJsonObject("context") {
                putJsonObject("client") {
                    put("clientName", "VISIONOS")
                    put("clientVersion", "1.02")
                    put("deviceMake", "Apple")
                    put("deviceModel", "RealityDevice17,1")
                    put("osName", "visionOS")
                    put("osVersion", "26.5.23O471")
                    put("userAgent", VISION_AGENT)
                    put("hl", "en")
                    put("gl", "US")
                    if (visitorData != null) put("visitorData", visitorData)
                }
            }
            put("videoId", videoId)
            put("contentCheckOk", true)
            put("racyCheckOk", true)
        }
        val headers = mutableMapOf(
            "Content-Type" to "application/json",
            "User-Agent" to VISION_AGENT,
            "X-YouTube-Client-Name" to "101",
            "X-YouTube-Client-Version" to "1.02",
            "Origin" to "https://www.youtube.com",
        )
        if (visitorData != null) headers["X-Goog-Visitor-Id"] = visitorData
        val json = Json.parseToJsonElement(send("https://www.youtube.com/youtubei/v1/player?prettyPrint=false", headers, body.toString()))
        val status = str(dig(json, "playabilityStatus", "status"))
        if (status != "OK" || str(dig(json, "videoDetails", "videoId")) != videoId) {
            throw IllegalStateException(str(dig(json, "playabilityStatus", "reason")) ?: "YouTube didn't give this song's audio ($status)")
        }
        val formats = (dig(json, "streamingData", "adaptiveFormats") as? JsonArray).orEmpty().mapNotNull { obj(it) }
        // Direct-link AAC audio in the original language (no dubbed tracks).
        val audio = formats.filter { f ->
            (str(f["mimeType"]) ?: "").startsWith("audio/mp4") && str(f["url"]) != null &&
                str(dig(f, "audioTrack", "audioIsDefault")) != "false"
        }
        fun rate(f: JsonObject): Int = (str(f["averageBitrate"]) ?: str(f["bitrate"]))?.toIntOrNull() ?: 0
        val pick = audio.maxByOrNull { rate(it) } ?: throw IllegalStateException("No audio for this song")
        // Picture-only H.264 versions, for episode video.
        val videos = formats.mapNotNull { f ->
            val mime = str(f["mimeType"]) ?: return@mapNotNull null
            val url = str(f["url"]) ?: return@mapNotNull null
            val height = str(f["height"])?.toIntOrNull() ?: return@mapNotNull null
            if (!mime.startsWith("video/mp4") || !mime.contains("avc1") || height <= 0) return@mapNotNull null
            VideoFormat(height, url, rate(f))
        }
        return Quick(str(pick["url"])!!, rate(pick) / 1000, str(dig(json, "responseContext", "visitorData")) ?: visitorData, videos)
    }

    // MARK: JSON helpers

    private fun obj(e: JsonElement?): JsonObject? = e as? JsonObject

    private fun str(e: JsonElement?): String? = (e as? JsonPrimitive)?.let { if (it is kotlinx.serialization.json.JsonNull) null else it.content }

    private fun dig(e: JsonElement?, vararg path: Any): JsonElement? {
        var cur = e
        for (k in path) {
            cur = when (k) {
                is String -> (cur as? JsonObject)?.get(k)
                is Int -> (cur as? JsonArray)?.getOrNull(k)
                else -> null
            } ?: return null
        }
        return cur
    }

    private fun text(e: JsonElement?): String? {
        val o = e as? JsonObject ?: return null
        str(o["simpleText"])?.let { return it }
        val runs = o["runs"] as? JsonArray ?: return null
        return runs.joinToString("") { str(dig(it, "text")) ?: "" }.ifEmpty { null }
    }

    /** Every musicResponsiveListItemRenderer, in document order. */
    private fun collect(e: JsonElement, found: (JsonObject) -> Unit) {
        when (e) {
            is JsonArray -> e.forEach { collect(it, found) }
            is JsonObject -> {
                val r = e["musicResponsiveListItemRenderer"] as? JsonObject
                if (r != null) {
                    found(r)
                    return
                }
                for (k in e.keys.sorted()) collect(e.getValue(k), found)
            }
            else -> {}
        }
    }

    /** Every object under `key`, anywhere. */
    private fun walk(e: JsonElement, key: String, found: (JsonObject) -> Unit) {
        when (e) {
            is JsonArray -> e.forEach { walk(it, key, found) }
            is JsonObject -> for (k in e.keys.sorted()) {
                val v = e.getValue(k)
                if (k == key && v is JsonObject) found(v) else walk(v, key, found)
            }
            else -> {}
        }
    }

    private fun firstValue(e: JsonElement?, key: String): JsonElement? {
        when (e) {
            is JsonArray -> for (v in e) firstValue(v, key)?.let { return it }
            is JsonObject -> {
                e[key]?.let { return it }
                for (k in e.keys.sorted()) firstValue(e.getValue(k), key)?.let { return it }
            }
            else -> {}
        }
        return null
    }

    private fun columnText(column: JsonElement?, renderer: String): String =
        (dig(column, renderer, "text", "runs") as? JsonArray).orEmpty().joinToString("") { str(dig(it, "text")) ?: "" }

    private fun thumbnail(node: JsonElement?): String? {
        val paths = listOf(
            listOf("thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails"),
            listOf("thumbnail", "croppedSquareThumbnailRenderer", "thumbnail", "thumbnails"),
            listOf("thumbnailRenderer", "musicThumbnailRenderer", "thumbnail", "thumbnails"),
        )
        for (p in paths) {
            val list = dig(node, *p.toTypedArray()) as? JsonArray ?: continue
            val url = str(dig(list.lastOrNull(), "url")) ?: continue
            return if (url.startsWith("//")) "https:$url" else url
        }
        return null
    }

    private fun parseDuration(s: String): Double? {
        val parts = s.split(":")
        if (parts.size !in 2..3 || parts.any { p -> p.isEmpty() || !p.all { it.isDigit() } }) return null
        return parts.fold(0L) { total, p -> total * 60 + p.toLong() }.toDouble()
    }

    private fun isExplicit(e: JsonElement?): Boolean = when (e) {
        is JsonArray -> e.any { isExplicit(it) }
        is JsonObject -> str(e["iconType"]) == "MUSIC_EXPLICIT_BADGE" || e.any { (k, v) -> k != "menu" && isExplicit(v) }
        else -> false
    }

    /** A playable song or video from a list row. `requireDuration = false` for artist and album pages. */
    private fun parseTrack(r: JsonObject, requireDuration: Boolean): Track? {
        val cols = r["flexColumns"] as? JsonArray ?: return null
        if (cols.isEmpty()) return null
        val id = str(dig(r, "playlistItemData", "videoId")) ?: str(firstValue(cols[0], "videoId")) ?: return null
        val title = columnText(cols[0], FLEX)
        if (title.isEmpty()) return null

        val meta = if (cols.size > 1) columnText(cols[1], FLEX) else ""
        val parts = meta.split("•").map { it.trim() }.filter { it.isNotEmpty() }.toMutableList()
        if (parts.isNotEmpty() && parts[0] in listOf("Song", "Video", "Episode")) parts.removeAt(0)

        var duration: Double? = null
        if (parts.isNotEmpty()) {
            parseDuration(parts.last())?.let {
                duration = it
                parts.removeAt(parts.size - 1)
            }
        }
        if (duration == null) {
            val fixed = (r["fixedColumns"] as? JsonArray)?.firstOrNull()
            if (fixed != null) duration = parseDuration(columnText(fixed, "musicResponsiveListItemFixedColumnRenderer"))
        }
        if (duration == null && requireDuration) return null

        val artist = parts.getOrNull(0) ?: ""
        val second = parts.getOrNull(1)?.lowercase() ?: ""
        val album = if (parts.size > 1 && !second.contains("view") && !second.contains("play")) parts[1] else null
        return Track(
            id = id,
            title = title,
            artist = artist,
            album = album,
            duration = duration,
            artworkURL = thumbnail(r),
            explicit = if (isExplicit(r)) true else null,
        )
    }

    private fun albumRef(r: JsonObject, artist: String): AlbumRef? {
        val id = str(dig(r, "navigationEndpoint", "browseEndpoint", "browseId")) ?: return null
        val title = text(r["title"]) ?: return null
        if (!id.startsWith("MPRE")) return null
        return AlbumRef(id, title, artist, thumbnail(r))
    }

    companion object {
        const val WEB_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
        const val VISION_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        private const val FLEX = "musicResponsiveListItemFlexColumnRenderer"
        private const val SONGS = "EgWKAQIIAWoMEA4QChADEAQQCRAF"
        private const val ARTISTS = "EgWKAQIgAWoMEA4QChADEAQQCRAF"
        private const val ALBUMS = "EgWKAQIYAWoMEA4QChADEAQQCRAF"
        private const val VIDEOS = "EgWKAQIQAWoMEA4QChADEAQQCRAF"
    }
}
