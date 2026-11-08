package com.lordxhobo.drift.podcasts

import com.lordxhobo.drift.data.Track
import com.lordxhobo.drift.youtube.HttpDownloader
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.net.URLEncoder
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone

/**
 * Podcasts on YouTube: any channel (or one of its podcast playlists) followed as a show, its videos as
 * episodes, and any video played from a pasted link. The same as the computer's (desktop/src/main/youtube.ts).
 */
object YouTubePodcasts {
    private const val UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
    private const val APPLE_EPOCH = 978_307_200.0

    // MARK: JSON helpers

    private fun dig(e: JsonElement?, vararg path: Any): JsonElement? {
        var cur = e
        for (k in path) {
            cur = when (k) {
                is String -> (cur as? JsonObject)?.get(k)
                is Int -> (cur as? JsonArray)?.let { a -> if (k < 0) a.getOrNull(a.size + k) else a.getOrNull(k) }
                else -> null
            } ?: return null
        }
        return cur
    }

    private fun str(e: JsonElement?): String? = (e as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    private fun text(e: JsonElement?): String? {
        val o = e as? JsonObject ?: return null
        str(o["simpleText"])?.let { return it }
        val runs = o["runs"] as? JsonArray ?: return null
        return runs.joinToString("") { str((it as? JsonObject)?.get("text")) ?: "" }.ifEmpty { null }
    }

    private fun viewText(e: JsonElement?): String? = str((e as? JsonObject)?.get("content")) ?: text(e)

    /** Every string in it (keys in order), like the computer's `strings`. */
    private fun strings(e: JsonElement?): List<String> = when (e) {
        is JsonPrimitive -> if (e.isString) listOf(e.content) else emptyList()
        is JsonArray -> e.flatMap { strings(it) }
        is JsonObject -> e.keys.sorted().flatMap { strings(e[it]) }
        else -> emptyList()
    }

    /** Members-only videos don't play without a paid membership: left out everywhere. */
    private fun membersOnly(e: JsonElement?): Boolean =
        strings(e).any { it == "Members only" || it == "Members first" || it.contains("MEMBERS_ONLY") }

    private fun parseDuration(s: String): Double? {
        val parts = s.split(":")
        if (parts.size < 2 || parts.size > 3) return null
        var total = 0.0
        for (p in parts) {
            if (p.isEmpty() || !p.all { it.isDigit() }) return null
            total = total * 60 + p.toDouble()
        }
        return total
    }

    private fun fixURL(s: String?): String? = s?.let { if (it.startsWith("//")) "https:$it" else it }

    /** "3 days ago" → seconds since 2001. */
    private fun relativeDate(s: String?): Double? {
        val m = s?.let { Regex("(\\d+)\\s+(second|minute|hour|day|week|month|year)").find(it) } ?: return null
        val unit = when (m.groupValues[2]) {
            "second" -> 1; "minute" -> 60; "hour" -> 3600; "day" -> 86400; "week" -> 7 * 86400; "month" -> 30 * 86400; else -> 365 * 86400
        }
        return System.currentTimeMillis() / 1000.0 - m.groupValues[1].toDouble() * unit - APPLE_EPOCH
    }

    /** youtube.com's own scheme: "2.<yesterday's date>.00.00". */
    private fun clientVersion(): String {
        val c = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply { add(Calendar.DAY_OF_MONTH, -1) }
        return "2.%04d%02d%02d.00.00".format(c.get(Calendar.YEAR), c.get(Calendar.MONTH) + 1, c.get(Calendar.DAY_OF_MONTH))
    }

    private fun post(path: String, fields: JsonObject): JsonElement {
        val version = clientVersion()
        val body = JsonObject(fields + ("context" to buildJsonObject {
            putJsonObject("client") {
                put("clientName", "WEB"); put("clientVersion", version); put("hl", "en"); put("gl", "US")
            }
        }))
        val req = Request.Builder()
            .url("https://www.youtube.com/youtubei/v1/$path?prettyPrint=false")
            .header("User-Agent", UA)
            .header("Origin", "https://www.youtube.com")
            .header("X-YouTube-Client-Name", "1")
            .header("X-YouTube-Client-Version", version)
            .post(body.toString().toRequestBody("application/json".toMediaType()))
            .build()
        HttpDownloader.shared.client.newCall(req).execute().use { r ->
            if (r.code != 200) throw IOException("YouTube answered ${r.code}")
            return Json.parseToJsonElement(r.body?.string() ?: "{}")
        }
    }

    private fun fields(vararg pairs: Pair<String, String>) = JsonObject(pairs.associate { it.first to JsonPrimitive(it.second) })

    // MARK: Videos as episodes

    private data class Video(val id: String, val title: String, val channel: String, val duration: Double)

    private fun parseVideo(r: JsonElement?): Video? {
        val o = r as? JsonObject ?: return null
        if (membersOnly(o["badges"]) || membersOnly(o["badge"])) return null
        val id = str(o["videoId"]) ?: return null
        val title = viewText(o["title"]) ?: return null
        val duration = parseDuration(viewText(o["lengthText"]) ?: "") ?: return null
        // Live streams have no length; shorts are under a minute.
        if (duration < 60) return null
        return Video(id, title, str(dig(o, "ownerText", "runs", 0, "text")) ?: "", duration)
    }

    private fun metadataRows(meta: JsonElement?): List<JsonElement> =
        (dig(meta, "metadata", "contentMetadataViewModel", "metadataRows") as? JsonArray).orEmpty()

    private fun parseLockup(v: JsonElement?): Video? {
        val o = v as? JsonObject ?: return null
        val id = str(o["contentId"]) ?: return null
        if (id.length != 11 || str(o["contentType"]) != "LOCKUP_CONTENT_TYPE_VIDEO") return null
        if (membersOnly(o)) return null
        val meta = dig(o, "metadata", "lockupMetadataViewModel")
        val title = viewText(dig(meta, "title")) ?: return null
        val duration = strings(dig(o, "contentImage", "thumbnailViewModel", "overlays")).firstNotNullOfOrNull { parseDuration(it) } ?: return null
        if (duration < 60) return null
        var channel = ""
        for (row in metadataRows(meta)) for (part in (dig(row, "metadataParts") as? JsonArray).orEmpty()) {
            val browse = str(dig(part, "text", "commandRuns", 0, "onTap", "innertubeCommand", "browseEndpoint", "browseId"))
            if (browse != null && browse.startsWith("UC")) channel = viewText(dig(part, "text")) ?: channel
        }
        return Video(id, title, channel, duration)
    }

    private fun episodeFromVideo(r: JsonElement?): Track? {
        val v = parseVideo(r) ?: return null
        val thumbs = dig(r, "thumbnail", "thumbnails") as? JsonArray
        return Track(
            id = v.id, title = v.title, artist = v.channel, duration = v.duration,
            artworkURL = fixURL(str(dig(thumbs?.lastOrNull(), "url"))) ?: "https://i.ytimg.com/vi/${v.id}/mqdefault.jpg",
            podcast = true,
            channelID = str(dig(r, "ownerText", "runs", 0, "navigationEndpoint", "browseEndpoint", "browseId")),
            channelAvatar = fixURL(str(dig(r, "channelThumbnailSupportedRenderers", "channelThumbnailWithLinkRenderer", "thumbnail", "thumbnails", 0, "url"))),
            published = relativeDate(viewText(dig(r, "publishedTimeText"))),
        )
    }

    private fun episodeFromLockup(v: JsonElement?): Track? {
        val base = parseLockup(v) ?: return null
        val meta = dig(v, "metadata", "lockupMetadataViewModel")
        var channelID: String? = null
        for (row in metadataRows(meta)) for (part in (dig(row, "metadataParts") as? JsonArray).orEmpty()) {
            val browse = str(dig(part, "text", "commandRuns", 0, "onTap", "innertubeCommand", "browseEndpoint", "browseId"))
            if (browse != null && browse.startsWith("UC")) channelID = browse
        }
        val sources = dig(v, "contentImage", "thumbnailViewModel", "image", "sources") as? JsonArray
        val avatar = strings(dig(meta, "image")).firstOrNull { it.startsWith("https://yt3") || it.startsWith("//yt3") }
        return Track(
            id = base.id, title = base.title, artist = base.channel, duration = base.duration,
            artworkURL = fixURL(str(dig(sources?.lastOrNull(), "url"))) ?: "https://i.ytimg.com/vi/${base.id}/mqdefault.jpg",
            podcast = true,
            channelID = channelID,
            channelAvatar = fixURL(avatar),
            published = relativeDate(strings(metadataRows(meta).let { JsonArray(it) }).firstOrNull { it.endsWith(" ago") }),
        )
    }

    private fun parseChannel(r: JsonElement?): PodcastChannel? {
        val id = str(dig(r, "channelId")) ?: return null
        val name = viewText(dig(r, "title")) ?: return null
        val thumbs = dig(r, "thumbnail", "thumbnails") as? JsonArray
        val candidates = listOfNotNull(viewText(dig(r, "videoCountText")), viewText(dig(r, "subscriberCountText")))
        return PodcastChannel(
            id = id, name = name,
            avatarURL = fixURL(str(dig(thumbs?.lastOrNull(), "url"))),
            subtitle = candidates.firstOrNull { it.contains("subscriber") } ?: candidates.firstOrNull(),
        )
    }

    private val imageIn = { e: JsonElement? ->
        fixURL(strings(e).firstOrNull { Regex("^(https:)?//(i\\d?\\.ytimg\\.com|yt3\\.)").containsMatchIn(it) && !it.contains("/vi_webp/") })
    }

    private fun podcastFromLockup(v: JsonElement?, forcePodcast: Boolean = false): PodcastChannel? {
        val id = str(dig(v, "contentId")) ?: return null
        if (!id.startsWith("PL")) return null
        if (!forcePodcast && !(str(dig(v, "contentType")) ?: "").contains("PODCAST")) return null
        val meta = dig(v, "metadata", "lockupMetadataViewModel")
        val name = viewText(dig(meta, "title")) ?: return null
        val by = strings(JsonArray(metadataRows(meta))).firstOrNull { it.isNotBlank() && !Regex("\\d+ (episode|video)").containsMatchIn(it) }
        return PodcastChannel(id, name, imageIn(dig(v, "contentImage")), if (by != null) "Podcast · $by" else "Podcast")
    }

    private fun collectEpisodes(json: JsonElement, channels: MutableList<PodcastChannel>? = null): List<Track> {
        val out = mutableListOf<Track>()
        fun visit(e: JsonElement?) {
            when (e) {
                is JsonArray -> e.forEach { visit(it) }
                is JsonObject -> for (k in e.keys.sorted()) {
                    val v = e[k]
                    if (k == "videoRenderer" || k == "lockupViewModel") {
                        val t = if (k == "videoRenderer") episodeFromVideo(v) else episodeFromLockup(v)
                        if (t != null && out.none { it.id == t.id }) out += t
                        // A podcast (YouTube's podcast playlists) in the results: a show of its own.
                        val show = if (k == "lockupViewModel" && channels != null) podcastFromLockup(v) else null
                        if (show != null && channels!!.none { it.id == show.id }) channels += show
                    } else if (k == "channelRenderer" && channels != null) {
                        val c = parseChannel(v)
                        if (c != null && channels.none { it.id == c.id }) channels += c
                    } else visit(v)
                }
                else -> {}
            }
        }
        visit(json)
        return out
    }

    /** Shows (channels and podcasts) and episodes on YouTube. Blocking. */
    fun search(query: String): Pair<List<PodcastChannel>, List<Track>> {
        val json = post("search", fields("query" to query))
        val channels = mutableListOf<PodcastChannel>()
        val episodes = collectEpisodes(json, channels)
        return channels to episodes
    }

    // MARK: YouTube podcasts (playlists marked as podcasts, on a channel's Podcasts tab)

    private fun findAll(e: JsonElement?, keys: Set<String>, found: (String, JsonElement?) -> Unit) {
        when (e) {
            is JsonArray -> e.forEach { findAll(it, keys, found) }
            is JsonObject -> for ((k, v) in e) if (k in keys) found(k, v) else findAll(v, keys, found)
            else -> {}
        }
    }

    /** The podcasts on a channel's Podcasts tab (none when it has no such tab). */
    private fun channelPodcasts(channel: PodcastChannel): List<PodcastChannel> {
        if (!channel.id.startsWith("UC")) return emptyList()
        val home = post("browse", fields("browseId" to channel.id))
        var params: String? = null
        findAll(home, setOf("tabRenderer")) { _, tab ->
            val url = str(dig(tab, "endpoint", "commandMetadata", "webCommandMetadata", "url"))
            if (url != null && url.endsWith("/podcasts")) params = str(dig(tab, "endpoint", "browseEndpoint", "params"))
        }
        val p = params ?: return emptyList()
        val json = post("browse", fields("browseId" to channel.id, "params" to p))
        val out = mutableListOf<PodcastChannel>()
        findAll(json, setOf("lockupViewModel", "gridPlaylistRenderer", "playlistRenderer")) { k, v ->
            val show = if (k == "lockupViewModel") podcastFromLockup(v, forcePodcast = true)
            else str(dig(v, "playlistId"))?.takeIf { it.startsWith("PL") }?.let { id ->
                viewText(dig(v, "title"))?.let { name -> PodcastChannel(id, name, imageIn(dig(v, "thumbnail") ?: dig(v, "thumbnails")), "Podcast") }
            }
            if (show != null && out.none { it.id == show.id }) {
                out += show.copy(subtitle = "Podcast · ${channel.name}", avatarURL = show.avatarURL ?: channel.avatarURL)
            }
        }
        return out
    }

    private fun episodeFromPlaylistVideo(r: JsonElement?): Track? {
        if (membersOnly(dig(r, "badges")) || membersOnly(dig(r, "thumbnailOverlays"))) return null
        val id = str(dig(r, "videoId")) ?: return null
        val title = viewText(dig(r, "title")) ?: return null
        val duration = str(dig(r, "lengthSeconds"))?.toDoubleOrNull()?.takeIf { it > 0 } ?: parseDuration(viewText(dig(r, "lengthText")) ?: "")
        if (duration != null && duration < 60) return null
        return Track(
            id = id, title = title, artist = str(dig(r, "shortBylineText", "runs", 0, "text")) ?: "",
            duration = duration, artworkURL = "https://i.ytimg.com/vi/$id/mqdefault.jpg", podcast = true,
            published = relativeDate(strings(dig(r, "videoInfo")).firstOrNull { it.endsWith(" ago") }),
        )
    }

    /** Newest first: by date where there is one; undated ones keep their place in the list. */
    private fun newestFirst(list: List<Track>): List<Track> {
        if (list.none { it.published != null }) return list
        var last: Double? = null
        return list.map { t ->
            if (t.published != null) last = t.published
            t to (t.published ?: last ?: Double.NEGATIVE_INFINITY)
        }.sortedByDescending { it.second }.map { it.first }
    }

    /** The continuation token in a browse answer (the next page), if any. */
    private fun nextToken(e: JsonElement): String? {
        var token: String? = null
        findAll(e, setOf("continuationItemRenderer")) { _, v ->
            str(dig(v, "continuationEndpoint", "continuationCommand", "token"))?.let { token = it }
        }
        return token
    }

    /** A YouTube podcast's episodes (its playlist), newest first. */
    private fun playlistEpisodes(show: PodcastChannel, artist: String = show.name, channelID: String = show.id): List<Track> {
        val list = show.id.removePrefix("VL")
        val out = mutableListOf<Track>()
        var token: String? = null
        for (page in 0 until 6) {
            val json = if (page == 0) post("browse", fields("browseId" to "VL$list")) else post("browse", fields("continuation" to token!!))
            token = nextToken(json)
            var added = 0
            findAll(json, setOf("playlistVideoRenderer", "lockupViewModel", "videoRenderer")) { k, v ->
                val t = when (k) {
                    "playlistVideoRenderer" -> episodeFromPlaylistVideo(v)
                    "videoRenderer" -> episodeFromVideo(v)
                    else -> episodeFromLockup(v)
                } ?: return@findAll
                if (out.any { it.id == t.id }) return@findAll
                out += t.copy(artist = artist, channelID = channelID, channelAvatar = show.avatarURL)
                added++
            }
            if (token == null || added == 0 || out.size >= 400) break
        }
        val dates = rssEpisodes(show.copy(id = list), "playlist_id=$list").mapNotNull { t -> t.published?.let { t.id to it } }.toMap()
        return newestFirst(out.map { t -> dates[t.id]?.let { t.copy(published = it) } ?: t })
    }

    /** The channel's (or playlist's) RSS feed: only the latest 15 uploads, but with exact dates. */
    private fun rssEpisodes(channel: PodcastChannel, which: String = "channel_id=${channel.id}"): List<Track> = runCatching {
        val req = Request.Builder().url("https://www.youtube.com/feeds/videos.xml?$which").header("User-Agent", UA).build()
        HttpDownloader.shared.client.newCall(req).execute().use { r ->
            if (r.code != 200) return@use emptyList()
            val xml = r.body?.string() ?: return@use emptyList()
            fun unescape(s: String) = s.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&#39;", "'")
            val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.US)
            xml.split("<entry>").drop(1).mapNotNull { entry ->
                val id = Regex("<yt:videoId>([^<]+)</yt:videoId>").find(entry)?.groupValues?.get(1) ?: return@mapNotNull null
                val title = Regex("<title>([^<]*)</title>").find(entry)?.groupValues?.get(1) ?: return@mapNotNull null
                val link = Regex("<link[^>]*href=\"([^\"]+)\"").find(entry)?.groupValues?.get(1) ?: ""
                if (id.length != 11 || link.contains("/shorts/")) return@mapNotNull null
                val published = Regex("<published>([^<]+)</published>").find(entry)?.groupValues?.get(1)
                val author = Regex("<author>\\s*<name>([^<]*)</name>").find(entry)?.groupValues?.get(1)
                Track(
                    id = id, title = unescape(title), artist = author?.let { unescape(it) } ?: channel.name,
                    artworkURL = "https://i.ytimg.com/vi/$id/mqdefault.jpg", podcast = true,
                    channelID = channel.id, channelAvatar = channel.avatarURL,
                    published = published?.let { p -> runCatching { iso.parse(p)!!.time / 1000.0 - APPLE_EPOCH }.getOrNull() },
                )
            }
        }
    }.getOrDefault(emptyList())

    /**
     * A show's episodes: one podcast's playlist; a channel's podcasts (when it has a Podcasts tab); else
     * its Videos tab (a few pages), with exact dates from its RSS feed. Blocking.
     */
    fun channelEpisodes(channel: PodcastChannel): List<Track> {
        if (channel.id.startsWith("PL") || channel.id.startsWith("VL")) return playlistEpisodes(channel)
        val podcasts = runCatching { channelPodcasts(channel) }.getOrDefault(emptyList())
        if (podcasts.isNotEmpty()) {
            val all = podcasts.take(4).flatMap { p ->
                runCatching { playlistEpisodes(p.copy(avatarURL = channel.avatarURL ?: p.avatarURL), channel.name, channel.id) }.getOrDefault(emptyList())
            }.distinctBy { it.id }
            if (all.isNotEmpty()) return newestFirst(all.sortedByDescending { it.published ?: Double.NEGATIVE_INFINITY })
        }
        val out = mutableListOf<Track>()
        var token: String? = null
        try {
            for (page in 0 until 4) {
                val json = if (page == 0) post("browse", fields("browseId" to channel.id, "params" to "EgZ2aWRlb3PyBgQKAjoA"))
                else post("browse", fields("continuation" to token!!))
                token = nextToken(json)
                var added = 0
                for (t in collectEpisodes(json)) {
                    if (out.any { it.id == t.id }) continue
                    out += t.copy(
                        channelID = channel.id,
                        artist = if (t.artist.isEmpty() || t.artist == "YouTube") channel.name else t.artist,
                        channelAvatar = t.channelAvatar ?: channel.avatarURL,
                    )
                    added++
                }
                if (token == null || added == 0 || out.size >= 120) break
            }
        } catch (e: Exception) {
            if (out.isEmpty()) {
                val rss = rssEpisodes(channel)
                if (rss.isNotEmpty()) return rss
                throw e
            }
        }
        val rss = rssEpisodes(channel)
        if (out.isEmpty()) return rss
        // The feed's exact dates (the Videos tab only says "2 weeks ago"), and anything newer than the tab shows.
        val dates = rss.mapNotNull { t -> t.published?.let { t.id to it } }.toMap()
        val dated = out.map { t -> dates[t.id]?.let { t.copy(published = it) } ?: t }
        val newest = dated.maxOf { it.published ?: Double.NEGATIVE_INFINITY }
        val fresh = rss.filter { r -> dated.none { it.id == r.id } && (r.published ?: Double.NEGATIVE_INFINITY) > newest }
        return fresh + dated
    }

    // MARK: All of YouTube, for music (fan uploads, live sets, mixes)

    /** A video as a song: just its audio, as uploaded. */
    private fun asSong(t: Track, upload: Boolean = true) = Track(
        id = t.id, title = t.title, artist = t.artist, duration = t.duration,
        artworkURL = "https://i.ytimg.com/vi/${t.id}/hqdefault.jpg", upload = if (upload) true else null,
    )

    /** Videos on YouTube as songs (about 20 a page; `more` is the next page's token). A pasted link: that video. Blocking. */
    fun searchYouTube(query: String, more: String? = null): Pair<List<Track>, String?> {
        if (more == null && videoId(query) != null) return listOfNotNull(songFromLink(query)) to null
        val json = post("search", if (more != null) fields("continuation" to more) else fields("query" to query))
        return collectEpisodes(json).map { asSong(it) } to nextToken(json)
    }

    /** A shared or pasted YouTube / YouTube Music link, as a song. Blocking. */
    fun songFromLink(link: String): Track? = videoFromLink(link)?.let { asSong(it, upload = !link.contains("music.youtube")) }

    // MARK: Links

    /** A YouTube link (watch, youtu.be, shorts, live, embed, music.youtube) → video ID. */
    fun videoId(text: String): String? {
        val s = text.trim()
        if (!s.contains("youtu")) return null
        for (p in listOf("[?&]v=([A-Za-z0-9_-]{11})", "youtu\\.be/([A-Za-z0-9_-]{11})", "/(?:shorts|live|embed)/([A-Za-z0-9_-]{11})")) {
            Regex(p).find(s)?.let { return it.groupValues[1] }
        }
        return null
    }

    /** One video from its link, to play as an episode. Blocking. */
    fun videoFromLink(link: String): Track? {
        val id = videoId(link) ?: return null
        runCatching { search(id).second.firstOrNull { it.id == id } }.getOrNull()?.let { return it }
        val url = "https://www.youtube.com/oembed?url=" + URLEncoder.encode("https://www.youtube.com/watch?v=$id", "UTF-8") + "&format=json"
        HttpDownloader.shared.client.newCall(Request.Builder().url(url).build()).execute().use { r ->
            if (r.code != 200) return null
            val o = Json.parseToJsonElement(r.body?.string() ?: "{}") as? JsonObject ?: return null
            return Track(
                id = id, title = str(o["title"]) ?: "Video", artist = str(o["author_name"]) ?: "YouTube",
                artworkURL = "https://i.ytimg.com/vi/$id/mqdefault.jpg", podcast = true,
            )
        }
    }
}
