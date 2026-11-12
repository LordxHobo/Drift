package com.lordxhobo.drift.playback

import android.os.Handler
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

/**
 * YouTube's own player (YTWeb) as a Media3 player, so the session, notification, lock screen, Bluetooth and
 * Drift's own screens drive videos from the YouTube viewer just like songs. The queue lives here; the web
 * view plays one video of it at a time.
 */
@UnstableApi
class WebVideoPlayer : SimpleBasePlayer(Looper.getMainLooper()) {
    private val main = Handler(Looper.getMainLooper())
    private var items: List<MediaItem> = emptyList()
    private var uids: List<Any> = emptyList()
    private var index = 0
    private var playWhenReady = false
    private var prepared = false
    private var ended = false
    private var repeat = Player.REPEAT_MODE_OFF
    private var params = PlaybackParameters.DEFAULT
    /** Where to start the video (before the page reports where it is). */
    private var startMs = 0L
    private var error: PlaybackException? = null
    /** The queue entry the page has loaded. */
    private var loaded: Any? = null

    init {
        YTWeb.listener = object : YTWeb.Listener {
            override fun changed() = invalidateState()

            override fun ended() {
                when {
                    repeat == Player.REPEAT_MODE_ONE -> {
                        YTWeb.seek(0)
                        YTWeb.play()
                    }
                    index + 1 < items.size -> goTo(index + 1)
                    repeat == Player.REPEAT_MODE_ALL && items.isNotEmpty() -> goTo(0)
                    else -> ended = true
                }
                invalidateState()
            }

            override fun failed(message: String) {
                error = PlaybackException("YouTube's player couldn't play this video: $message", null, PlaybackException.ERROR_CODE_REMOTE_ERROR)
                invalidateState()
                // On to the next one after a moment (like songs that fail).
                val failedAt = loaded
                main.postDelayed({
                    if (loaded === failedAt && index + 1 < items.size) {
                        goTo(index + 1)
                        invalidateState()
                    }
                }, 2500)
            }
        }
    }

    private fun goTo(i: Int) {
        index = i
        startMs = 0
        ended = false
        loaded = null
        load()
    }

    /** Loads the current queue entry into the page (once prepared). */
    private fun load() {
        if (!prepared || items.isEmpty()) return
        val uid = uids[index]
        if (loaded === uid && YTWeb.videoId == items[index].mediaId) return
        loaded = uid
        ended = false
        error = null
        YTWeb.load(items[index].mediaId, startMs, playWhenReady)
        YTWeb.rate(params.speed)
    }

    private val onPage: Boolean get() = items.isNotEmpty() && loaded === uids[index] && YTWeb.videoId == items[index].mediaId

    override fun getState(): SimpleBasePlayer.State {
        val commands = Player.Commands.Builder().addAll(
            Player.COMMAND_PLAY_PAUSE, Player.COMMAND_PREPARE, Player.COMMAND_STOP, Player.COMMAND_RELEASE,
            Player.COMMAND_SEEK_TO_DEFAULT_POSITION, Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
            Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM, Player.COMMAND_SEEK_TO_PREVIOUS,
            Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM, Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_MEDIA_ITEM,
            Player.COMMAND_SEEK_BACK, Player.COMMAND_SEEK_FORWARD,
            Player.COMMAND_SET_SPEED_AND_PITCH, Player.COMMAND_SET_REPEAT_MODE,
            Player.COMMAND_GET_CURRENT_MEDIA_ITEM, Player.COMMAND_GET_TIMELINE, Player.COMMAND_GET_METADATA,
            Player.COMMAND_SET_MEDIA_ITEM, Player.COMMAND_CHANGE_MEDIA_ITEMS,
        ).build()
        val playlist = items.mapIndexed { i, item ->
            val d = if (i == index && onPage && YTWeb.durationMs > 0) YTWeb.durationMs * 1000 else C.TIME_UNSET
            SimpleBasePlayer.MediaItemData.Builder(uids[i]).setMediaItem(item).setDurationUs(d).setIsSeekable(true).build()
        }
        val state = when {
            playlist.isEmpty() || !prepared -> Player.STATE_IDLE
            ended -> Player.STATE_ENDED
            error != null -> Player.STATE_IDLE
            !onPage || !YTWeb.ready || YTWeb.buffering -> Player.STATE_BUFFERING
            else -> Player.STATE_READY
        }
        val b = SimpleBasePlayer.State.Builder()
            .setAvailableCommands(commands)
            .setPlayWhenReady(playWhenReady, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
            .setPlaybackState(state)
            .setPlayerError(error)
            .setRepeatMode(repeat)
            .setPlaybackParameters(params)
            .setIsLoading(state == Player.STATE_BUFFERING)
            .setPlaylist(playlist)
        if (playlist.isNotEmpty()) {
            b.setCurrentMediaItemIndex(index)
            val start = startMs
            b.setContentPositionMs(SimpleBasePlayer.PositionSupplier { if (onPage && YTWeb.ready) YTWeb.positionMs() else start })
        }
        return b.build()
    }

    private val done: ListenableFuture<*> get() = Futures.immediateVoidFuture()

    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
        this.playWhenReady = playWhenReady
        if (playWhenReady) {
            if (ended) {
                // Played to the end: from the start again.
                startMs = 0
                loaded = null
                ended = false
            }
            if (onPage) YTWeb.play() else load()
        } else {
            YTWeb.pause()
        }
        return done
    }

    override fun handlePrepare(): ListenableFuture<*> {
        prepared = true
        if (error != null) {
            // Try again from where it was.
            error = null
            startMs = if (onPage) YTWeb.positionMs() else startMs
            loaded = null
        }
        load()
        return done
    }

    override fun handleStop(): ListenableFuture<*> {
        prepared = false
        if (onPage) startMs = YTWeb.positionMs()
        loaded = null
        YTWeb.stop()
        return done
    }

    override fun handleRelease(): ListenableFuture<*> {
        YTWeb.stop()
        return done
    }

    override fun handleSetMediaItems(mediaItems: List<MediaItem>, startIndex: Int, startPositionMs: Long): ListenableFuture<*> {
        items = mediaItems
        uids = mediaItems.map { Any() }
        index = if (startIndex == C.INDEX_UNSET) 0 else startIndex.coerceIn(0, (items.size - 1).coerceAtLeast(0))
        startMs = if (startPositionMs == C.TIME_UNSET) 0 else startPositionMs
        ended = false
        error = null
        loaded = null
        if (items.isEmpty()) YTWeb.stop() else load()
        return done
    }

    override fun handleAddMediaItems(index: Int, mediaItems: List<MediaItem>): ListenableFuture<*> {
        val at = index.coerceIn(0, items.size)
        val wasEmpty = items.isEmpty()
        items = items.take(at) + mediaItems + items.drop(at)
        uids = uids.take(at) + mediaItems.map { Any() } + uids.drop(at)
        if (!wasEmpty && at <= this.index) this.index += mediaItems.size
        if (wasEmpty) load()
        return done
    }

    override fun handleRemoveMediaItems(fromIndex: Int, toIndex: Int): ListenableFuture<*> {
        val current = uids.getOrNull(index)
        items = items.take(fromIndex) + items.drop(toIndex)
        uids = uids.take(fromIndex) + uids.drop(toIndex)
        val still = uids.indexOfFirst { it === current }
        when {
            items.isEmpty() -> {
                index = 0
                loaded = null
                YTWeb.stop()
            }
            still >= 0 -> index = still
            else -> {
                // The one playing was removed: the one after it.
                index = fromIndex.coerceAtMost(items.size - 1)
                startMs = 0
                loaded = null
                load()
            }
        }
        return done
    }

    override fun handleMoveMediaItems(fromIndex: Int, toIndex: Int, newIndex: Int): ListenableFuture<*> {
        val current = uids.getOrNull(index)
        val movedItems = items.subList(fromIndex, toIndex).toList()
        val movedUids = uids.subList(fromIndex, toIndex).toList()
        val restItems = items.take(fromIndex) + items.drop(toIndex)
        val restUids = uids.take(fromIndex) + uids.drop(toIndex)
        val at = newIndex.coerceIn(0, restItems.size)
        items = restItems.take(at) + movedItems + restItems.drop(at)
        uids = restUids.take(at) + movedUids + restUids.drop(at)
        index = uids.indexOfFirst { it === current }.coerceAtLeast(0)
        return done
    }

    override fun handleSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int): ListenableFuture<*> {
        if (items.isEmpty()) return done
        val target = if (mediaItemIndex == C.INDEX_UNSET) index else mediaItemIndex.coerceIn(0, items.size - 1)
        val pos = if (positionMs == C.TIME_UNSET) 0 else positionMs.coerceAtLeast(0)
        ended = false
        if (target != index) {
            index = target
            startMs = pos
            loaded = null
            load()
        } else {
            startMs = pos
            if (onPage) YTWeb.seek(pos) else load()
        }
        return done
    }

    override fun handleSetRepeatMode(repeatMode: Int): ListenableFuture<*> {
        repeat = repeatMode
        return done
    }

    override fun handleSetPlaybackParameters(playbackParameters: PlaybackParameters): ListenableFuture<*> {
        params = playbackParameters
        YTWeb.rate(playbackParameters.speed)
        return done
    }
}
