package com.lordxhobo.drift.playback

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Bundle
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.lordxhobo.drift.data.Library
import com.lordxhobo.drift.data.Track
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.guava.await
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString

/**
 * The app's side of playback: what's playing, the queue, and the controls. Talks to PlaybackService
 * through a Media3 controller; everything here is read by the screens as Compose state.
 */
object Playback {
    enum class Repeat { OFF, ALL, ONE }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var controller: MediaController? = null
    /** What to do once connected (a song picked while the service was still starting). */
    private val pending = mutableListOf<(MediaController) -> Unit>()

    var queue by mutableStateOf(listOf<Track>())
        private set
    var index by mutableStateOf(0)
        private set
    var isPlaying by mutableStateOf(false)
        private set
    var isBuffering by mutableStateOf(false)
        private set
    var position by mutableLongStateOf(0L)
        private set
    var duration by mutableLongStateOf(0L)
        private set
    var shuffle by mutableStateOf(false)
        private set
    var repeat by mutableStateOf(Repeat.OFF)
        private set
    var playingFrom by mutableStateOf("")
        private set
    var error by mutableStateOf<String?>(null)
        private set

    /** The order before shuffling, to go back to it. */
    private var original: List<Track> = emptyList()

    val current: Track? get() = queue.getOrNull(index)
    val upNext: List<Track> get() = if (index + 1 <= queue.size) queue.drop(index + 1) else emptyList()

    fun connect(context: Context) {
        if (controller != null) return
        val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
        scope.launch {
            val c = runCatching { MediaController.Builder(context, token).buildAsync().await() }.getOrNull() ?: return@launch
            controller = c
            c.addListener(listener)
            readAll(c)
            pending.forEach { it(c) }
            pending.clear()
            // The position bar moves on its own: read it a few times a second.
            while (true) {
                position = c.currentPosition.coerceAtLeast(0)
                val d = c.duration
                if (d > 0) duration = d
                delay(250)
            }
        }
    }

    private fun withController(action: (MediaController) -> Unit) {
        val c = controller
        if (c != null) action(c) else pending += action
    }

    private val listener = object : Player.Listener {
        override fun onEvents(player: Player, events: Player.Events) = readAll(player)

        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            if (reason == Player.MEDIA_ITEM_TRANSITION_REASON_AUTO) naturalEndAt = System.currentTimeMillis()
            // Videos from the YouTube viewer stay out of the music's Recently played.
            mediaItem?.let { trackOf(it) }?.takeIf { it.watch != true }?.let { Library.addRecent(it) }
        }
    }

    /** Listen Together: jumps made here (to tell the others), and when a song last ended by itself. */
    var seeks = 0
        private set
    var naturalEndAt = 0L
        private set

    /** The view showing the player's own picture (YouTube viewer videos), or none. */
    private var pictureView: android.view.TextureView? = null

    fun showPicture(view: android.view.TextureView?) {
        val old = pictureView
        if (old === view) return
        pictureView = view
        withController { c -> if (view != null) c.setVideoTextureView(view) else if (old != null) c.clearVideoTextureView(old) }
    }

    /** Stops and forgets what was playing (the floating video's X). */
    fun close() {
        withController { c ->
            c.stop()
            c.clearMediaItems()
            choosePlayer(null)
        }
        original = emptyList()
    }

    /** A new quality for the video playing: its picture again at that height, from where it is. */
    fun reloadPicture() {
        val c = controller ?: return
        val t = current ?: return
        if (!PlaybackService.showsPicture(t)) return
        val at = c.currentPosition
        val i = c.currentMediaItemIndex
        c.replaceMediaItem(i, itemOf(t))
        c.seekTo(i, at)
    }

    /** Where the song is right now (ms), not just as of the last read. */
    fun exactPosition(): Long = controller?.currentPosition?.coerceAtLeast(0) ?: position

    /** Called when the song or play/pause changes (friends' activity, stats, other devices listen). */
    val onChange = mutableListOf<(Track?, Boolean) -> Unit>()
    private var lastNotified: Pair<String?, Boolean>? = null

    private fun readAll(p: Player) {
        val list = (0 until p.mediaItemCount).mapNotNull { trackOf(p.getMediaItemAt(it)) }
        if (list.map { it.id } != queue.map { it.id }) queue = list
        index = p.currentMediaItemIndex.coerceAtLeast(0)
        isPlaying = p.isPlaying
        isBuffering = p.playbackState == Player.STATE_BUFFERING
        repeat = when (p.repeatMode) {
            Player.REPEAT_MODE_ONE -> Repeat.ONE
            Player.REPEAT_MODE_ALL -> Repeat.ALL
            else -> Repeat.OFF
        }
        error = p.playerError?.let { "Couldn't play this song. Check your connection." }
        val d = p.duration
        duration = if (d > 0) d else ((current?.duration ?: 0.0) * 1000).toLong()
        val now = current?.id to isPlaying
        if (now != lastNotified) {
            lastNotified = now
            onChange.forEach { it(current, isPlaying) }
        }
    }

    // MARK: Songs ⇄ player items

    const val TRACK_KEY = "drift.track"

    internal fun itemOf(t: Track): MediaItem {
        val extras = Bundle().apply { putString(TRACK_KEY, Library.json.encodeToString(t)) }
        val meta = MediaMetadata.Builder()
            .setTitle(t.title)
            .setArtist(t.artist)
            .setAlbumTitle(t.album)
            .setArtworkUri(Uri.parse(t.artwork(544)))
            .setExtras(extras)
            .build()
        return MediaItem.Builder().setMediaId(t.id).setMediaMetadata(meta).build()
    }

    /** Started from elsewhere (Android Auto): what "Playing from" says. */
    fun cameFrom(source: String, list: List<Track>) {
        playingFrom = source
        shuffle = false
        original = list
    }

    private fun trackOf(item: MediaItem): Track? {
        val s = item.mediaMetadata.extras?.getString(TRACK_KEY) ?: return null
        return runCatching { Library.json.decodeFromString(Track.serializer(), s) }.getOrNull()
    }

    // MARK: Controls

    /** Plays a list from one of its songs (or a random one, shuffled). */
    fun play(tracks: List<Track>, start: Int = 0, from: String, shuffled: Boolean = false) {
        if (tracks.isEmpty()) return
        val first = if (shuffled) tracks.indices.random() else start.coerceIn(tracks.indices)
        original = tracks
        playingFrom = from
        val list = if (shuffled) listOf(tracks[first]) + tracks.filterIndexed { i, _ -> i != first }.shuffled() else tracks
        val at = if (shuffled) 0 else first
        shuffle = shuffled
        queue = list
        index = at
        withController { c ->
            choosePlayer(list[at])
            c.setMediaItems(list.map { itemOf(it) }, at, 0)
            c.prepare()
            c.play()
        }
    }

    /** Videos from the YouTube viewer play in YouTube's own player (like ProTube); everything else in ExoPlayer. */
    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    private fun choosePlayer(first: Track?) {
        PlaybackService.instance?.use(first != null && PlaybackService.showsPicture(first))
    }

    fun playNext(t: Track) {
        if (current == null) return play(listOf(t), 0, "Queue")
        withController { c -> c.addMediaItem(c.currentMediaItemIndex + 1, itemOf(t)) }
        original = original + t
    }

    fun addToQueue(t: Track) {
        if (current == null) return play(listOf(t), 0, "Queue")
        withController { c -> c.addMediaItem(itemOf(t)) }
        original = original + t
    }

    fun toggle() = withController { c ->
        if (c.isPlaying) c.pause() else {
            if (c.playbackState == Player.STATE_IDLE) c.prepare()
            c.play()
        }
    }

    fun next() = withController { c -> if (c.hasNextMediaItem()) c.seekToNextMediaItem() }

    /** The previous song, or back to the start of this one after the first few seconds. */
    fun previous() = withController { c ->
        if (c.currentPosition > 3000 || !c.hasPreviousMediaItem()) {
            seeks++
            c.seekTo(0)
        } else c.seekToPreviousMediaItem()
    }

    fun seek(ms: Long) = withController { c ->
        seeks++
        c.seekTo(ms)
        position = ms
    }

    /** Plays a song further down the queue. */
    fun jump(to: Int) = withController { c ->
        if (to in 0 until c.mediaItemCount) {
            c.seekTo(to, 0)
            c.play()
        }
    }

    fun removeFromQueue(at: Int) = withController { c ->
        if (at != c.currentMediaItemIndex && at in 0 until c.mediaItemCount) c.removeMediaItem(at)
    }

    /** Moves a song in Up next one place up (-1) or down (+1). */
    fun move(at: Int, by: Int) = withController { c ->
        val to = at + by
        val now = c.currentMediaItemIndex
        if (at > now && to > now && to < c.mediaItemCount) c.moveMediaItem(at, to)
    }

    fun clearUpNext() = withController { c ->
        val from = c.currentMediaItemIndex + 1
        if (from < c.mediaItemCount) c.removeMediaItems(from, c.mediaItemCount)
    }

    /** Shuffles what's next (the song playing stays), or goes back to the original order. */
    fun toggleShuffle() {
        val cur = current ?: run { shuffle = !shuffle; return }
        shuffle = !shuffle
        val rest = if (shuffle) upNext.shuffled() else {
            val i = original.indexOfFirst { it.id == cur.id }
            if (i >= 0) original.drop(i + 1) else upNext
        }
        withController { c ->
            val from = c.currentMediaItemIndex + 1
            if (from < c.mediaItemCount) c.removeMediaItems(from, c.mediaItemCount)
            c.addMediaItems(rest.map { itemOf(it) })
        }
    }

    fun pause() = withController { c -> c.pause() }

    fun resume() = withController { c ->
        if (c.playbackState == Player.STATE_IDLE) c.prepare()
        c.play()
    }

    /** "off", "all" or "one". */
    fun repeatTo(mode: String) = withController { c ->
        c.repeatMode = when (mode) {
            "all" -> Player.REPEAT_MODE_ALL
            "one" -> Player.REPEAT_MODE_ONE
            else -> Player.REPEAT_MODE_OFF
        }
    }

    fun shuffleTo(on: Boolean) {
        if (shuffle != on) toggleShuffle()
    }

    /** The player's own volume, 0–1 (the phone's volume buttons work on top of it). */
    var volume by mutableStateOf(1f)
        private set

    fun changeVolume(v: Float) = withController { c ->
        c.volume = v.coerceIn(0f, 1f)
        volume = c.volume
    }

    /** Playback moved here from another device: the song where it was, then its queue. */
    /** Back or forward a few seconds (episodes: 15 back, 30 forward). */
    fun skipBy(seconds: Int) = withController { c ->
        seeks++
        val target = (c.currentPosition + seconds * 1000L).coerceAtLeast(0)
        val end = c.duration
        c.seekTo(if (end > 0) minOf(target, end - 1000) else target)
        position = c.currentPosition
    }

    /** An episode, from where it was left off. */
    fun playEpisode(t: Track) {
        val store = com.lordxhobo.drift.podcasts.PodcastStore
        store.started(t.id)
        transferIn(t, emptyList(), store.resumePosition(t.id), true, t.artist)
    }

    fun transferIn(track: Track, queue: List<Track>, positionSeconds: Double, playing: Boolean, source: String) {
        original = listOf(track) + queue
        playingFrom = source.ifEmpty { "Another device" }
        shuffle = false
        this.queue = original
        index = 0
        withController { c ->
            choosePlayer(track)
            c.setMediaItems(original.map { itemOf(it) }, 0, (positionSeconds * 1000).toLong().coerceAtLeast(0))
            c.prepare()
            if (playing) c.play() else c.pause()
        }
    }

    /**
     * Listen Together: plays what the session plays (the song, what's after it, where, and whether).
     * Only changes what differs, so the music keeps going smoothly.
     */
    fun jamPlay(track: Track, upcoming: List<Track>, positionSeconds: Double, playing: Boolean) {
        if (current?.id != track.id) {
            transferIn(track, upcoming, positionSeconds, playing, "Listening together")
            return
        }
        withController { c ->
            if (upNext.map { it.id } != upcoming.map { it.id }) {
                val from = c.currentMediaItemIndex + 1
                if (from < c.mediaItemCount) c.removeMediaItems(from, c.mediaItemCount)
                c.addMediaItems(upcoming.map { itemOf(it) })
                original = listOf(track) + upcoming
            }
            // Paused, or just paused/started: the exact spot. While playing on: only bigger gaps (no stutter).
            val tolerance = if (!playing || playing != c.isPlaying) 0.3 else 1.5
            val target = (positionSeconds * 1000).toLong().coerceAtLeast(0)
            if (kotlin.math.abs(c.currentPosition - target) > tolerance * 1000) {
                c.seekTo(target)
                position = target
            }
            if (playing && !c.isPlaying) {
                if (c.playbackState == Player.STATE_IDLE) c.prepare()
                c.play()
            } else if (!playing && c.isPlaying) c.pause()
        }
    }

    fun cycleRepeat() = withController { c ->
        c.repeatMode = when (c.repeatMode) {
            Player.REPEAT_MODE_OFF -> Player.REPEAT_MODE_ALL
            Player.REPEAT_MODE_ALL -> Player.REPEAT_MODE_ONE
            else -> Player.REPEAT_MODE_OFF
        }
    }
}
