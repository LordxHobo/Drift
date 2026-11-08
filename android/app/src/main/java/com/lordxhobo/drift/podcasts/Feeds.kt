package com.lordxhobo.drift.podcasts

import com.lordxhobo.drift.data.Track
import com.lordxhobo.drift.youtube.HttpDownloader
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Request
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/**
 * Podcasts from their own feeds (RSS 2.0 with Apple's itunes: tags, as every podcast host makes them):
 * shows found in Apple's podcast directory, or any feed link pasted in. Episodes are plain audio files.
 * The same ids as the iPhone and the computer (rss-…, from the feed link and each episode's guid).
 */
object Feeds {
    private const val UA = "Drift/1.0 (podcast app)"
    /** Shows can have many hundreds of episodes; the newest this many are kept. */
    const val MAX_EPISODES = 500
    /** Seconds between 1970 and 2001 (dates count from 2001, like the iPhone's). */
    private const val SINCE_2001 = 978_307_200.0

    /** 64-bit FNV-1a of the text (UTF-8), as 16 hex digits. */
    fun fnv64(s: String): String {
        var h = -0x340d631b7bdddcdbL // 0xcbf29ce484222325
        for (b in s.toByteArray(Charsets.UTF_8)) {
            h = h xor (b.toLong() and 0xff)
            h *= 0x100000001b3L
        }
        return java.lang.Long.toUnsignedString(h, 16).padStart(16, '0')
    }

    /** A show's or episode's id: "rss-" and 14 hex digits (fits where YouTube ids go). */
    fun feedId(key: String): String = "rss-" + fnv64(key).take(14)

    private val entities = mapOf("amp" to "&", "lt" to "<", "gt" to ">", "quot" to "\"", "apos" to "'", "nbsp" to "\u00A0")

    fun decodeText(s: String): String {
        Regex("^\\s*<!\\[CDATA\\[([\\s\\S]*?)]]>\\s*$").find(s)?.let { return it.groupValues[1].trim() }
        return s.replace(Regex("<!\\[CDATA\\[([\\s\\S]*?)]]>"), "$1")
            .replace(Regex("&(#x[0-9a-fA-F]+|#\\d+|\\w+);")) { m ->
                val e = m.groupValues[1]
                if (e.startsWith("#")) {
                    val n = if (e.length > 1 && (e[1] == 'x' || e[1] == 'X')) e.drop(2).toIntOrNull(16) else e.drop(1).toIntOrNull()
                    if (n != null && n > 0) String(Character.toChars(n)) else m.value
                } else entities[e.lowercase()] ?: m.value
            }
            .trim()
    }

    /** The text inside the first <tag>…</tag>. */
    private fun tagText(xml: String, tag: String): String? {
        val t = Regex.escape(tag)
        return Regex("<$t(?:\\s[^>]*)?>([\\s\\S]*?)</$t>", RegexOption.IGNORE_CASE).find(xml)?.let { decodeText(it.groupValues[1]) }
    }

    /** An attribute of the first <tag …> that has it. */
    private fun tagAttr(xml: String, tag: String, attr: String): String? {
        val a = Regex("\\s${Regex.escape(attr)}\\s*=\\s*(\"([^\"]*)\"|'([^']*)')", RegexOption.IGNORE_CASE)
        for (m in Regex("<${Regex.escape(tag)}\\s[^>]*>", RegexOption.IGNORE_CASE).findAll(xml)) {
            val found = a.find(m.value) ?: continue
            val v = found.groups[2]?.value ?: found.groups[3]?.value ?: ""
            return decodeText(v)
        }
        return null
    }

    /** "1:02:03", "62:03", "3723" or "3723.5" → seconds. */
    fun parseDuration(s: String?): Double? {
        if (s == null) return null
        val parts = s.trim().split(":").map { it.toDoubleOrNull() }
        if (parts.isEmpty() || parts.any { it == null || !it.isFinite() }) return null
        val secs = parts.fold(0.0) { acc, n -> acc * 60 + n!! }
        return if (secs > 0) Math.round(secs).toDouble() else null
    }

    private val dateFormats = listOf("EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "yyyy-MM-dd'T'HH:mm:ssXXX", "EEE, d MMM yyyy")

    /** RFC 822 date ("Tue, 27 Oct 2026 21:00:00 GMT") → seconds since 2001. */
    fun parseDate(s: String?): Double? {
        val text = s?.trim()?.replace(Regex("\\s+"), " ") ?: return null
        for (f in dateFormats) {
            val fmt = SimpleDateFormat(f, Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC"); isLenient = false }
            val d = runCatching { fmt.parse(text) }.getOrNull() ?: continue
            return d.time / 1000.0 - SINCE_2001
        }
        return null
    }

    private fun httpsImage(u: String?): String? = u?.trim()?.replace(Regex("^http://", RegexOption.IGNORE_CASE), "https://")

    data class Parsed(val title: String, val channel: PodcastChannel, val episodes: List<Track>)

    fun parseFeed(xml: String, c: PodcastChannel): Parsed {
        val firstItem = Regex("<item[\\s>]", RegexOption.IGNORE_CASE).find(xml)?.range?.first ?: -1
        val head = if (firstItem >= 0) xml.substring(0, firstItem) else xml
        // <image> has its own <title>, so it's set aside before reading the show's.
        val imageBlock = Regex("<image[\\s>][\\s\\S]*?</image>", RegexOption.IGNORE_CASE).find(head)?.value
        val title = tagText(if (imageBlock != null) head.replaceFirst(imageBlock, "") else head, "title") ?: ""
        val image = httpsImage(tagAttr(head, "itunes:image", "href") ?: imageBlock?.let { tagText(it, "url") })
        val author = tagText(head, "itunes:author")
        val channel = PodcastChannel(
            id = c.id,
            name = c.name.ifEmpty { title.ifEmpty { "Podcast" } },
            avatarURL = c.avatarURL?.ifEmpty { null } ?: image,
            subtitle = c.subtitle ?: author?.ifEmpty { null },
            feedURL = c.feedURL,
        )
        val episodes = mutableListOf<Track>()
        val seen = mutableSetOf<String>()
        for (m in Regex("<item[\\s>][\\s\\S]*?</item>", RegexOption.IGNORE_CASE).findAll(xml)) {
            val item = m.value
            val audio = tagAttr(item, "enclosure", "url") ?: tagAttr(item, "media:content", "url") ?: continue
            val guid = tagText(item, "guid")?.ifEmpty { null } ?: audio
            val id = feedId("${c.id}|$guid")
            if (!seen.add(id)) continue
            episodes += Track(
                id = id,
                title = tagText(item, "title")?.ifEmpty { null } ?: tagText(item, "itunes:title")?.ifEmpty { null } ?: "Episode",
                artist = channel.name,
                artworkURL = httpsImage(tagAttr(item, "itunes:image", "href")) ?: channel.avatarURL,
                duration = parseDuration(tagText(item, "itunes:duration")),
                podcast = true,
                channelID = c.id,
                channelAvatar = channel.avatarURL,
                published = parseDate(tagText(item, "pubDate")),
                audioURL = audio.trim(),
                feedURL = c.feedURL,
            )
        }
        // Newest first (most feeds already are, a few list oldest first).
        val sorted = episodes.sortedByDescending { it.published ?: Double.NEGATIVE_INFINITY }
        return Parsed(title, channel, sorted.take(MAX_EPISODES))
    }

    private fun get(url: String, accept: String? = null): String {
        val b = Request.Builder().url(url).header("User-Agent", UA)
        if (accept != null) b.header("Accept", accept)
        HttpDownloader.shared.client.newCall(b.build()).execute().use { r ->
            if (!r.isSuccessful) throw IOException("The feed answered ${r.code}")
            return r.body?.string() ?: ""
        }
    }

    private fun fetchFeed(url: String) = get(url, "application/rss+xml, application/xml, text/xml, */*")

    /** Shows in Apple's podcast directory (this country's, then the US one if that finds nothing). Blocking. */
    fun searchShows(term: String): List<PodcastChannel> {
        val here = Locale.getDefault().country.ifEmpty { "US" }.uppercase()
        val found = searchIn(term, here)
        return if (found.isNotEmpty() || here == "US") found else searchIn(term, "US")
    }

    private fun searchIn(term: String, country: String): List<PodcastChannel> {
        val url = "https://itunes.apple.com/search".toHttpUrl().newBuilder()
            .addQueryParameter("media", "podcast").addQueryParameter("entity", "podcast")
            .addQueryParameter("limit", "20").addQueryParameter("country", country).addQueryParameter("term", term)
            .build().toString()
        val body = Json.parseToJsonElement(get(url)) as? JsonObject ?: return emptyList()
        val out = mutableListOf<PodcastChannel>()
        for (r in (body["results"] as? JsonArray).orEmpty()) {
            val o = r as? JsonObject ?: continue
            fun s(k: String) = (o[k] as? JsonPrimitive)?.contentOrNull
            val feed = s("feedUrl")?.ifEmpty { null } ?: continue
            if (out.any { it.feedURL == feed }) continue
            val count = (o["trackCount"] as? JsonPrimitive)?.intOrNull ?: 0
            val author = s("artistName") ?: ""
            out += PodcastChannel(
                id = feedId(feed),
                name = s("collectionName") ?: s("trackName") ?: "Podcast",
                avatarURL = s("artworkUrl600") ?: s("artworkUrl100"),
                subtitle = listOf(author, if (count > 0) "$count episodes" else "").filter { it.isNotEmpty() }.joinToString(" · ").ifEmpty { null },
                feedURL = feed,
            )
        }
        return out
    }

    /** Where a pasted link's feed is: a feed link, a show's Apple Podcasts page, or a SoundCloud profile. */
    private fun feedFor(link: String): String? {
        val url = link.toHttpUrlOrNull() ?: return null
        val host = url.host.lowercase()
        if (host.endsWith("podcasts.apple.com") || host.endsWith("itunes.apple.com")) {
            val id = Regex("id(\\d+)").find(url.encodedPath)?.groupValues?.get(1) ?: return null
            val body = Json.parseToJsonElement(get("https://itunes.apple.com/lookup?id=$id&entity=podcast")) as? JsonObject ?: return null
            val first = (body["results"] as? JsonArray)?.firstOrNull() as? JsonObject
            return (first?.get("feedUrl") as? JsonPrimitive)?.contentOrNull?.ifEmpty { null }
        }
        if (host.endsWith("soundcloud.com") && !host.startsWith("feeds.")) {
            val n = Regex("soundcloud(?:://|:)users:(\\d+)").find(fetchFeed(link))?.groupValues?.get(1) ?: return null
            return "https://feeds.soundcloud.com/users/soundcloud:users:$n/sounds.rss"
        }
        return link
    }

    /** A show from a pasted link (with its episodes). Blocking. */
    fun showFromLink(link: String): Parsed? {
        val trimmed = link.trim()
        if (!trimmed.startsWith("http://", true) && !trimmed.startsWith("https://", true)) return null
        val feed = feedFor(trimmed) ?: return null
        val parsed = parseFeed(fetchFeed(feed), PodcastChannel(id = feedId(feed), name = "", feedURL = feed))
        if (parsed.title.isEmpty() && parsed.episodes.isEmpty()) return null
        return parsed
    }

    /** A followed show's episodes, newest first. Blocking. */
    fun episodes(c: PodcastChannel): List<Track> {
        val feed = c.feedURL ?: return emptyList()
        return parseFeed(fetchFeed(feed), c).episodes
    }
}
