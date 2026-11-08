package com.lordxhobo.drift.social

import android.content.Context
import android.util.Base64
import com.lordxhobo.drift.data.CollabInfo
import com.lordxhobo.drift.data.Library
import com.lordxhobo.drift.data.Playlist
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
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File

/** Merging edits to a shared playlist: exactly the same rules as the iPhone and the computer. */
object CollabMerge {
    /**
     * `base`: the list as this device last saw it on the server; `local`: its copy now; `remote`: the
     * newest on the server. This device's changes (what differs between base and local) are applied
     * to remote, so two people editing at once both keep their changes.
     */
    fun mergeTracks(base: List<String>, local: List<Track>, remote: List<Track>, me: String): List<Track> {
        val baseSet = base.toSet()
        val localIds = local.map { it.id }.toSet()
        val removed = base.filter { it !in localIds }.toSet()
        val added = local.filter { it.id !in baseSet }

        // Songs removed here stay removed.
        var result = remote.filter { it.id !in removed }.toMutableList()

        // Moved here: the songs this device knew take its order, in the places they hold now.
        val commonLocal = local.filter { it.id in baseSet }.map { it.id }
        val commonBase = base.filter { it in localIds }
        if (commonLocal != commonBase) {
            val order = commonLocal.withIndex().associate { (i, id) -> id to i }
            val known = result.filter { it.id in order }.sortedBy { order.getValue(it.id) }
            var k = 0
            result = result.map { if (it.id in order) known[k++] else it }.toMutableList()
        }

        // Added here: after the song it follows here (or at the start), marked as added by this person.
        for (t in added) {
            if (result.any { it.id == t.id }) continue
            val i = local.indexOfFirst { it.id == t.id }
            val before = if (i > 0) local[i - 1].id else null
            val place = if (before == null) 0 else result.indexOfFirst { it.id == before }.let { if (it >= 0) it + 1 else result.size }
            result.add(place, t.copy(addedBy = t.addedBy ?: me))
        }
        return result
    }

    /** Renamed here wins, otherwise the server's name. */
    fun mergeName(baseName: String, localName: String, remoteName: String) = if (localName != baseName) localName else remoteName

    fun hasLocalChanges(base: List<String>, baseName: String, local: List<Track>, localName: String) =
        localName != baseName || base != local.map { it.id }
}

/**
 * Shared (collaborative) playlists: one document per playlist (collabs/{playlist id}) that every member
 * can change. Each device remembers the list as it last saw it there, so only its own changes are sent.
 */
object CollabSync {
    @Serializable
    private data class Base(val updateTime: String, val ids: List<String>, val name: String, val coverAt: Long = 0)

    @Serializable
    private data class State(val bases: Map<String, Base> = emptyMap(), val left: List<String> = emptyList())

    private class Remote(
        val id: String, val updateTime: String, val info: CollabInfo, val name: String, val colorIndex: Int,
        val tracks: List<Track>, val coverStyle: String?, val coverSymbol: String?, val cover: ByteArray?, val coverAt: Long,
    )

    private lateinit var file: File
    private val bases = mutableMapOf<String, Base>()
    /** Playlists left here (so they don't come back before the server has caught up). */
    private val left = mutableSetOf<String>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val mutex = Mutex()
    private var pending: Job? = null
    private val json = Json { ignoreUnknownKeys = true }

    fun init(context: Context) {
        file = File(context.filesDir, "collab-state.json")
        runCatching { json.decodeFromString(State.serializer(), file.readText()) }.getOrNull()?.let {
            bases.putAll(it.bases)
            left.addAll(it.left)
        }
        // Edits here go up a moment later; every 30 s, changes from the others come down.
        Library.onAnyChange.add { if (Library.playlists.any { it.collab != null }) schedule(2000) }
        scope.launch {
            delay(4000)
            while (true) {
                if (Social.me != null) syncNow()
                delay(30_000)
            }
        }
    }

    private fun save() {
        runCatching {
            val tmp = File(file.parentFile, "collab-state.json.tmp")
            tmp.writeText(json.encodeToString(State.serializer(), State(bases.toMap(), left.toList())))
            tmp.renameTo(file)
        }
    }

    fun schedule(ms: Long) {
        pending?.cancel()
        pending = scope.launch {
            delay(ms)
            syncNow()
        }
    }

    suspend fun syncNow() {
        mutex.withLock { runCatching { sync() } }
    }

    // MARK: Reading the server

    private fun parse(doc: JsonObject?): Remote? {
        doc ?: return null
        val f = FV.fields(doc)
        val id = FV.id(doc)
        val owner = FV.string(f, "owner") ?: return null
        val tracks = LibrarySync.decodeTracksPublic(FV.string(f, "tracks")) ?: return null
        val updateTime = FV.str(doc["updateTime"]) ?: return null
        val names = FV.mapFields(f, "names")?.mapNotNull { (k, v) ->
            FV.str((v as? JsonObject)?.get("stringValue"))?.let { k to it }
        }?.toMap().orEmpty()
        return Remote(
            id = id, updateTime = updateTime,
            info = CollabInfo(owner, FV.stringArray(f, "members"), names),
            name = FV.string(f, "name") ?: "Playlist",
            colorIndex = (FV.long(f, "colorIndex") ?: 0).toInt(),
            tracks = tracks,
            coverStyle = FV.string(f, "coverStyle")?.takeIf { it.isNotEmpty() },
            coverSymbol = FV.string(f, "coverSymbol")?.takeIf { it.isNotEmpty() },
            cover = FV.data(f, "cover"),
            coverAt = FV.long(f, "coverAt") ?: 0,
        )
    }

    private fun infoFields(info: CollabInfo): Map<String, JsonElement> = mapOf(
        "owner" to FV.s(info.owner),
        "members" to FV.strings(info.members),
        "names" to FV.map(info.names.mapValues { FV.s(it.value) }),
    )

    private fun myName(): String = Social.me?.name ?: "Someone"

    /** Takes the server's version as it is (nothing changed here). */
    private suspend fun adopt(r: Remote) {
        val old = bases[r.id]
        withContext(Dispatchers.Main) {
            val local = Library.playlist(r.id)
            val coverChanged = r.coverAt != 0L && (local == null || r.coverAt != old?.coverAt)
            val base = local ?: Playlist(id = r.id, name = r.name, colorIndex = r.colorIndex)
            var p = base.copy(name = r.name, tracks = r.tracks, collab = r.info)
            if (coverChanged) {
                // A cover set by someone (whoever changed it last wins).
                p = p.copy(
                    coverStyle = r.coverStyle ?: "auto", coverSymbol = r.coverSymbol, colorIndex = r.colorIndex,
                    cover64 = r.cover?.let { Base64.encodeToString(it, Base64.NO_WRAP) },
                )
            }
            Library.setCollabPlaylist(p)
        }
        bases[r.id] = Base(r.updateTime, r.tracks.map { it.id }, r.name, if (r.coverAt != 0L) r.coverAt else old?.coverAt ?: 0)
    }

    private suspend fun sync() {
        val uid = Social.me?.id ?: return
        val query = buildJsonObject {
            put("from", buildJsonArray { add(buildJsonObject { put("collectionId", "collabs") }) })
            put("where", buildJsonObject {
                put("fieldFilter", buildJsonObject {
                    put("field", buildJsonObject { put("fieldPath", "members") })
                    put("op", "ARRAY_CONTAINS")
                    put("value", FV.s(uid))
                })
            })
        }
        val remotes = withContext(Dispatchers.IO) { Firestore.query(query) }.mapNotNull { parse(it) }
        val seen = mutableSetOf<String>()
        for (r in remotes) {
            seen.add(r.id)
            if (r.id in left) continue
            val local = Library.playlist(r.id)
            val base = bases[r.id]
            if (local == null || base == null) {
                // New: invited, or made shared on another of your devices.
                adopt(r)
                continue
            }
            when {
                CollabMerge.hasLocalChanges(base.ids, base.name, local.tracks, local.name) -> send(r, local, base, uid)
                r.updateTime != base.updateTime -> adopt(r)
                local.collab != r.info -> withContext(Dispatchers.Main) { Library.setCollabPlaylist(local.copy(collab = r.info)) }
            }
        }
        // Shared playlists that are gone (stopped by their owner, or you were taken out).
        withContext(Dispatchers.Main) {
            for (p in Library.playlists.toList()) {
                val c = p.collab ?: continue
                if (p.id in seen) continue
                if (c.owner == uid) Library.setCollabPlaylist(p.copy(collab = null)) // yours: a normal playlist again
                else Library.removeRemotePlaylist(p.id)
                bases.remove(p.id)
            }
        }
        left.retainAll(seen)
        save()
    }

    /** Sends this device's changes, merged into the newest version (again if someone was quicker). */
    private suspend fun send(remote: Remote, local: Playlist, base: Base, uid: String) {
        var r = remote
        repeat(3) {
            val tracks = CollabMerge.mergeTracks(base.ids, local.tracks, r.tracks, uid)
            val name = CollabMerge.mergeName(base.name, local.name, r.name)
            val names = r.info.names + (uid to myName())
            val info = r.info.copy(names = names)
            try {
                val time = withContext(Dispatchers.IO) {
                    Firestore.patch(
                        "collabs/${r.id}",
                        mapOf(
                            "name" to FV.s(name),
                            "tracks" to FV.s(LibrarySync.tracksJSONPublic(tracks)),
                            "names" to infoFields(info).getValue("names"),
                            "updatedAt" to FV.i(System.currentTimeMillis()),
                            "updatedBy" to FV.s(uid),
                        ),
                        mask = listOf("name", "tracks", "names", "updatedAt", "updatedBy"),
                        updateTime = r.updateTime,
                    )
                }
                adopt(Remote(r.id, time ?: r.updateTime, info, name, r.colorIndex, tracks, r.coverStyle, r.coverSymbol, r.cover, r.coverAt))
                return
            } catch (e: ChangedMeanwhileException) {
                // Someone else changed it first: merge into their version instead.
                r = parse(withContext(Dispatchers.IO) { Firestore.get("collabs/${r.id}") }) ?: return
            }
        }
    }

    // MARK: Sharing, inviting, leaving

    /** Makes one of your playlists shared (you own it), or changes who's in it. */
    suspend fun share(id: String, people: List<UserProfile>) = mutex.withLock {
        val uid = Social.me?.id ?: throw IllegalStateException("Make a profile first, so friends can find you.")
        val p = Library.playlist(id) ?: return@withLock
        if (p.collab != null) {
            setMembersLocked(id, people, uid)
            return@withLock
        }
        val info = CollabInfo(uid, listOf(uid) + people.map { it.id }, mapOf(uid to myName()) + people.associate { it.id to it.name })
        val tracks = p.tracks.map { it.copy(addedBy = it.addedBy ?: uid) }
        val now = System.currentTimeMillis()
        val time = withContext(Dispatchers.IO) {
            Firestore.patch(
                "collabs/$id",
                infoFields(info) + mapOf(
                    "name" to FV.s(p.name),
                    "tracks" to FV.s(LibrarySync.tracksJSONPublic(tracks)),
                    "colorIndex" to FV.i(p.colorIndex.toLong()),
                    "createdAt" to FV.i(now), "updatedAt" to FV.i(now), "updatedBy" to FV.s(uid),
                ),
                mustNotExist = true,
            )
        }
        left.remove(id)
        withContext(Dispatchers.Main) { Library.setCollabPlaylist(p.copy(tracks = tracks, collab = info)) }
        bases[id] = Base(time ?: "", tracks.map { it.id }, p.name)
        save()
    }

    private suspend fun setMembersLocked(id: String, people: List<UserProfile>, uid: String) {
        val r = parse(withContext(Dispatchers.IO) { Firestore.get("collabs/$id") }) ?: return
        if (r.info.owner != uid) return
        val info = CollabInfo(uid, listOf(uid) + people.map { it.id }.filter { it != uid }, mapOf(uid to myName()) + people.associate { it.id to it.name })
        val time = withContext(Dispatchers.IO) {
            Firestore.patch("collabs/$id", infoFields(info), mask = listOf("owner", "members", "names"), updateTime = r.updateTime)
        }
        withContext(Dispatchers.Main) { Library.playlist(id)?.let { Library.setCollabPlaylist(it.copy(collab = info)) } }
        bases[id]?.let { b -> if (time != null) bases[id] = b.copy(updateTime = time) }
        save()
    }

    /** A member leaves (the playlist goes from their library). */
    suspend fun leave(id: String) = mutex.withLock {
        val uid = Social.me?.id ?: return@withLock
        val r = parse(withContext(Dispatchers.IO) { Firestore.get("collabs/$id") })
        if (r != null && r.info.owner != uid) {
            withContext(Dispatchers.IO) {
                Firestore.patch("collabs/$id", mapOf("members" to FV.strings(r.info.members - uid)), mask = listOf("members"), updateTime = r.updateTime)
            }
        }
        left.add(id)
        bases.remove(id)
        withContext(Dispatchers.Main) { Library.removeRemotePlaylist(id) }
        save()
    }

    /** The owner stops sharing: a normal playlist again (and gone from everyone else's library). */
    suspend fun stop(id: String) = mutex.withLock {
        withContext(Dispatchers.IO) { Firestore.delete("collabs/$id") }
        bases.remove(id)
        withContext(Dispatchers.Main) { Library.playlist(id)?.let { Library.setCollabPlaylist(it.copy(collab = null)) } }
        save()
    }
}
