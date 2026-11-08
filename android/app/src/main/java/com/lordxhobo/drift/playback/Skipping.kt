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

/** A part of a video the SponsorBlock community marked as skippable (seconds). */
data class SkipSegment(val start: Double, val end: Double, val category: String = "")

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
    /** Episodes: skip sponsor reads, self-promotion and "like and subscribe" reminders. */
    var sponsors by mutableStateOf(true)
        private set
    /** How fast episodes play (music always plays at its own speed). */
    var podcastSpeed by mutableStateOf(1f)
        private set
    val speeds = listOf(0.75f, 1f, 1.25f, 1.5f, 1.75f, 2f)
    private lateinit var prefs: SharedPreferences

    fun init(context: Context) {
        prefs = context.getSharedPreferences("drift.settings", Context.MODE_PRIVATE)
        nonMusic = prefs.getBoolean("skipNonMusic", true)
        silence = prefs.getBoolean("skipSilence", true)
        sponsors = prefs.getBoolean("skipSponsors", true)
        podcastSpeed = prefs.getFloat("podcastSpeed", 1f)
    }

    fun changeSponsors(on: Boolean) {
        sponsors = on
        prefs.edit().putBoolean("skipSponsors", on).apply()
    }

    fun changeSpeed(v: Float) {
        podcastSpeed = v
        prefs.edit().putFloat("podcastSpeed", v).apply()
    }

    fun changeNonMusic(on: Boolean) {
        nonMusic = on
        prefs.edit().putBoolean("skipNonMusic", on).apply()
    }

    fun changeSilence(on: Boolean) {
        silence = on
        prefs.edit().putBoolean("skipSilence", on).apply()
    }

    /** A video's skippable parts: not music in a song, sponsors and the like in an episode (none when SponsorBlock has nothing, or can't be reached). */
    fun segments(videoId: String, podcast: Boolean = false): List<SkipSegment> = runCatching {
        val b = "https://sponsor.ajay.app/api/skipSegments".toHttpUrl().newBuilder().addQueryParameter("videoID", videoId)
        for (c in if (podcast) listOf("sponsor", "selfpromo", "interaction") else listOf("music_offtopic")) b.addQueryParameter("category", c)
        val url = b.build()
        HttpDownloader.shared.client.newCall(Request.Builder().url(url).build()).execute().use { res ->
            if (res.code != 200) return@use emptyList()
            val list = Json.parseToJsonElement(res.body?.string() ?: "[]") as? JsonArray ?: return@use emptyList()
            list.mapNotNull { e ->
                val seg = (e as? JsonObject)?.get("segment") as? JsonArray ?: return@mapNotNull null
                if (seg.size != 2) return@mapNotNull null
                val start = seg[0].jsonPrimitive.doubleOrNull ?: return@mapNotNull null
                val end = seg[1].jsonPrimitive.doubleOrNull ?: return@mapNotNull null
                val category = (e["category"] as? kotlinx.serialization.json.JsonPrimitive)?.content ?: ""
                if (end - start >= 1) SkipSegment(start, end, category) else null
            }.sortedBy { it.start }
        }
    }.getOrDefault(emptyList())

    /** "sponsor", "non-music intro", "non-music outro"… */
    fun label(s: SkipSegment, duration: Double): String = when {
        s.category == "sponsor" -> "sponsor"
        s.category == "selfpromo" -> "self-promotion"
        s.category == "interaction" -> "subscribe reminder"
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
    // The episode playing, to save where it was left.
    private var episode: Track? = null
    private var episodePos = 0.0
    private var episodeDur = 0.0
    private var wasPlaying = false
    private var lastProgress = 0L

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
            // The episode that was playing: where it was left (or finished).
            saveEpisode(force = true)
            songId = id
            segments = emptyList()
            skipped.clear()
            silentSince = 0
            heard = false
            Level.take()
            val t = track()
            episode = t?.takeIf { it.isEpisode }
            episodePos = 0.0
            episodeDur = 0.0
            wasPlaying = false
            // Episodes at their own speed; music at its own.
            val speed = if (episode != null) Skipping.podcastSpeed else 1f
            if (player.playbackParameters.speed != speed) player.setPlaybackSpeed(speed)
            val podcast = episode != null
            // SponsorBlock knows YouTube videos (not a show's own audio files).
            if (id != null && !id.startsWith("rss-") && (if (podcast) Skipping.sponsors else Skipping.nonMusic)) {
                thread(isDaemon = true) {
                    val list = Skipping.segments(id, podcast)
                    main.post { if (songId == id) segments = list }
                }
            }
        }
        val t = track()
        val d = duration(t)
        val now = player.currentPosition / 1000.0
        if (episode != null) {
            episodePos = now
            if (d > 0) episodeDur = d
            val playing = player.isPlaying
            // Every few seconds while it plays, and right away when it's paused.
            if (playing && SystemClock.elapsedRealtime() - lastProgress > 5_000) saveEpisode(force = false)
            else if (!playing && wasPlaying) saveEpisode(force = true)
            wasPlaying = playing
            val speed = Skipping.podcastSpeed
            if (player.playbackParameters.speed != speed) player.setPlaybackSpeed(speed)
        }
        if (id == null || !player.isPlaying) {
            silentSince = 0
            return
        }
        // Played again from the start (repeat): its parts can be skipped again.
        if (now < 1 && skipped.isNotEmpty()) skipped.clear()

        // Non-music parts.
        if (segments.isNotEmpty()) {
            val on = if (episode != null) Skipping.sponsors else Skipping.nonMusic
            val seg = if (!on) null else segments.firstOrNull { now >= it.start && now < it.end - 0.5 && it.start !in skipped }
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
        // Not for episodes: talk has its pauses.
        if (!Skipping.silence || loudest == null || episode != null) {
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

    private fun saveEpisode(force: Boolean) {
        val e = episode ?: return
        if (episodeDur <= 0 || episodePos <= 0) return
        lastProgress = SystemClock.elapsedRealtime()
        com.lordxhobo.drift.podcasts.PodcastStore.update(e, episodePos, episodeDur, force)
    }

    private fun nextSong() {
        if (player.hasNextMediaItem()) player.seekToNextMediaItem()
        else {
            player.pause()
            player.seekTo(0)
        }
    }
}
