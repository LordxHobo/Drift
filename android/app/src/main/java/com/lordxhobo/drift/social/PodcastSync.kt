package com.lordxhobo.drift.social

import com.lordxhobo.drift.data.Track
import com.lordxhobo.drift.podcasts.EpisodeProgress
import com.lordxhobo.drift.podcasts.PodcastChannel
import com.lordxhobo.drift.podcasts.PodcastStore
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
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement

/**
 * Keeps the shows you follow and where you are in each episode the same on all your devices, in one
 * document (users/{uid}/library/podcasts), the same as the iPhone's and the computer's:
 * - shows: the followed shows (JSON), with showsAt, when they last changed (the newest list wins);
 * - progress: episode id → where it was left (JSON), each episode's newest place winning.
 */
object PodcastSync {
    /** One episode's place, as stored: the episode, position and length (s), when (ms), finished. */
    @Serializable
    internal data class Entry(val t: Track, val p: Double, val d: Double, val u: Long, val f: Boolean = false)

    /** At most this many episodes' places are kept on the server (the most recent). */
    private const val KEEP = 300
    private const val PATH = "podcasts"

    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val mutex = Mutex()
    private var pending: Job? = null

    fun init() {
        // While Drift runs: changes from other devices, every 2 minutes.
        scope.launch {
            delay(8000)
            while (true) {
                if (Social.me != null) run()
                delay(120_000)
            }
        }
    }

    /**
     * Something changed here. A follow or a jump: sent in a moment. A place while playing: at most once a
     * minute (it changes every second).
     */
    fun changed(soon: Boolean) {
        if (Social.me == null) return
        if (!soon && pending?.isActive == true) return
        pending?.cancel()
        pending = scope.launch {
            delay(if (soon) 2000 else 60_000)
            run()
        }
    }

    /** Back in Drift, or leaving it. */
    fun syncNow() {
        scope.launch { run() }
    }

    private suspend fun run() = mutex.withLock {
        val uid = Social.me?.id ?: return@withLock
        runCatching { sync(uid) }
    }

    private data class Push(val shows: List<PodcastChannel>, val showsAt: Long, val progress: Map<String, Entry>)

    private suspend fun sync(uid: String) {
        val path = "users/$uid/library/$PATH"
        val f = withContext(Dispatchers.IO) { FV.fields(Firestore.get(path)) }
        val remoteShows = FV.string(f, "shows")?.let { s ->
            runCatching { json.decodeFromString(ListSerializer(PodcastChannel.serializer()), s) }.getOrNull()
        }
        val remoteShowsAt = FV.long(f, "showsAt") ?: 0
        val remoteProgress = FV.string(f, "progress")?.let { s ->
            runCatching { json.decodeFromString(MapSerializer(String.serializer(), Entry.serializer()), s) }.getOrNull()
        }.orEmpty()

        val push = merge(uid, remoteShows, remoteShowsAt, remoteProgress) ?: return
        val fields: Map<String, JsonElement> = mapOf(
            "shows" to FV.s(json.encodeToString(ListSerializer(PodcastChannel.serializer()), push.shows)),
            "showsAt" to FV.i(push.showsAt),
            "progress" to FV.s(json.encodeToString(MapSerializer(String.serializer(), Entry.serializer()), push.progress)),
            "updatedAt" to FV.i(System.currentTimeMillis()),
            "deleted" to FV.b(false),
        )
        withContext(Dispatchers.IO) { Firestore.patch(path, fields) }
    }

    /** Brings the other devices' changes here; returns what to send when the server is missing something. */
    private fun merge(uid: String, remoteShows: List<PodcastChannel>?, remoteShowsAt: Long, remote: Map<String, Entry>): Push? {
        val store = PodcastStore
        val now = System.currentTimeMillis()
        val firstTime = store.syncedUid != uid
        val local = store.subscriptions
        var shows = local
        var showsAt = store.showsChanged
        var sendShows = false
        when {
            remoteShows == null -> {
                sendShows = local.isNotEmpty() || showsAt > 0
                if (showsAt == 0L) showsAt = now
            }
            firstTime -> {
                // First sync on this phone: both (the profile's first, then any followed only here).
                val ids = remoteShows.map { it.id }.toSet()
                val extra = local.filter { it.id !in ids }
                shows = remoteShows + extra
                sendShows = extra.isNotEmpty()
                showsAt = if (sendShows) now else remoteShowsAt
            }
            remoteShowsAt > showsAt -> {
                shows = remoteShows
                showsAt = remoteShowsAt
            }
            showsAt > remoteShowsAt -> sendShows = true
        }
        if (shows != local || showsAt != store.showsChanged) store.adoptShows(shows, showsAt)

        // Each episode: the newest place wins.
        val mine = store.progress
        val newer = remote.filter { (id, e) -> (mine[id]?.updated ?: -1) < e.u }
        store.adoptProgress(newer.mapValues { (_, e) -> EpisodeProgress(e.t, e.p, e.d, e.u, e.f) })
        val all = HashMap(remote)
        for ((id, p) in mine) {
            val r = all[id]
            if (r == null || r.u < p.updated) all[id] = Entry(p.track, p.position, p.duration, p.updated, p.finished)
        }
        val kept = all.entries.sortedByDescending { it.value.u }.take(KEEP).associate { it.key to it.value }
        val sendProgress = kept.mapValues { it.value.u } != remote.mapValues { it.value.u }
        store.markSynced(uid)

        if (!sendShows && !sendProgress) return null
        return Push(shows, showsAt, kept)
    }
}
