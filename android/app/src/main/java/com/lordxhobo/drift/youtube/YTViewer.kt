package com.lordxhobo.drift.youtube

import android.content.Context
import android.content.SharedPreferences
import android.webkit.CookieManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
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
import java.security.MessageDigest

data class YTAccount(val name: String, val handle: String, val avatar: String?, val channelId: String?)
data class YTChannel(val id: String, val name: String, val avatar: String?, val fresh: Boolean = false)
data class YTVideo(
    val id: String,
    val title: String,
    val channel: String,
    val channelId: String?,
    val thumbnail: String,
    /** Seconds (none for live streams). */
    val duration: Double?,
    val views: String,
    val published: String,
    val live: Boolean,
)
data class YTVideoDetails(
    val id: String,
    val title: String,
    val views: String,
    val published: String,
    val description: String,
    val channel: YTChannel,
    val subscribers: String,
    val subscribed: Boolean,
    val related: List<YTVideo>,
    /** Where the comments start (and how to post one). */
    val commentsToken: String?,
)
data class YTComment(
    val id: String,
    val author: String,
    val authorAvatar: String?,
    val authorChannelId: String?,
    val text: String,
    val published: String,
    val likes: String,
    val replies: Int,
    val pinned: Boolean,
    val byCreator: Boolean,
)
data class YTCommentsPage(val comments: List<YTComment>, val more: String?, val newest: String?, val postParams: String?)

/**
 * The YouTube viewer: the signed-in account (its YouTube cookies, kept on this phone only) and reading its
 * feeds through YouTube's own web API, the same as the computer and the iPhone: new videos from
 * subscriptions, history, Watch later, liked videos, subscribed channels, search, a video's details,
 * comments. Videos themselves play through the normal player (as episodes that show their picture).
 */
object YTViewer {
    /** Who's signed in (null: nobody). */
    var account by mutableStateOf<YTAccount?>(null)
        private set
    var signedIn by mutableStateOf(false)
        private set
    /** Music, or the YouTube viewer. */
    var on by mutableStateOf(false)
        private set

    /** What the sign-in page and requests say they are (Google refuses sign-in in apps' web views). */
    const val SIGNIN_UA = "Mozilla/5.0 (Android 14; Mobile; rv:132.0) Gecko/132.0 Firefox/132.0"
    private const val WEB_VERSION = "2.20251105.01.00"
    private const val ORIGIN = "https://www.youtube.com"

    private lateinit var prefs: SharedPreferences
    private var cookie = ""

    fun init(context: Context) {
        prefs = context.getSharedPreferences("drift.youtube", Context.MODE_PRIVATE)
        cookie = prefs.getString("cookie", "") ?: ""
        signedIn = sapisid() != null
        on = signedIn && prefs.getBoolean("on", false)
    }

    fun turn(value: Boolean) {
        on = value && signedIn
        prefs.edit().putBoolean("on", on).apply()
    }

    /** After the sign-in page reached YouTube: keeps its cookies. True when signed in. */
    fun signedInWith(cookies: String?): Boolean {
        val c = cookies.orEmpty()
        if (!c.contains("SAPISID=") && !c.contains("__Secure-3PAPISID=")) return false
        cookie = c
        prefs.edit().putString("cookie", c).apply()
        signedIn = true
        account = null
        return true
    }

    fun signOut() {
        cookie = ""
        prefs.edit().remove("cookie").putBoolean("on", false).apply()
        signedIn = false
        on = false
        account = null
        runCatching { CookieManager.getInstance().removeAllCookies(null) }
    }

    private fun sapisid(): String? =
        cookie.split(';').map { it.trim() }.firstNotNullOfOrNull { kv ->
            val i = kv.indexOf('=')
            if (i > 0 && (kv.substring(0, i) == "SAPISID" || kv.substring(0, i) == "__Secure-3PAPISID")) kv.substring(i + 1) else null
        }

    /** YouTube's signed-in header: a hash of the time, the SAPISID cookie and the site. */
    private fun auth(): String {
        val ts = System.currentTimeMillis() / 1000
        val hash = MessageDigest.getInstance("SHA-1").digest("$ts ${sapisid()} $ORIGIN".toByteArray()).joinToString("") { "%02x".format(it) }
        return "SAPISIDHASH ${ts}_$hash"
    }

    private suspend fun post(endpoint: String, body: Map<String, Any> = emptyMap()): JsonObject = withContext(Dispatchers.IO) {
        if (sapisid() == null) throw IllegalStateException("Sign in to YouTube first.")
        val payload = buildJsonObject {
            putJsonObject("context") {
                putJsonObject("client") {
                    put("clientName", "WEB")
                    put("clientVersion", WEB_VERSION)
                    put("hl", "en")
                    put("gl", "US")
                }
            }
            for ((k, v) in body) put(k, toJson(v))
        }
        val req = Request.Builder()
            .url("$ORIGIN/youtubei/v1/$endpoint?prettyPrint=false")
            .post(payload.toString().toRequestBody("application/json".toMediaType()))
            .header("User-Agent", SIGNIN_UA)
            .header("Cookie", cookie)
            .header("Authorization", auth())
            .header("Origin", ORIGIN)
            .header("X-Origin", ORIGIN)
            .header("X-Goog-AuthUser", "0")
            .header("X-Youtube-Client-Name", "1")
            .header("X-Youtube-Client-Version", WEB_VERSION)
            .build()
        HttpDownloader.shared.client.newCall(req).execute().use { r ->
            val text = r.body?.string().orEmpty()
            if (r.code == 401 || r.code == 403) throw IllegalStateException("YouTube signed you out. Sign in again in Settings.")
            if (!r.isSuccessful) throw IllegalStateException("YouTube didn't answer (${r.code}).")
            kotlinx.serialization.json.Json.parseToJsonElement(text) as JsonObject
        }
    }

    private fun toJson(v: Any): JsonElement = when (v) {
        is JsonElement -> v
        is String -> JsonPrimitive(v)
        is Number -> JsonPrimitive(v)
        is Boolean -> JsonPrimitive(v)
        is List<*> -> JsonArray(v.map { toJson(it!!) })
        is Map<*, *> -> JsonObject(v.entries.associate { (k, x) -> k.toString() to toJson(x!!) })
        else -> JsonPrimitive(v.toString())
    }

    // MARK: Account

    suspend fun loadAccount(): YTAccount? {
        if (!signedIn) return null
        account?.let { return it }
        val a = runCatching {
            val data = post("account/account_menu")
            val header = find(data, "activeAccountHeaderRenderer")
            val handle = text(get(header, "channelHandle"))
            YTAccount(
                name = text(get(header, "accountName")).ifEmpty { "YouTube" },
                handle = handle,
                avatar = lastThumb(get(header, "accountPhoto")),
                channelId = if (handle.isNotEmpty()) channelFromHandle(handle) else null,
            )
        }.getOrElse { YTAccount("YouTube", "", null, null) }
        account = a
        return a
    }

    private suspend fun channelFromHandle(handle: String): String? = runCatching {
        val h = if (handle.startsWith("@")) handle else "@$handle"
        val data = post("navigation/resolve_url", mapOf("url" to "$ORIGIN/$h"))
        str(get(find(data, "browseEndpoint"), "browseId"))?.takeIf { it.startsWith("UC") }
    }.getOrNull()

    // MARK: Feeds

    enum class Feed(val browseId: String, val title: String) {
        SUBSCRIPTIONS("FEsubscriptions", "Home"), HISTORY("FEhistory", "History"), WATCH_LATER("VLWL", "Watch later"), LIKED("VLLL", "Liked videos")
    }

    suspend fun feed(f: Feed): List<YTVideo> = videos(post("browse", mapOf("browseId" to f.browseId)))

    suspend fun channels(): List<YTChannel> {
        val data = post("guide")
        val out = mutableListOf<YTChannel>()
        fun walk(n: JsonElement?) {
            when (n) {
                is JsonArray -> n.forEach { walk(it) }
                is JsonObject -> {
                    val e = n["guideEntryRenderer"] as? JsonObject
                    val id = str(get(get(e, "navigationEndpoint"), "browseEndpoint")?.let { get(it, "browseId") })
                    if (e != null && id != null && id.startsWith("UC")) {
                        if (out.none { it.id == id }) {
                            out.add(YTChannel(id, text(e["formattedTitle"]), lastThumb(e["thumbnail"]), str(e["presentationStyle"]) == "GUIDE_ENTRY_PRESENTATION_STYLE_NEW_CONTENT"))
                        }
                    } else n.values.forEach { walk(it) }
                }
                else -> {}
            }
        }
        walk(find(data, "guideSubscriptionsSectionRenderer"))
        return out
    }

    suspend fun search(q: String): List<YTVideo> = videos(post("search", mapOf("query" to q, "params" to "EgIQAQ%3D%3D")))

    suspend fun channel(id: String): Pair<YTChannel, List<YTVideo>> {
        val data = post("browse", mapOf("browseId" to id, "params" to "EgZ2aWRlb3PyBgQKAjoA"))
        val meta = find(data, "channelMetadataRenderer")
        val header = find(data, "pageHeaderViewModel") ?: find(data, "c4TabbedHeaderRenderer")
        val name = str(get(meta, "title")) ?: text(get(header, "title"))
        val list = videos(data).map { it.copy(channel = it.channel.ifEmpty { name }, channelId = it.channelId ?: id) }
        return YTChannel(id, name, lastThumb(get(meta, "avatar")) ?: lastThumb(find(header, "avatar"))) to list
    }

    suspend fun video(id: String): YTVideoDetails {
        val data = post("next", mapOf("videoId" to id))
        val primary = find(data, "videoPrimaryInfoRenderer")
        val secondary = find(data, "videoSecondaryInfoRenderer")
        val owner = find(secondary, "videoOwnerRenderer")
        val subscribe = find(secondary, "subscribeButtonRenderer")
        return YTVideoDetails(
            id = id,
            title = text(get(primary, "title")),
            views = text(find(get(primary, "viewCount"), "viewCount")).ifEmpty { text(find(primary, "shortViewCount")) },
            published = text(get(primary, "relativeDateText")).ifEmpty { text(get(primary, "dateText")) },
            description = text(get(secondary, "attributedDescription")).ifEmpty { text(get(secondary, "description")) },
            channel = YTChannel(str(get(get(get(owner, "navigationEndpoint"), "browseEndpoint"), "browseId")) ?: "", text(get(owner, "title")), lastThumb(get(owner, "thumbnail"))),
            subscribers = text(get(owner, "subscriberCountText")),
            subscribed = (get(subscribe, "subscribed") as? JsonPrimitive)?.contentOrNull == "true",
            related = videos(find(data, "secondaryResults")).filter { it.id != id && !it.live },
            commentsToken = commentsStart(data),
        )
    }

    // MARK: Doing things

    suspend fun subscribe(channelId: String, on: Boolean) {
        if (on) post("subscription/subscribe", mapOf("channelIds" to listOf(channelId), "params" to "EgIIAhgA"))
        else post("subscription/unsubscribe", mapOf("channelIds" to listOf(channelId)))
    }

    suspend fun like(videoId: String) {
        post("like/like", mapOf("target" to mapOf("videoId" to videoId)))
    }

    suspend fun watchLater(videoId: String) {
        post("browse/edit_playlist", mapOf("playlistId" to "WL", "actions" to listOf(mapOf("addedVideoId" to videoId, "action" to "ACTION_ADD_VIDEO"))))
    }

    // MARK: Comments

    /** The comments section's first token, in a video's details. */
    private fun commentsStart(data: JsonElement?): String? {
        var token: String? = null
        fun walk(n: JsonElement?) {
            if (token != null) return
            when (n) {
                is JsonArray -> n.forEach { walk(it) }
                is JsonObject -> {
                    val s = n["itemSectionRenderer"] as? JsonObject
                    if (s != null && str(s["sectionIdentifier"]) == "comment-item-section") {
                        token = str(get(find(s, "continuationCommand"), "token"))
                        return
                    }
                    n.values.forEach { walk(it) }
                }
                else -> {}
            }
        }
        walk(data)
        return token
    }

    suspend fun comments(token: String): YTCommentsPage {
        val data = post("next", mapOf("continuation" to token))
        // The comments themselves live in "entity" updates, matched to the threads by key.
        val payloads = mutableMapOf<String, JsonObject>()
        (find(data, "mutations") as? JsonArray)?.forEach { m ->
            val p = get(get(m, "payload"), "commentEntityPayload") as? JsonObject ?: return@forEach
            str(get(m, "entityKey"))?.let { payloads[it] = p }
        }
        val out = mutableListOf<YTComment>()
        var more: String? = null
        var header: JsonElement? = null
        fun walk(n: JsonElement?) {
            when (n) {
                is JsonArray -> n.forEach { walk(it) }
                is JsonObject -> {
                    n["commentsHeaderRenderer"]?.let { header = it }
                    val thread = n["commentThreadRenderer"] as? JsonObject
                    if (thread != null) {
                        val view = get(get(thread, "commentViewModel"), "commentViewModel")
                        val key = str(get(view, "commentKey"))
                        val p = payloads[key]
                        if (p != null) out.add(commentFrom(p, pinned = get(view, "pinnedText") != null))
                        return
                    }
                    val cont = n["continuationItemRenderer"] as? JsonObject
                    if (cont != null) {
                        str(get(find(cont, "continuationCommand"), "token"))?.let { more = it }
                        return
                    }
                    n.values.forEach { walk(it) }
                }
                else -> {}
            }
        }
        walk(find(data, "onResponseReceivedEndpoints"))
        val sorts = find(header, "subMenuItems") as? JsonArray
        val newest = sorts?.getOrNull(1)?.let { str(get(find(it, "continuationCommand"), "token")) }
        return YTCommentsPage(out, more, newest, str(find(header, "createCommentParams")))
    }

    private fun commentFrom(p: JsonObject, pinned: Boolean): YTComment {
        val props = get(p, "properties")
        val author = get(p, "author")
        val toolbar = get(p, "toolbar")
        return YTComment(
            id = str(get(props, "commentId")) ?: "",
            author = str(get(author, "displayName")) ?: "",
            authorAvatar = str(get(author, "avatarThumbnailUrl")),
            authorChannelId = str(get(author, "channelId")),
            text = str(get(get(props, "content"), "content")) ?: "",
            published = str(get(props, "publishedTime")) ?: "",
            likes = str(get(toolbar, "likeCountNotliked"))?.trim() ?: "",
            replies = str(get(toolbar, "replyCount"))?.filter { it.isDigit() }?.toIntOrNull() ?: 0,
            pinned = pinned,
            byCreator = (get(author, "isCreator") as? JsonPrimitive)?.contentOrNull == "true",
        )
    }

    suspend fun postComment(params: String, text: String) {
        post("comment/create_comment", mapOf("commentText" to text, "createCommentParams" to params))
    }

    // MARK: Reading YouTube's answers

    private fun get(n: JsonElement?, key: String): JsonElement? = (n as? JsonObject)?.get(key)

    private fun str(n: JsonElement?): String? = (n as? JsonPrimitive)?.contentOrNull

    /** The first value under `key` anywhere in `n`. */
    private fun find(n: JsonElement?, key: String): JsonElement? = when (n) {
        is JsonObject -> n[key] ?: n.values.firstNotNullOfOrNull { find(it, key) }
        is JsonArray -> n.firstNotNullOfOrNull { find(it, key) }
        else -> null
    }

    private fun text(t: JsonElement?): String {
        str(t)?.let { return it }
        val o = t as? JsonObject ?: return ""
        str(o["simpleText"])?.let { return it }
        str(o["content"])?.let { return it }
        return (o["runs"] as? JsonArray)?.joinToString("") { str(get(it, "text")) ?: "" } ?: ""
    }

    private fun lastThumb(t: JsonElement?): String? {
        val list = (get(t, "thumbnails") ?: get(t, "sources") ?: get(get(t, "image"), "sources")) as? JsonArray ?: return null
        val url = str(get(list.lastOrNull(), "url")) ?: return null
        return if (url.startsWith("//")) "https:$url" else url
    }

    private fun seconds(s: String): Double? {
        val t = s.trim()
        if (!Regex("^\\d+(:\\d+)+$").matches(t)) return null
        return t.split(':').fold(0.0) { a, p -> a * 60 + p.toDouble() }
    }

    private fun browseIdOf(n: JsonElement?): String? = str(get(find(n, "browseEndpoint"), "browseId"))

    /** One video from any of the shapes YouTube uses (older renderers and the newer "lockup" view models). */
    private fun videoFrom(key: String, v: JsonObject): YTVideo? {
        if (key == "lockupViewModel") {
            val type = str(v["contentType"])
            if (type != null && type != "LOCKUP_CONTENT_TYPE_VIDEO") return null
            val id = str(v["contentId"]) ?: return null
            val meta = get(get(v, "metadata"), "lockupMetadataViewModel") ?: return null
            val rows = (get(get(get(meta, "metadata"), "contentMetadataViewModel"), "metadataRows") as? JsonArray).orEmpty()
            val parts = rows.map { r -> (get(r, "metadataParts") as? JsonArray).orEmpty().map { text(get(it, "text")) }.filter { it.isNotEmpty() } }
            val badges = mutableListOf<String>()
            fun badgesIn(n: JsonElement?) {
                when (n) {
                    is JsonArray -> n.forEach { badgesIn(it) }
                    is JsonObject -> {
                        (n["thumbnailBadgeViewModel"] as? JsonObject)?.let { badges.add(text(it["text"])) }
                        n.values.forEach { badgesIn(it) }
                    }
                    else -> {}
                }
            }
            badgesIn(v["contentImage"])
            val len = badges.firstOrNull { seconds(it) != null }
            return YTVideo(
                id = id,
                title = text(get(meta, "title")),
                channel = parts.getOrNull(0)?.getOrNull(0) ?: "",
                channelId = browseIdOf(get(meta, "image")) ?: browseIdOf(rows.firstOrNull()),
                thumbnail = lastThumb(find(v["contentImage"], "image")) ?: "https://i.ytimg.com/vi/$id/hqdefault.jpg",
                duration = len?.let { seconds(it) },
                views = parts.getOrNull(1)?.getOrNull(0) ?: "",
                published = parts.getOrNull(1)?.getOrNull(1) ?: "",
                live = badges.any { it.contains("live", ignoreCase = true) },
            )
        }
        val id = str(v["videoId"]) ?: return null
        val owner = v["ownerText"] ?: v["shortBylineText"] ?: v["longBylineText"]
        val lenText = text(v["lengthText"]).ifEmpty { text(get(find(v["thumbnailOverlays"], "thumbnailOverlayTimeStatusRenderer"), "text")) }
        return YTVideo(
            id = id,
            title = text(v["title"]).ifEmpty { text(v["headline"]) },
            channel = text(owner),
            channelId = browseIdOf(owner),
            thumbnail = lastThumb(v["thumbnail"]) ?: "https://i.ytimg.com/vi/$id/hqdefault.jpg",
            duration = seconds(lenText),
            views = text(v["shortViewCountText"]).ifEmpty { text(v["viewCountText"]) },
            published = text(v["publishedTimeText"]),
            live = (str(find(v["thumbnailOverlays"], "style")) ?: "").contains("LIVE"),
        )
    }

    private val videoKeys = setOf("videoRenderer", "gridVideoRenderer", "compactVideoRenderer", "playlistVideoRenderer", "lockupViewModel")
    private val shortsKeys = setOf("reelShelfRenderer", "shortsLockupViewModel", "reelItemRenderer")

    /** Every video in an answer, in order, once each (Shorts left out). */
    private fun videos(n: JsonElement?): List<YTVideo> {
        val out = mutableListOf<YTVideo>()
        val seen = mutableSetOf<String>()
        fun walk(x: JsonElement?) {
            when (x) {
                is JsonArray -> x.forEach { walk(it) }
                is JsonObject -> for ((k, v) in x) {
                    if (k in shortsKeys) continue
                    if (k in videoKeys && v is JsonObject) {
                        val video = videoFrom(k, v)
                        if (video != null && video.title.isNotEmpty() && seen.add(video.id)) out.add(video)
                        continue
                    }
                    walk(v)
                }
                else -> {}
            }
        }
        walk(n)
        return out
    }
}
