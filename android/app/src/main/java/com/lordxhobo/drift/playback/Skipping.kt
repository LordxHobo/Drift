package com.lordxhobo.drift.playback

import android.content.Context
import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.common.audio.AudioProcessor.AudioFormat
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import com.lordxhobo.drift.data.Library
import com.lordxhobo.drift.data.Track
import com.lordxhobo.drift.data.formatTime
import com.lordxhobo.drift.youtube.HttpDownloader
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.concurrent.thread

/** A short message shown at the bottom of the app (skipped a part, joined a session…). */
object Notice {
    var text by mutableStateOf<String?>(null)
}

/** A part of a video the SponsorBlock community marked as not music (seconds). */
data class SkipSegment(val start: Double, val end: Double)

/**
 * Ad-free listening: skips the parts of music videos that aren't music (intros, outros, talking; marked by
 * the SponsorBlock community), and moves on when a song ends in a long stretch of silence. Same rules as the
 * iPhone and the computer.
 */
object Skipping {
    var nonMusic by mutableStateOf(true)
        private set
    var silence by mutableStateOf(true)
        private set
    private lateinit var prefs: SharedPreferences

    fun init(context: Context) {
        prefs = context.getSharedPreferences("drift.settings", Context.MODE_PRIVATE)
        nonMusic = prefs.getBoolean("skipNonMusic", true)
        silence = prefs.getBoolean("skipSilence", true)
    }

    fun changeNonMusic(on: Boolean) {
        nonMusic = on
        prefs.edit().putBoolean("skipNonMusic", on).apply()
    }

    fun changeSilence(on: Boolean) {
        silence = on
        prefs.edit().putBoolean("skipSilence", on).apply()
    }

    /** The non-music parts of a video (none when SponsorBlock has nothing, or can't be reached). */
    fun segments(videoId: String): List<SkipSegment> = runCatching {
        val url = "https://sponsor.ajay.app/api/skipSegments".toHttpUrl().newBuilder()
            .addQueryParameter("videoID", videoId)
            .addQueryParameter("category", "music_offtopic")
            .build()
        HttpDownloader.shared.client.newCall(Request.Builder().url(url).build()).execute().use { res ->
            if (res.code != 200) return@use emptyList()
            val list = Json.parseToJsonElement(res.body?.string() ?: "[]") as? JsonArray ?: return@use emptyList()
            list.mapNotNull { e ->
                val seg = (e as? JsonObject)?.get("segment") as? JsonArray ?: return@mapNotNull null
                if (seg.size != 2) return@mapNotNull null
                val start = seg[0].jsonPrimitive.doubleOrNull ?: return@mapNotNull null
                val end = seg[1].jsonPrimitive.doubleOrNull ?: return@mapNotNull null
                if (end - start >= 1) SkipSegment(start, end) else null
            }.sortedBy { it.start }
        }
    }.getOrDefault(emptyList())

    /** "non-music intro", "non-music outro" or "non-music part". */
    fun label(s: SkipSegment, duration: Double): String = when {
        s.start < 1 -> "non-music intro"
        duration > 0 && s.end > duration - 2 -> "non-music outro"
        else -> "non-music part"
    }
}

/** How loud the music that just played was (0 = silence, 1 = full scale), measured on its way to the speaker. */
object Level {
    @Volatile private var loudest = 0f
    @Volatile private var heard = false

    fun record(peak: Float) {
        if (peak > loudest) loudest = peak
        heard = true
    }

    /** The loudest moment since the last call, then starts over. null = no sound came through (unknown). */
    fun take(): Float? {
        val h = heard
        val l = loudest
        heard = false
        loudest = 0f
        return if (h) l else null
    }
}

/** Passes the sound on unchanged, noting how loud it is (16-bit sound only; anything else isn't measured). */
@UnstableApi
class LevelMeter : BaseAudioProcessor() {
    override fun onConfigure(inputAudioFormat: AudioFormat): AudioFormat =
        if (inputAudioFormat.encoding == C.ENCODING_PCM_16BIT) inputAudioFormat else AudioFormat.NOT_SET

    override fun queueInput(inputBuffer: ByteBuffer) {
        val size = inputBuffer.remaining()
        if (size == 0) return
        val samples = inputBuffer.duplicate().order(ByteOrder.nativeOrder()).asShortBuffer()
        var peak = 0
        while (samples.hasRemaining()) {
            val v = abs(samples.get().toInt())
            if (v > peak) peak = v
        }
        Level.record(peak / 32768f)
        replaceOutputBuffer(size).put(inputBuffer).flip()
    }
}

/** Runs next to the player (in the background too): does the skipping. */
@UnstableApi
class SkipMonitor(private val player: Player) {
    private val main = Handler(Looper.getMainLooper())
    private var songId: String? = null
    private var segments: List<SkipSegment> = emptyList()
    private val skipped = mutableSetOf<Double>()
    private var silentSince = 0L
    private var heard = false
    private var running = true

    private val loop = object : Runnable {
        override fun run() {
            if (!running) return
            runCatching { check() }
            main.postDelayed(this, 250)
        }
    }

    fun start() = main.post(loop)

    fun stop() {
        running = false
        main.removeCallbacks(loop)
    }

    private fun track(): Track? {
        val s = player.currentMediaItem?.mediaMetadata?.extras?.getString(Playback.TRACK_KEY) ?: return null
        return runCatching { Library.json.decodeFromString(Track.serializer(), s) }.getOrNull()
    }

    /** The song's real length (seconds): what's known about it, else what the file says. */
    private fun duration(t: Track?): Double {
        t?.duration?.takeIf { it > 0 }?.let { return it }
        val d = player.duration
        return if (d == C.TIME_UNSET || d <= 0) 0.0 else d / 1000.0
    }

    private fun check() {
        val id = player.currentMediaItem?.mediaId
        if (id != songId) {
            songId = id
            segments = emptyList()
            skipped.clear()
            silentSince = 0
            heard = false
            Level.take()
            if (id != null && Skipping.nonMusic) {
                thread(isDaemon = true) {
                    val list = Skipping.segments(id)
                    main.post { if (songId == id) segments = list }
                }
            }
        }
        if (id == null || !player.isPlaying) {
            silentSince = 0
            return
        }
        val t = track()
        val d = duration(t)
        val now = player.currentPosition / 1000.0
        // Played again from the start (repeat): its parts can be skipped again.
        if (now < 1 && skipped.isNotEmpty()) skipped.clear()

        // Non-music parts.
        if (Skipping.nonMusic && segments.isNotEmpty()) {
            val seg = segments.firstOrNull { now >= it.start && now < it.end - 0.5 && it.start !in skipped }
            if (seg != null) {
                skipped += seg.start
                if (d > 0 && seg.end >= d - 1) {
                    // An outro at the very end: on to the next song.
                    Notice.text = "Skipped ${Skipping.label(seg, d)}"
                    nextSong()
                } else {
                    player.seekTo((seg.end * 1000).toLong())
                    Notice.text = "Skipped ${Skipping.label(seg, d)} · ${formatTime(seg.end - seg.start)}"
                }
                silentSince = 0
                return
            }
        }

        // Songs that end in minutes of dead air (or a hidden track after it): 15 s of dead air after the first
        // 40% of a song, with more than 8 s left, ends it. Strict on purpose, so a quiet break, a fade or a
        // soft outro is never taken for the end; and only once the song has been heard.
        val loudest = Level.take()
        if (!Skipping.silence || loudest == null) {
            silentSince = 0
            return
        }
        if (loudest > 0.01f) heard = true
        if (!heard || d <= 60 || now < d * 0.4 || d - now <= 8 || loudest >= 0.001f) {
            silentSince = 0
            return
        }
        val clock = SystemClock.elapsedRealtime()
        if (silentSince == 0L) silentSince = clock
        else if (clock - silentSince >= 15_000) {
            silentSince = 0
            Notice.text = "Skipped ${formatTime(d - now)} of silence"
            nextSong()
        }
    }

    private fun nextSong() {
        if (player.hasNextMediaItem()) player.seekToNextMediaItem()
        else {
            player.pause()
            player.seekTo(0)
        }
    }
}
