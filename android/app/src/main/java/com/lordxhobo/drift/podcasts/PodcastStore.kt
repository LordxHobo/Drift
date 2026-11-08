package com.lordxhobo.drift.podcasts

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.lordxhobo.drift.data.Track
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File

/** A show: a YouTube channel or podcast playlist, or a show with its own feed. Same as the iPhone's and the computer's. */
@Serializable
data class PodcastChannel(
    val id: String,
    val name: String,
    val avatarURL: String? = null,
    val subtitle: String? = null,
    /** A show from its feed (RSS) rather than YouTube. */
    val feedURL: String? = null,
) {
    val isFeed: Boolean get() = feedURL != null
    /** One YouTube podcast (a playlist) rather than a whole channel: square cover, not round. */
    val squareCover: Boolean get() = isFeed || id.startsWith("PL") || id.startsWith("VL")
}

/** Where an episode was left off. */
@Serializable
data class EpisodeProgress(
    val track: Track,
    /** Seconds. */
    val position: Double,
    val duration: Double,
    /** ms since 1970. */
    val updated: Long,
    val finished: Boolean,
)

/**
 * Followed shows, their latest episodes and where each episode was left off. Kept on this phone (like the
 * iPhone's and the computer's, podcasts aren't synced between devices).
 */
object PodcastStore {
    @Serializable
    private data class Stored(
        val subscriptions: List<PodcastChannel> = emptyList(),
        val progress: Map<String, EpisodeProgress> = emptyMap(),
        val feeds: Map<String, List<Track>> = emptyMap(),
        val feedsUpdated: Long? = null,
    )

    var subscriptions by mutableStateOf(listOf<PodcastChannel>())
        private set
    var progress by mutableStateOf(mapOf<String, EpisodeProgress>())
        private set
    var feeds by mutableStateOf(mapOf<String, List<Track>>())
        private set
    var refreshing by mutableStateOf(false)
        private set
    var loading by mutableStateOf(setOf<String>())
        private set

    private var feedsUpdated: Long? = null
    private var lastSave = 0L
    private var dirty = false
    private lateinit var file: File
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    fun init(context: Context) {
        file = File(context.filesDir, "podcasts.json")
        runCatching { json.decodeFromString(Stored.serializer(), file.readText()) }.getOrNull()?.let {
            subscriptions = it.subscriptions
            progress = it.progress
            feeds = it.feeds
            feedsUpdated = it.feedsUpdated
        }
    }

    private fun save() {
        val text = json.encodeToString(Stored.serializer(), Stored(subscriptions, progress, feeds, feedsUpdated))
        lastSave = System.currentTimeMillis()
        dirty = false
        scope.launch(Dispatchers.IO) {
            runCatching {
                val tmp = File(file.path + ".tmp")
                tmp.writeText(text)
                tmp.renameTo(file)
            }
        }
    }

    /** Writes pending progress now (Drift going to the background). */
    fun flush() {
        if (dirty) save()
    }

    // MARK: Following

    fun isFollowing(id: String?): Boolean = id != null && subscriptions.any { it.id == id }

    fun follow(c: PodcastChannel) {
        if (isFollowing(c.id)) return
        subscriptions = subscriptions + c
        save()
        scope.launch { loadChannel(c) }
    }

    fun unfollow(id: String) {
        subscriptions = subscriptions.filterNot { it.id == id }
        save()
    }

    fun toggleFollow(c: PodcastChannel) = if (isFollowing(c.id)) unfollow(c.id) else follow(c)

    /** The show an episode is from (nothing for a feed episode whose feed isn't known). */
    fun channel(t: Track): PodcastChannel? {
        val id = t.channelID ?: return null
        subscriptions.firstOrNull { it.id == id }?.let { return it }
        if (id.startsWith("rss-") && t.feedURL == null) return null
        return PodcastChannel(id, t.artist, t.channelAvatar, feedURL = t.feedURL)
    }

    /** A show's episodes: from its feed, or YouTube. Blocking. */
    fun fetchEpisodes(c: PodcastChannel): List<Track> =
        if (c.isFeed) Feeds.episodes(c) else YouTubePodcasts.channelEpisodes(c)

    /** A show opened from a pasted link: its episodes are already here. */
    fun showLoaded(c: PodcastChannel, episodes: List<Track>) {
        if (episodes.isNotEmpty()) feeds = feeds + (c.id to episodes)
    }

    // MARK: Episodes

    /** Newest episodes from every followed show. */
    val newEpisodes: List<Track>
        get() = subscriptions.flatMap { feeds[it.id].orEmpty() }
            .sortedByDescending { it.published ?: Double.NEGATIVE_INFINITY }
            .take(60)

    val continueListening: List<EpisodeProgress>
        get() = progress.values.filter { !it.finished && it.position >= 30 }.sortedByDescending { it.updated }.take(10)

    /** Every followed show's newest episodes (at most every 30 minutes unless forced). */
    suspend fun refresh(force: Boolean) {
        if (refreshing || subscriptions.isEmpty()) return
        val last = feedsUpdated
        if (!force && last != null && System.currentTimeMillis() - last < 30 * 60_000) return
        refreshing = true
        try {
            val subs = subscriptions
            val results = withContext(Dispatchers.IO) {
                coroutineScope {
                    subs.map { c -> async { c.id to runCatching { fetchEpisodes(c) }.getOrNull() } }.awaitAll()
                }
            }
            var next = feeds
            for ((id, eps) in results) if (!eps.isNullOrEmpty()) next = next + (id to eps)
            feeds = next
            feedsUpdated = System.currentTimeMillis()
            save()
        } finally {
            refreshing = false
        }
    }

    /** One show's episodes (its page, or right after following). Throws when they can't be loaded. */
    suspend fun loadChannel(c: PodcastChannel): List<Track> {
        if (c.id in loading) return feeds[c.id].orEmpty()
        loading = loading + c.id
        try {
            val eps = withContext(Dispatchers.IO) { fetchEpisodes(c) }
            if (eps.isNotEmpty()) {
                feeds = feeds + (c.id to eps)
                if (isFollowing(c.id)) save()
            }
            return eps
        } finally {
            loading = loading - c.id
        }
    }

    // MARK: Where each episode was left

    /** How far into it (0–1), for an episode started and not finished. */
    fun fraction(id: String): Double? {
        val p = progress[id] ?: return null
        if (p.finished || p.duration <= 0 || p.position < 30) return null
        return minOf(p.position / p.duration, 1.0)
    }

    fun isFinished(id: String): Boolean = progress[id]?.finished == true

    /** Seconds left, for an episode started and not finished. */
    fun remaining(id: String): Double? {
        val p = progress[id] ?: return null
        if (p.finished || p.duration <= 0 || p.position < 30) return null
        return maxOf(p.duration - p.position, 0.0)
    }

    /** Where to start an episode: a few seconds before where it was left. */
    fun resumePosition(id: String): Double {
        val p = progress[id] ?: return 0.0
        if (p.finished || p.position < 30) return 0.0
        return maxOf(p.position - 3, 0.0)
    }

    /** Called while an episode plays (saved every 15 s, or now with `force`). */
    fun update(t: Track, position: Double, duration: Double, force: Boolean = false) {
        if (!position.isFinite() || !duration.isFinite() || duration <= 0) return
        var next = progress + (t.id to EpisodeProgress(t, position, duration, System.currentTimeMillis(), duration - position < 30))
        // Keep the list from growing forever.
        if (next.size > 500) next = next.entries.sortedByDescending { it.value.updated }.take(500).associate { it.key to it.value }
        progress = next
        dirty = true
        if (force || System.currentTimeMillis() - lastSave > 15_000) save()
    }

    fun markPlayed(t: Track, played: Boolean) {
        progress = if (played) {
            val d = progress[t.id]?.duration ?: t.duration ?: 0.0
            progress + (t.id to EpisodeProgress(t, d, d, System.currentTimeMillis(), true))
        } else progress - t.id
        save()
    }
}
