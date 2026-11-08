package com.lordxhobo.drift.playback

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.lordxhobo.drift.MainActivity
import com.lordxhobo.drift.R
import com.lordxhobo.drift.youtube.HttpDownloader
import com.lordxhobo.drift.youtube.YouTube
import java.io.IOException

/**
 * Plays in the background, with the notification, lock screen and Bluetooth controls (Media3).
 * Songs are queued as `drift://song/<video id>`; the audio link is found only when a song starts
 * loading (links expire after a few hours).
 */
@UnstableApi
class PlaybackService : MediaSessionService() {
    private var session: MediaSession? = null
    private val main = Handler(Looper.getMainLooper())
    /** Songs that already got a fresh link after failing (one retry each). */
    private val retried = mutableSetOf<String>()
    private var skips: SkipMonitor? = null

    override fun onCreate() {
        super.onCreate()
        val upstream = YouTubeDataSource.Factory(HttpDownloader.shared.client)
        val resolving = ResolvingDataSource.Factory(upstream) { spec ->
            val uri = spec.uri
            if (uri.scheme == SCHEME) {
                val id = uri.lastPathSegment ?: throw IOException("No song")
                // Any failure finding the link counts as a loading error, so the player can recover.
                val url = try {
                    YouTube.audio(id).url
                } catch (e: IOException) {
                    throw e
                } catch (e: Exception) {
                    throw IOException("Couldn't find this song's audio", e)
                }
                spec.withUri(Uri.parse(url))
            } else spec
        }
        // Downloads first, then the song cache, then YouTube.
        val sources = SongDataSource.Factory(SongDataSource.cacheFactory(resolving), resolving)
        // On its way out, the sound passes a level meter (for skipping silence), then the equalizer.
        val renderers = object : DefaultRenderersFactory(this) {
            override fun buildAudioSink(context: Context, enableFloatOutput: Boolean, enableAudioTrackPlaybackParams: Boolean): AudioSink =
                DefaultAudioSink.Builder(context)
                    .setEnableFloatOutput(enableFloatOutput)
                    .setAudioProcessors(arrayOf<AudioProcessor>(LevelMeter(), EqualizerProcessor()))
                    .setEnableAudioTrackPlaybackParams(enableAudioTrackPlaybackParams)
                    .build()
        }
        val player = ExoPlayer.Builder(this, renderers)
            .setMediaSourceFactory(DefaultMediaSourceFactory(this).setDataSourceFactory(sources))
            .setAudioAttributes(
                AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(),
                true
            )
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .build()
        player.addListener(object : Player.Listener {
            override fun onPlayerError(error: PlaybackException) = recover(player)
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                mediaItem?.mediaId?.let { retried.remove(it) }
            }
        })

        skips = SkipMonitor(player).also { it.start() }

        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        session = MediaSession.Builder(this, player)
            .setSessionActivity(open)
            .setCallback(object : MediaSession.Callback {
                // Songs sent from the app arrive without their address: give each one back.
                override fun onAddMediaItems(
                    mediaSession: MediaSession,
                    controller: MediaSession.ControllerInfo,
                    mediaItems: MutableList<MediaItem>,
                ): ListenableFuture<MutableList<MediaItem>> =
                    Futures.immediateFuture(mediaItems.map { songItem(it) }.toMutableList())
            })
            .build()
        val notifications = DefaultMediaNotificationProvider.Builder(this).build()
        notifications.setSmallIcon(R.drawable.ic_notification)
        setMediaNotificationProvider(notifications)
    }

    /** A song that failed (usually an expired link): a fresh link once, then on to the next song. */
    private fun recover(player: ExoPlayer) {
        val item = player.currentMediaItem ?: return
        val id = item.mediaId
        if (retried.add(id)) {
            YouTube.forget(id)
            // A broken saved part (or a link for a different file): start that song afresh.
            SongCache.forget(id)
            val position = player.currentPosition
            player.prepare()
            player.seekTo(player.currentMediaItemIndex, position)
            player.play()
        } else {
            main.postDelayed({
                if (player.currentMediaItem?.mediaId == id && player.hasNextMediaItem()) {
                    player.seekToNextMediaItem()
                    player.prepare()
                    player.play()
                }
            }, 1500)
        }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    override fun onTaskRemoved(rootIntent: Intent?) {
        val player = session?.player
        // Swiped away while nothing plays: stop. While playing, keep going (like Spotify).
        if (player == null || !player.playWhenReady || player.mediaItemCount == 0) stopSelf()
    }

    override fun onDestroy() {
        skips?.stop()
        session?.run {
            player.release()
            release()
        }
        session = null
        super.onDestroy()
    }

    companion object {
        const val SCHEME = "drift"

        fun songItem(item: MediaItem): MediaItem =
            item.buildUpon().setUri(Uri.parse("$SCHEME://song/${item.mediaId}")).build()
    }
}
