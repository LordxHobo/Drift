package com.lordxhobo.drift.playback

import android.content.Context
import android.content.SharedPreferences
import android.view.TextureView
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import com.lordxhobo.drift.data.Track
import com.lordxhobo.drift.youtube.HttpDownloader
import com.lordxhobo.drift.youtube.YouTube
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.abs

/**
 * The picture for podcast episodes (optional, like on the iPhone). The sound always comes from the normal
 * player; this silent video just follows it, so speed, skipping and the notification keep working. It only
 * loads while the video is on screen, so it uses no data otherwise.
 */
@androidx.annotation.OptIn(UnstableApi::class)
object EpisodeVideo {
    /** Show episodes' video in the player (instead of their picture). */
    var on by mutableStateOf(false)
        private set
    /** The highest height to use. */
    var quality by mutableStateOf(720)
        private set
    /** Has a picture to show. */
    var ready by mutableStateOf(false)
        private set
    /** YouTube gave no video for this episode (or it didn't load). */
    var unavailable by mutableStateOf(false)
        private set
    /** The height playing now, and the ones the episode comes in. */
    var height by mutableStateOf<Int?>(null)
        private set
    var heights by mutableStateOf(listOf<Int>())
        private set

    private lateinit var app: Context
    private lateinit var prefs: SharedPreferences
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var player: ExoPlayer? = null
    /** The views showing it (the player, full screen on top): the last one gets the picture. */
    private val views = mutableListOf<TextureView>()
    private val surface: TextureView? get() = views.lastOrNull()
    private var key = ""
    private var load: Job? = null
    private var follow: Job? = null
    private var seekedAt = 0L

    fun init(context: Context) {
        app = context.applicationContext
        prefs = app.getSharedPreferences("drift.settings", Context.MODE_PRIVATE)
        on = prefs.getBoolean("episodeVideo", false)
        quality = prefs.getInt("videoQuality", 720)
        // A different episode: its own video (or none).
        Playback.onChange.add { _, _ -> update() }
    }

    /** An episode on YouTube (not a show's audio file). */
    fun canShow(t: Track?): Boolean = t != null && t.isEpisode && t.audioURL == null && !t.id.startsWith("rss-")

    fun turn(value: Boolean) {
        on = value
        prefs.edit().putBoolean("episodeVideo", value).apply()
        update()
    }

    /** Pick a quality (the highest choice means "always the sharpest"). */
    fun choose(h: Int) {
        quality = if (h == heights.lastOrNull()) 4320 else h
        prefs.edit().putInt("videoQuality", quality).apply()
        if (Playback.current?.let { PlaybackService.showsPicture(it) } == true) {
            key = ""
            height = h
            Playback.reloadPicture()
        }
        update()
    }

    /** The video's view appeared (on screen, Drift in front). */
    fun attach(view: TextureView) {
        views.remove(view)
        views.add(view)
        player?.setVideoTextureView(view)
        update()
    }

    /** The player plays this one's picture itself (a YouTube viewer video): it goes on the front view. */
    private val inPlayer: Boolean get() = Playback.current?.let { PlaybackService.showsPicture(it) } == true

    /** …or went away. */
    fun detach(view: TextureView) {
        val wasShowing = surface === view
        if (!views.remove(view)) return
        if (wasShowing) player?.clearVideoTextureView(view)
        val next = surface
        if (inPlayer) Playback.showPicture(next)
        if (next == null) stop() else if (wasShowing) player?.setVideoTextureView(next)
    }

    /** Loads the right video (or none) for what's playing and the settings. */
    fun update() {
        val t = Playback.current
        // A YouTube viewer video: the player shows its own picture (sound and picture as one, like YouTube's app).
        if (::app.isInitialized && t != null && PlaybackService.showsPicture(t)) {
            stopOwn()
            Playback.showPicture(surface)
            unavailable = false
            ready = surface != null
            val k = "${t.id}#in-player"
            if (key != k) {
                key = k
                scope.launch {
                    val found = withContext(Dispatchers.IO) { runCatching { YouTube.video(t.id, quality) }.getOrNull() }
                    if (key != k || found == null) return@launch
                    height = found.height
                    heights = found.heights
                }
            }
            return
        }
        Playback.showPicture(null)
        if (key.endsWith("#in-player")) key = ""
        // Episodes: when video is on. Videos from the YouTube viewer: always.
        if (!::app.isInitialized || !(on || t?.watch == true) || surface == null || !canShow(t) || t == null) {
            stop()
            return
        }
        val max = quality
        val k = "${t.id}#$max"
        if (k == key) return
        // Keep the old picture while a new quality loads for the same episode.
        val sameEpisode = key.startsWith(t.id + "#")
        key = k
        if (!sameEpisode) ready = false
        unavailable = false
        load?.cancel()
        load = scope.launch {
            val found = withContext(Dispatchers.IO) { runCatching { YouTube.video(t.id, max) }.getOrNull() }
            if (key != k) return@launch
            if (found == null) {
                unavailable = true
                ready = false
                return@launch
            }
            height = found.height
            heights = found.heights
            val p = player ?: build().also { player = it }
            surface?.let { p.setVideoTextureView(it) }
            p.setMediaItem(MediaItem.fromUri(found.url), Playback.exactPosition())
            p.prepare()
            startFollowing()
        }
    }

    private fun build(): ExoPlayer =
        ExoPlayer.Builder(app)
            .setMediaSourceFactory(DefaultMediaSourceFactory(YouTubeDataSource.Factory(HttpDownloader.shared.client)))
            .build()
            .apply {
                volume = 0f
                addListener(object : Player.Listener {
                    override fun onRenderedFirstFrame() {
                        ready = true
                    }

                    override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                        unavailable = true
                        ready = false
                    }
                })
            }

    fun stop() {
        stopOwn()
        key = ""
        ready = false
        Playback.showPicture(null)
    }

    /** Lets go of the silent copy (the picture of episodes). */
    private fun stopOwn() {
        load?.cancel()
        follow?.cancel()
        player?.release()
        player = null
    }

    /** Keeps the picture in step with the sound, a few times a second. */
    private fun startFollowing() {
        follow?.cancel()
        follow = scope.launch {
            while (isActive) {
                val p = player ?: break
                if (Playback.current?.isEpisode != true) break
                val audio = Playback.exactPosition()
                val now = System.currentTimeMillis()
                // A jump takes a moment to land: don't chase it.
                if (now - seekedAt > 1500 && abs(p.currentPosition - audio) > 400) {
                    p.seekTo(audio)
                    seekedAt = now
                }
                val speed = Skipping.podcastSpeed
                if (!Playback.isPlaying) {
                    if (p.playWhenReady) p.playWhenReady = false
                } else {
                    if (p.playbackParameters.speed != speed) p.setPlaybackSpeed(speed)
                    if (!p.playWhenReady) p.playWhenReady = true
                }
                delay(250)
            }
        }
    }
}
