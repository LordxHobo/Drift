package com.lordxhobo.drift.lyrics

import com.lordxhobo.drift.data.Track
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import java.net.URLEncoder
import java.util.concurrent.ConcurrentHashMap

/** A line of synced lyrics: when it starts (seconds) and its words. */
data class LyricLine(val time: Double, val text: String)

sealed interface LyricsResult {
    data class Synced(val lines: List<LyricLine>, val source: String) : LyricsResult
    data class Plain(val text: String, val source: String) : LyricsResult
    data object None : LyricsResult
}

/**
 * Lyrics, the same way as the iPhone: synced lyrics from LRCLIB (exact match first, then a search),
 * then plain lyrics from Genius. `get` fetches a URL and returns the status code and body.
 */
class LyricsService(private val get: (url: String) -> Pair<Int, String>) {
    private val cache = ConcurrentHashMap<String, LyricsResult>()

    /** Blocking: call it off the main thread. */
    fun lyrics(t: Track): LyricsResult {
        cache[t.id]?.let { return it }
        val title = cleanTitle(t.title, t.artist)
        val artist = mainArtist(t.artist)
        val duration = t.duration

        val params = mutableListOf("track_name" to title, "artist_name" to artist)
        t.album?.let { params.add("album_name" to it) }
        duration?.let { params.add("duration" to Math.round(it).toString()) }
        var entry = json("https://lrclib.net/api/get?" + query(params)) as? JsonObject
        if (entry != null && text(entry, "syncedLyrics") == null && text(entry, "plainLyrics") == null) entry = null

        if (entry == null) {
            val list = (json("https://lrclib.net/api/search?" + query(listOf("track_name" to title, "artist_name" to artist))) as? JsonArray)
                .orEmpty().mapNotNull { it as? JsonObject }
            fun close(e: JsonObject): Boolean {
                val d = (e["duration"] as? JsonPrimitive)?.doubleOrNull
                return duration == null || d == null || kotlin.math.abs(d - duration) <= 5
            }
            entry = list.firstOrNull { text(it, "syncedLyrics") != null && close(it) }
                ?: list.firstOrNull { text(it, "plainLyrics") != null && close(it) }
        }

        var result: LyricsResult = LyricsResult.None
        text(entry, "syncedLyrics")?.let { lrc ->
            val lines = parseLRC(lrc)
            if (lines.isNotEmpty()) result = LyricsResult.Synced(lines, "LRCLIB")
        }
        if (result == LyricsResult.None) text(entry, "plainLyrics")?.let { result = LyricsResult.Plain(it, "LRCLIB") }
        if (result == LyricsResult.None) genius(title, artist)?.let { result = LyricsResult.Plain(it, "Genius") }
        if (result != LyricsResult.None) cache[t.id] = result
        return result
    }

    private fun query(params: List<Pair<String, String>>): String =
        params.joinToString("&") { (k, v) -> k + "=" + URLEncoder.encode(v, "UTF-8") }

    private fun json(url: String): JsonElement? = runCatching {
        val (status, body) = get(url)
        if (status != 200) null else Json.parseToJsonElement(body)
    }.getOrNull()

    private fun text(o: JsonObject?, key: String): String? =
        (o?.get(key) as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content?.takeIf { it.isNotBlank() }

    // MARK: Genius (plain lyrics, when LRCLIB has none)

    private fun genius(title: String, artist: String): String? {
        val search = json("https://genius.com/api/search/multi?" + query(listOf("q" to "$artist $title"))) as? JsonObject ?: return null
        val sections = ((search["response"] as? JsonObject)?.get("sections") as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
        val song = sections.firstOrNull { (it["type"] as? JsonPrimitive)?.content == "song" } ?: return null
        val hit = (song["hits"] as? JsonArray)?.firstOrNull() as? JsonObject ?: return null
        val page = ((hit["result"] as? JsonObject)?.get("url") as? JsonPrimitive)?.content ?: return null
        val (status, html) = runCatching { get(page) }.getOrNull() ?: return null
        return if (status == 200) extractGeniusLyrics(html) else null
    }

    companion object {
        /** "Artist, Other & Someone" → "Artist". */
        fun mainArtist(a: String): String {
            var s = a
            for (sep in listOf(", ", " & ", " x ", " feat. ", " ft. ")) {
                val i = s.lowercase().indexOf(sep)
                if (i >= 0) s = s.substring(0, i)
            }
            return s.trim()
        }

        /** Without "(Official Video)" and the like, and without "Artist - " in front. */
        fun cleanTitle(t: String, artist: String): String {
            var s = t.replace(
                Regex("\\s*[(\\[][^)\\]]*(official|video|audio|lyric|visuali[sz]er|\\bhd\\b|4k|\\bmv\\b|remaster)[^)\\]]*[)\\]]", RegexOption.IGNORE_CASE),
                "",
            )
            val main = mainArtist(artist).lowercase()
            val dash = s.indexOf(" - ")
            if (main.isNotEmpty() && s.lowercase().startsWith(main) && dash >= 0) s = s.substring(dash + 3)
            s = s.replace(Regex("\\s+-\\s+.*(remaster|version|edit|mix).*$", RegexOption.IGNORE_CASE), "")
            return s.trim()
        }

        fun parseLRC(lrc: String): List<LyricLine> {
            val tag = Regex("\\[(\\d+):(\\d+(?:\\.\\d+)?)]")
            val lines = mutableListOf<LyricLine>()
            for (raw in lrc.split(Regex("\\r?\\n"))) {
                val tags = tag.findAll(raw).toList()
                if (tags.isEmpty()) continue
                val text = raw.substring(tags.last().range.last + 1).trim()
                for (m in tags) lines.add(LyricLine(m.groupValues[1].toDouble() * 60 + m.groupValues[2].toDouble(), text))
            }
            return lines.sortedBy { it.time }
        }

        /** Content ranges of every `<div … marker …>` element, with nested divs matched. */
        private fun divRanges(html: String, marker: String): List<IntRange> {
            val out = mutableListOf<IntRange>()
            var from = 0
            while (true) {
                val m = html.indexOf(marker, from)
                if (m < 0) break
                val open = html.indexOf('>', m)
                if (open < 0) break
                var depth = 1
                var i = open + 1
                var end = html.length
                while (i < html.length) {
                    if (html[i] == '<') {
                        if (html.startsWith("<div", i)) depth++
                        else if (html.startsWith("</div", i)) {
                            depth--
                            if (depth == 0) {
                                end = i
                                break
                            }
                        }
                    }
                    i++
                }
                out.add(open + 1 until end)
                from = end
            }
            return out
        }

        fun extractGeniusLyrics(html: String): String? {
            val parts = mutableListOf<String>()
            for (r in divRanges(html, "data-lyrics-container=\"true\"")) {
                var chunk = html.substring(r.first, r.last + 1)
                // Headers Genius puts inside the container (contributors, the "Lyrics" title…).
                while (true) {
                    val ex = divRanges(chunk, "data-exclude-from-selection=\"true\"").firstOrNull() ?: break
                    val start = chunk.lastIndexOf("<div", ex.first)
                    val close = chunk.indexOf("</div>", ex.last + 1)
                    if (start < 0 || close < 0) break
                    chunk = chunk.removeRange(start, close + "</div>".length)
                }
                parts.add(chunk)
            }
            if (parts.isEmpty()) return null
            var text = parts.joinToString("<br/>")
            text = text.replace(Regex("<br\\s*/?>"), "\n")
            text = text.replace(Regex("<[^>]+>"), "")
            text = decodeEntities(text)
            text = text.replace(Regex("\n{3,}"), "\n\n").trim()
            return text.ifEmpty { null }
        }

        private fun decodeEntities(s: String): String {
            var out = s
            for ((k, v) in listOf("&amp;" to "&", "&quot;" to "\"", "&#x27;" to "'", "&#39;" to "'", "&apos;" to "'", "&lt;" to "<", "&gt;" to ">", "&nbsp;" to " ")) {
                out = out.replace(k, v)
            }
            return Regex("&#(x?)([0-9a-fA-F]+);").replace(out) { m ->
                val code = m.groupValues[2].toIntOrNull(if (m.groupValues[1].isEmpty()) 10 else 16)
                if (code != null) String(Character.toChars(code)) else m.value
            }
        }
    }
}
