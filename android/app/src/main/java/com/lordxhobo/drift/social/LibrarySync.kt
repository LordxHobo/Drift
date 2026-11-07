package com.lordxhobo.drift.social

import android.content.Context
import android.util.Base64
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.lordxhobo.drift.data.Library
import com.lordxhobo.drift.data.Playlist
import com.lordxhobo.drift.data.PlaylistFolder
import com.lordxhobo.drift.data.Track
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import java.io.File

/**
 * Keeps playlists and liked songs in step with the profile's other devices, in the same format as the
 * iPhone and the computer: one document per item in users/{uid}/library (liked, pl-<id>), each with an
 * updatedAt time (ms). Pull what's newer, push what changed here, mark deleted playlists.
 *
 * Also folders and followed artists (kept whole, so the new-release details the other apps keep survive).
 */
object LibrarySync {
    @Serializable
    private data class Synced(val fingerprint: String, val updatedAt: Long)

    @Serializable
    private data class State(val uid: String = "", val synced: Map<String, Synced> = emptyMap())

    var syncing by mutableStateOf(false)
        private set
    var lastSync by mutableStateOf<Long?>(null)
        private set
    var error by mutableStateOf<String?>(null)
        private set

    private lateinit var dir: File
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val mutex = Mutex()
    private val json = Json { ignoreUnknownKeys = true }
    private var state = State()
    private var synced = mutableMapOf<String, Synced>()

    /**
     * Each song as another device last sent it, by video ID. Songs can carry details Android doesn't use
     * (a chosen version, podcast info…): they're merged back in when sending, so nothing gets dropped.
     */
    private var rawTracks = mutableMapOf<String, JsonObject>()
    private var pending: Job? = null
    private var lastPull = 0L

    fun init(context: Context) {
        dir = context.filesDir
        Library.onLocalChange = { schedule(3000) }
        // While Drift runs: look for changes from other devices every 2 minutes.
        scope.launch {
            while (true) {
                delay(120_000)
                if (Social.me != null) syncNow(pull = true)
            }
        }
    }

    private fun schedule(ms: Long) {
        if (Social.me == null) return
        pending?.cancel()
        pending = scope.launch {
            delay(ms)
            syncNow(pull = System.currentTimeMillis() - lastPull > 60_000)
        }
    }

    /** Pull (when asked, or on the first run) and push. Safe to call any time. */
    fun syncNow(pull: Boolean = true) {
        scope.launch { run(pull) }
    }

    /** The profile was deleted or replaced: forget what was synced (the library on this phone stays). */
    fun forget() {
        state = State()
        synced = mutableMapOf()
        rawTracks = mutableMapOf()
        lastSync = null
        error = null
        runCatching { File(dir, "sync-state.json").delete() }
        runCatching { File(dir, "sync-tracks.json").delete() }
    }

    private suspend fun run(pull: Boolean) = mutex.withLock {
        val uid = Social.me?.id ?: return@withLock
        syncing = true
        try {
            withContext(Dispatchers.IO) {
                load(uid)
                if (pull || lastPull == 0L) {
                    pullChanges(uid)
                    lastPull = System.currentTimeMillis()
                }
                pushChanges(uid)
            }
            lastSync = System.currentTimeMillis()
            error = null
        } catch (e: SocialException) {
            error = if (e.status == 403) "Drift's server refused the sync. The security rules may need publishing again." else e.message
        } catch (e: Exception) {
            error = "Couldn't sync. Check your connection."
        }
        syncing = false
    }

    // MARK: State

    private fun load(uid: String) {
        if (state.uid == uid) return
        val s = runCatching { json.decodeFromString(State.serializer(), File(dir, "sync-state.json").readText()) }.getOrNull()
        state = if (s?.uid == uid) s else State(uid)
        synced = state.synced.toMutableMap()
        rawTracks = runCatching {
            (Json.parseToJsonElement(File(dir, "sync-tracks.json").readText()) as JsonObject)
                .mapValues { it.value as JsonObject }.toMutableMap()
        }.getOrNull() ?: mutableMapOf()
    }

    private fun save() {
        state = State(state.uid, synced.toMap())
        writeAtomic("sync-state.json", json.encodeToString(State.serializer(), state))
        writeAtomic("sync-tracks.json", JsonObject(rawTracks).toString())
    }

    private fun writeAtomic(name: String, text: String) {
        runCatching {
            val tmp = File(dir, "$name.tmp")
            tmp.writeText(text)
            tmp.renameTo(File(dir, name))
        }
    }

    // MARK: Fingerprints (what was last sent, to know what changed)

    private fun hash(s: String): String {
        var h = -0x340d631b7bdddcdbL // FNV-1a offset basis
        for (b in s.toByteArray()) {
            h = h xor (b.toLong() and 0xff)
            h *= 0x100000001b3L
        }
        return java.lang.Long.toUnsignedString(h, 16)
    }

    private fun playlistFingerprint(p: Playlist, position: Int): String = hash(
        listOf(
            position, p.name, p.coverStyle ?: "auto", p.colorIndex, p.coverSymbol ?: "",
            p.cover64?.let { "${it.length}:${it.takeLast(16)}" } ?: "",
            p.isPublic ?: true, p.isAlbum == true, p.albumArtist ?: "", p.folder ?: "",
        ).joinToString("|") + "|" + p.tracks.joinToString(",") { it.id },
    )

    private fun foldersFingerprint() = hash(Library.folders.joinToString(",") { "${it.id}:${it.name}" })
    private fun artistsFingerprint() = hash(Library.followed.joinToString(",") { it.url })

    private fun currentFingerprint(name: String): String? {
        if (name == "liked") return hash(Library.liked.joinToString(",") { it.id })
        if (name == "folders") return foldersFingerprint()
        if (name == "artists") return artistsFingerprint()
        val i = Library.playlists.indexOfFirst { "pl-${it.id}" == name }
        return if (i >= 0) playlistFingerprint(Library.playlists[i], i) else null
    }

    // MARK: Songs as JSON

    private fun decodeTracks(s: String?): List<Track>? {
        if (s.isNullOrEmpty()) return null
        val list = runCatching { Json.parseToJsonElement(s) as JsonArray }.getOrNull() ?: return null
        return list.mapNotNull { e ->
            val o = e as? JsonObject ?: return@mapNotNull null
            // A song with fields this app doesn't know is still kept (with what can be read), never dropped.
            val t = runCatching { Library.json.decodeFromJsonElement(Track.serializer(), o) }.getOrNull()
                ?: Track(
                    id = (o["id"] as? JsonPrimitive)?.contentOrNull ?: return@mapNotNull null,
                    title = (o["title"] as? JsonPrimitive)?.contentOrNull ?: "",
                    artist = (o["artist"] as? JsonPrimitive)?.contentOrNull ?: "",
                )
            rawTracks[t.id] = o
            t
        }
    }

    /** Songs as JSON text, each merged over what other devices sent for it; huge lists drop artwork links. */
    private fun tracksJSON(tracks: List<Track>): String {
        fun encode(t: Track, art: Boolean): JsonObject {
            val raw = rawTracks[t.id] ?: JsonObject(emptyMap())
            // Empty text never replaces what another device sent (a song this app could only partly read).
            val mine = (Library.json.encodeToJsonElement(Track.serializer(), t) as JsonObject)
                .filterNot { (k, v) -> v is JsonPrimitive && v.isString && v.content.isEmpty() && k in raw }
            val merged = raw + mine
            return JsonObject(if (art) merged else merged - "artworkURL" - "channelAvatar")
        }
        val full = JsonArray(tracks.map { encode(it, true) }).toString()
        if (full.toByteArray().size < 850_000) return full
        return JsonArray(tracks.map { encode(it, false) }).toString()
    }

    // MARK: Pull

    private suspend fun pullChanges(uid: String) {
        val docs = Firestore.list("users/$uid/library", listOf("updatedAt", "deleted"))
        for ((name, f) in docs) {
            // Listening history, devices and remote control are for the other apps.
            if (name != "liked" && name != "folders" && name != "artists" && !name.startsWith("pl-")) continue
            val updatedAt = FV.long(f, "updatedAt") ?: 0
            val known = synced[name]
            if (known != null && known.updatedAt >= updatedAt) continue
            if (FV.bool(f, "deleted") == true) {
                if (name.startsWith("pl-")) withContext(Dispatchers.Main) { Library.removeRemotePlaylist(name.removePrefix("pl-")) }
                synced[name] = Synced("deleted", updatedAt)
                continue
            }
            val full = FV.fields(Firestore.get("users/$uid/library/$name")) ?: continue
            val remote = withContext(Dispatchers.Main) { apply(name, full) }
            // What the profile now holds: if this phone added to it (songs liked only here), it differs
            // from the library and gets sent.
            synced[name] = Synced(remote ?: currentFingerprint(name) ?: "", updatedAt)
        }
        save()
    }

    /** Applies a document; returns the fingerprint of what the profile holds when it differs from here. */
    private fun apply(name: String, f: JsonObject): String? {
        if (name == "liked") {
            val remote = decodeTracks(FV.string(f, "tracks")) ?: return null
            if (synced["liked"] == null) {
                // First sync on this phone: keep both (the profile's first, then anything only liked here).
                val ids = remote.map { it.id }.toSet()
                Library.replaceLiked(remote + Library.liked.filterNot { it.id in ids })
            } else {
                Library.replaceLiked(remote)
            }
            return hash(remote.joinToString(",") { it.id })
        }
        if (name == "folders") {
            val remote = runCatching {
                Library.json.decodeFromString(ListSerializer(PlaylistFolder.serializer()), FV.string(f, "folders") ?: "")
            }.getOrNull() ?: return null
            if (synced["folders"] == null) {
                val ids = remote.map { it.id }.toSet()
                Library.replaceFolders(remote + Library.folders.filterNot { it.id in ids })
            } else {
                Library.replaceFolders(remote)
            }
            return hash(remote.joinToString(",") { "${it.id}:${it.name}" })
        }
        if (name == "artists") {
            val remote = runCatching { Json.parseToJsonElement(FV.string(f, "artists") ?: "") as JsonArray }.getOrNull()
                ?.mapNotNull { it as? JsonObject }?.filter { Library.artistRef(it) != null } ?: return null
            val ids = remote.mapNotNull { Library.artistRef(it)?.url }
            if (synced["artists"] == null) {
                Library.replaceArtists(remote + Library.artists.filterNot { Library.artistRef(it)?.url in ids })
            } else {
                Library.replaceArtists(remote)
            }
            return hash(ids.joinToString(","))
        }
        val title = FV.string(f, "name") ?: return null
        val tracks = decodeTracks(FV.string(f, "tracks")) ?: return null
        val style = FV.string(f, "style")
        val p = Playlist(
            id = name.removePrefix("pl-"),
            name = title,
            tracks = tracks,
            colorIndex = (FV.long(f, "colorIndex") ?: 0).toInt(),
            coverStyle = style?.takeIf { it == "auto" || it == "color" || it == "photo" },
            coverSymbol = FV.string(f, "symbol"),
            isPublic = FV.bool(f, "isPublic"),
            isAlbum = if (FV.bool(f, "isAlbum") == true) true else null,
            albumArtist = FV.string(f, "albumArtist"),
            folder = FV.string(f, "folder")?.takeIf { it.isNotEmpty() },
            cover64 = FV.data(f, "cover")?.let { Base64.encodeToString(it, Base64.NO_WRAP) },
        )
        Library.applyRemotePlaylist(p, (FV.long(f, "position") ?: 0).toInt())
        return null
    }

    // MARK: Push

    private fun documentFields(name: String, updatedAt: Long): Map<String, JsonElement>? {
        val f = mutableMapOf("updatedAt" to FV.i(updatedAt), "deleted" to FV.b(false))
        if (name == "liked") {
            f["tracks"] = FV.s(tracksJSON(Library.liked))
            return f
        }
        if (name == "folders") {
            f["folders"] = FV.s(Library.json.encodeToString(ListSerializer(PlaylistFolder.serializer()), Library.folders))
            return f
        }
        if (name == "artists") {
            f["artists"] = FV.s(JsonArray(Library.artists).toString())
            return f
        }
        val all = Library.playlists
        val i = all.indexOfFirst { "pl-${it.id}" == name }
        if (i < 0) return null
        val p = all[i]
        f["name"] = FV.s(p.name)
        f["position"] = FV.i(i.toLong())
        f["tracks"] = FV.s(tracksJSON(p.tracks))
        f["style"] = FV.s(p.coverStyle ?: "auto")
        f["colorIndex"] = FV.i(p.colorIndex.toLong())
        f["symbol"] = FV.s(p.coverSymbol ?: "music.note.list")
        f["isPublic"] = FV.b(p.isPublic ?: true)
        f["isAlbum"] = FV.b(p.isAlbum == true)
        p.albumArtist?.let { f["albumArtist"] = FV.s(it) }
        f["folder"] = FV.s(p.folder ?: "")
        p.cover64?.let { c ->
            val bytes = runCatching { Base64.decode(c, Base64.DEFAULT) }.getOrNull()
            if (bytes != null && bytes.size < 270_000) f["cover"] = FV.bytes(bytes)
        }
        return f
    }

    private fun pushChanges(uid: String) {
        val now = System.currentTimeMillis()
        val items = mutableListOf(
            "liked" to hash(Library.liked.joinToString(",") { it.id }),
            "folders" to foldersFingerprint(),
            "artists" to artistsFingerprint(),
        )
        Library.playlists.forEachIndexed { i, p -> items.add("pl-${p.id}" to playlistFingerprint(p, i)) }

        for ((name, fp) in items) {
            if (synced[name]?.fingerprint == fp) continue
            val fields = documentFields(name, now) ?: continue
            Firestore.patch("users/$uid/library/$name", fields)
            synced[name] = Synced(fp, now)
            save()
        }

        // Playlists deleted here: leave a marker so the other devices delete them too.
        val present = Library.playlists.map { "pl-${it.id}" }.toSet()
        for ((name, s) in synced.toMap()) {
            if (!name.startsWith("pl-") || name in present || s.fingerprint == "deleted") continue
            Firestore.patch("users/$uid/library/$name", mapOf("deleted" to FV.b(true), "updatedAt" to FV.i(now)), mask = listOf("deleted", "updatedAt"))
            synced[name] = Synced("deleted", now)
            save()
        }
    }

    /** Deletes the profile's whole synced library (when deleting the profile). */
    fun removeAll(uid: String) {
        for (name in Firestore.listNames("users/$uid/library")) Firestore.delete("users/$uid/library/$name")
    }
}
