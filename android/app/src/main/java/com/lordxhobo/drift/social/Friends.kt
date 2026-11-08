package com.lordxhobo.drift.social

import android.util.Base64
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.lordxhobo.drift.data.Library
import com.lordxhobo.drift.data.Playlist
import com.lordxhobo.drift.data.Track
import com.lordxhobo.drift.playback.Playback
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** A playlist someone shows on their profile, as others see it (users/{uid}/playlists/{id}). */
data class SharedPlaylist(
    val id: String,
    val ownerId: String,
    val ownerName: String,
    val name: String,
    val position: Int,
    val count: Int,
    val duration: Int,
    val colorIndex: Int,
    /** First songs, for the cover. */
    val preview: List<Track>,
) {
    val subtitle: String
        get() {
            val songs = "$count ${if (count == 1) "song" else "songs"}"
            if (duration <= 0) return songs
            val h = duration / 3600
            val m = (duration % 3600) / 60
            return songs + " · " + if (h > 0) "$h h $m min" else "$m min"
        }
}

/** Songs stored compactly as one JSON text, the same as the iPhone's (keeps big playlists small). */
object SharedTracks {
    @Serializable
    private data class T(val i: String, val t: String, val a: String, val d: Int? = null, val w: String? = null, val p: Boolean? = null)

    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    fun encode(tracks: List<Track>, artwork: Boolean = true): String =
        json.encodeToString(ListSerializer(T.serializer()), tracks.map { T(it.id, it.title, it.artist, it.duration?.toInt(), if (artwork) it.artworkURL else null) })

    fun decode(s: String?): List<Track> {
        if (s.isNullOrEmpty()) return emptyList()
        return runCatching { json.decodeFromString(ListSerializer(T.serializer()), s) }.getOrNull().orEmpty()
            .map { Track(id = it.i, title = it.t, artist = it.a, duration = it.d?.toDouble(), artworkURL = it.w) }
    }
}

/**
 * Friends: following people, what they're listening to, and the playlists they show. Your own listening
 * is shared the same way (unless turned off), and your playlists are shown on your profile. Same
 * Firestore documents as the iPhone and the computer.
 */
object Friends {
    /** Everyone you follow: listening now first, then most recent. */
    var friends by mutableStateOf(listOf<UserProfile>())
        private set
    var loading by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)
        private set

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    fun init() {
        Playback.onChange.add { t, playing -> playerChanged(t, playing) }
    }

    // MARK: Reading

    private fun profiles(docs: List<JsonObject>) = docs.mapNotNull { UserProfile.from(it) }

    suspend fun refresh() {
        if (Social.me == null) return
        loading = true
        try {
            val mine = Social.reload()
            val ids = mine?.following.orEmpty()
            val list = withContext(Dispatchers.IO) { profiles(Firestore.batchGet(ids.map { "users/$it" })) }
            friends = list.sortedWith(compareByDescending<UserProfile> { it.listeningNow }.thenByDescending { it.updatedAt ?: 0 })
            error = null
        } catch (e: Exception) {
            error = "Couldn't load your friends. Check your connection."
        }
        loading = false
    }

    suspend fun user(id: String): UserProfile? = withContext(Dispatchers.IO) {
        runCatching { Firestore.get("users/$id")?.let { UserProfile.from(it) } }.getOrNull()
    }

    suspend fun followers(id: String): List<UserProfile> = withContext(Dispatchers.IO) {
        val q = buildJsonObject {
            put("from", buildJsonArray { add(buildJsonObject { put("collectionId", "users") }) })
            put("where", buildJsonObject {
                put("fieldFilter", buildJsonObject {
                    put("field", buildJsonObject { put("fieldPath", "following") })
                    put("op", "ARRAY_CONTAINS")
                    put("value", FV.s(id))
                })
            })
            put("limit", 200)
        }
        runCatching { profiles(Firestore.query(q)) }.getOrDefault(emptyList())
    }

    /** People whose username or name starts with what was typed. */
    suspend fun search(text: String): List<UserProfile> = withContext(Dispatchers.IO) {
        fun prefix(field: String, q: String): List<JsonObject> {
            val query = buildJsonObject {
                put("from", buildJsonArray { add(buildJsonObject { put("collectionId", "users") }) })
                put("where", buildJsonObject {
                    put("compositeFilter", buildJsonObject {
                        put("op", "AND")
                        put("filters", buildJsonArray {
                            add(rangeFilter(field, "GREATER_THAN_OR_EQUAL", q))
                            add(rangeFilter(field, "LESS_THAN", q + ""))
                        })
                    })
                })
                put("orderBy", buildJsonArray { add(buildJsonObject { put("field", buildJsonObject { put("fieldPath", field) }) }) })
                put("limit", 20)
            }
            return runCatching { Firestore.query(query) }.getOrDefault(emptyList())
        }
        val handle = text.lowercase().filter { it in 'a'..'z' || it in '0'..'9' || it == '_' || it == '.' }
        val display = Social.searchKey(text.trim())
        if (handle.isEmpty() && display.isEmpty()) return@withContext emptyList()
        coroutineScope {
            val a = async { if (handle.isNotEmpty()) prefix("usernameLower", handle) else emptyList() }
            val b = async { if (display.isNotEmpty()) prefix("displayNameLower", display) else emptyList() }
            val me = Social.me?.id
            profiles(a.await() + b.await()).filter { it.id != me }.distinctBy { it.id }
        }
    }

    private fun rangeFilter(field: String, op: String, value: String): JsonElement = buildJsonObject {
        put("fieldFilter", buildJsonObject {
            put("field", buildJsonObject { put("fieldPath", field) })
            put("op", op)
            put("value", FV.s(value))
        })
    }

    // MARK: Following

    fun isFollowing(id: String): Boolean = Social.me?.following?.contains(id) == true

    suspend fun follow(id: String, on: Boolean) {
        val me = Social.me ?: return
        if (id == me.id) return
        // Start from the latest list, so a follow made on another device meanwhile isn't lost.
        val latest = Social.reload() ?: me
        val list = latest.following.filter { it != id } + if (on) listOf(id) else emptyList()
        withContext(Dispatchers.IO) {
            Firestore.patch("users/${me.id}", mapOf("following" to FV.strings(list)), mask = listOf("following"))
        }
        Social.updateMe { it.copy(following = list) }
        if (!on) friends = friends.filter { it.id != id }
        scope.launch { refresh() }
    }

    // MARK: Your activity

    private var lastPublished: String? = null
    private var publishJob: Job? = null

    suspend fun setShareActivity(on: Boolean) {
        val me = Social.me ?: return
        withContext(Dispatchers.IO) {
            Firestore.patch("users/${me.id}", mapOf("shareActivity" to FV.b(on)), mask = listOf("shareActivity"))
        }
        Social.updateMe { it.copy(shareActivity = on) }
        lastPublished = null
        playerChanged(lastTrack, lastPlaying)
    }

    suspend fun setAllowInvites(on: Boolean) {
        val me = Social.me ?: return
        withContext(Dispatchers.IO) {
            Firestore.patch("users/${me.id}", mapOf("allowInvites" to FV.b(on)), mask = listOf("allowInvites"))
        }
        Social.updateMe { it.copy(allowInvites = on) }
    }

    private var lastTrack: Track? = null
    private var lastPlaying = false

    /** The player changed song or paused: tell friends (a moment later, once it settles). */
    fun playerChanged(track: Track?, playing: Boolean) {
        lastTrack = track
        lastPlaying = playing
        publishJob?.cancel()
        publishJob = scope.launch {
            delay(1500)
            publish(track, playing)
        }
    }

    private suspend fun publish(track: Track?, playing: Boolean) {
        val me = Social.me ?: return
        val hidden = !me.shareActivity
        val t = if (hidden) null else track
        val isPlaying = !hidden && playing && t != null
        val signature = "${t?.id ?: "-"}|$isPlaying|$hidden"
        if (signature == lastPublished) return
        val fields = mutableMapOf("playing" to FV.b(isPlaying), "updatedAt" to FV.i(System.currentTimeMillis() / 1000))
        val mask = mutableListOf("playing", "updatedAt")
        if (hidden) {
            fields["nowPlaying"] = FV.nul
            mask.add("nowPlaying")
        } else if (t != null) {
            val np = mutableMapOf(
                "id" to FV.s(t.id), "title" to FV.s(t.title), "artist" to FV.s(t.artist), "podcast" to FV.b(false),
                "artwork" to FV.s(t.artworkURL ?: "https://i.ytimg.com/vi/${t.id}/hqdefault.jpg"),
            )
            t.duration?.let { np["duration"] = FV.i(it.toLong()) }
            fields["nowPlaying"] = FV.map(np)
            mask.add("nowPlaying")
        }
        val ok = withContext(Dispatchers.IO) {
            runCatching { Firestore.patch("users/${me.id}", fields, mask = mask) }.isSuccess
        }
        if (ok) lastPublished = signature
    }

    // MARK: Playlists on profiles

    suspend fun sharedPlaylists(u: UserProfile): List<SharedPlaylist> = withContext(Dispatchers.IO) {
        val docs = Firestore.list("users/${u.id}/playlists", listOf("name", "position", "count", "duration", "colorIndex", "preview"))
        docs.mapNotNull { (id, f) ->
            val name = FV.string(f, "name") ?: return@mapNotNull null
            SharedPlaylist(
                id = id, ownerId = u.id, ownerName = u.name, name = name,
                position = (FV.long(f, "position") ?: 0).toInt(),
                count = (FV.long(f, "count") ?: 0).toInt(),
                duration = (FV.long(f, "duration") ?: 0).toInt(),
                colorIndex = (FV.long(f, "colorIndex") ?: 0).toInt(),
                preview = SharedTracks.decode(FV.string(f, "preview")),
            )
        }.sortedBy { it.position }
    }

    suspend fun sharedTracks(ownerId: String, id: String): List<Track> = withContext(Dispatchers.IO) {
        SharedTracks.decode(FV.string(FV.fields(Firestore.get("users/$ownerId/playlists/$id")), "tracks"))
    }
}

/**
 * Keeps the playlists you show on your profile (all but the ones made private) up to date on the
 * server, like the iPhone. Friends see them on your profile.
 */
object PlaylistSharing {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var pending: Job? = null
    private var reconciled = false
    /** Playlist ID → fingerprint of what was last uploaded (this launch; checked against the server). */
    private val done = mutableMapOf<String, String>()

    fun init() {
        Library.onAnyChange.add { schedule(3000) }
    }

    fun profileReady() {
        reconciled = false
        done.clear()
        schedule(1000)
    }

    private fun schedule(ms: Long) {
        if (Social.me == null) return
        pending?.cancel()
        pending = scope.launch {
            delay(ms)
            withContext(Dispatchers.IO) { runCatching { sync() } }
        }
    }

    private fun isShared(p: Playlist) = p.isPublic ?: true

    private fun fingerprint(p: Playlist, position: Int): String =
        "$position|${p.name}|${p.coverStyle ?: "auto"}|${p.colorIndex}|${p.coverSymbol ?: ""}|${p.cover64?.length ?: 0}|" + p.tracks.joinToString(",") { it.id }

    private fun sync() {
        val uid = Social.me?.id ?: return
        val shown = Library.playlists.filter { isShared(it) }
        val wanted = shown.map { it.id }.toSet()
        if (!reconciled) {
            val remote = Firestore.listNames("users/$uid/playlists").toSet()
            // Shown before but made private or deleted while Drift was closed.
            for (id in remote - wanted) Firestore.delete("users/$uid/playlists/$id")
            reconciled = true
        }
        shown.forEachIndexed { position, p ->
            val sig = fingerprint(p, position)
            if (done[p.id] == sig) return@forEachIndexed
            Firestore.patch("users/$uid/playlists/${p.id}", fields(p, position))
            done[p.id] = sig
        }
        for (id in done.keys.toList()) {
            if (id !in wanted) {
                Firestore.delete("users/$uid/playlists/$id")
                done.remove(id)
            }
        }
    }

    private fun fields(p: Playlist, position: Int): Map<String, JsonElement> {
        val limit = 850_000
        var list = p.tracks
        var json = SharedTracks.encode(list)
        if (json.toByteArray().size > limit) json = SharedTracks.encode(list, artwork = false)
        while (json.toByteArray().size > limit && list.size > 100) {
            list = list.take(list.size * 3 / 4)
            json = SharedTracks.encode(list, artwork = false)
        }
        val total = p.tracks.sumOf { it.duration ?: 0.0 }.toLong()
        val f = mutableMapOf(
            "name" to FV.s(p.name),
            "position" to FV.i(position.toLong()),
            "count" to FV.i(list.size.toLong()),
            "duration" to FV.i(total),
            "style" to FV.s(p.coverStyle ?: "auto"),
            "colorIndex" to FV.i(p.colorIndex.toLong()),
            "symbol" to FV.s(p.coverSymbol ?: "music.note.list"),
            "preview" to FV.s(SharedTracks.encode(p.tracks.take(4))),
            "tracks" to FV.s(json),
            "updatedAt" to FV.i(System.currentTimeMillis() / 1000),
        )
        val cover = p.cover64?.takeIf { p.coverStyle == "photo" }?.let { runCatching { Base64.decode(it, Base64.DEFAULT) }.getOrNull() }
        f["cover"] = if (cover != null && cover.size < 270_000) FV.bytes(cover) else FV.nul
        return f
    }

    /** Profile deleted: its playlists go too. */
    fun removeAll(uid: String) {
        for (id in Firestore.listNames("users/$uid/playlists")) Firestore.delete("users/$uid/playlists/$id")
        done.clear()
    }
}
