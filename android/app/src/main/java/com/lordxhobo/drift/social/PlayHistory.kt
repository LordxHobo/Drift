package com.lordxhobo.drift.social

import android.content.Context
import com.lordxhobo.drift.playback.Playback
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.io.File
import java.util.Calendar
import java.util.TimeZone

/** One song you listened to (30 seconds or more, like Spotify counts it). Same as the iPhone's. */
@Serializable
data class PlayRecord(
    val id: String,
    val title: String,
    val artist: String,
    val art: String? = null,
    /** When it started (seconds since 1970). */
    val at: Long,
    /** How long you listened. */
    val secs: Long,
)

/**
 * What you've listened to, for Listening stats. Kept on this phone, and (with a Drift profile) also in your
 * synced library, one document per device and month ("plays-<device>-<yyyy-mm>"), so the stats add up
 * what you played on every device. Same format as the iPhone and the computer.
 */
object PlayHistory {
    /** Songs count once you've listened this long. */
    const val MINIMUM = 30

    @Serializable
    private data class Stored(val plays: List<PlayRecord> = emptyList(), val dirty: List<String> = emptyList())

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
    private lateinit var file: File

    var plays: List<PlayRecord> = emptyList()
        private set
    private val dirty = mutableSetOf<String>()
    private var changedAt = 0L
    private var uploadAt = 0L

    // The listen now (one song, from when it started).
    private var listenId: String? = null
    private var listened = 0.0
    private var lastPosition = 0L
    private var recorded: Int? = null

    fun init(context: Context) {
        file = File(context.filesDir, "plays.json")
        runCatching { json.decodeFromString(Stored.serializer(), file.readText()) }.getOrNull()?.let {
            plays = it.plays
            dirty += it.dirty
        }
        // Anything not sent last time goes in a minute.
        if (dirty.isNotEmpty()) uploadAt = System.currentTimeMillis() + 60_000
        scope.launch {
            var last = System.currentTimeMillis()
            while (true) {
                delay(1000)
                val now = System.currentTimeMillis()
                val elapsed = (now - last) / 1000.0
                last = now
                tick(elapsed)
                if (changedAt != 0L && now - changedAt >= 15_000) save()
                if (uploadAt != 0L && now >= uploadAt) {
                    uploadAt = 0
                    runCatching { upload() }
                }
            }
        }
    }

    /** Once a second: counts the time the song playing now has been listened to. */
    internal fun tick(elapsed: Double) {
        val t = Playback.current
        val pos = Playback.position
        // A new listen: another song, or the same one again from the start (repeat).
        if (t?.id != listenId || (pos < 5_000 && lastPosition > pos + 20_000)) {
            listenId = t?.id
            listened = 0.0
            recorded = null
        }
        lastPosition = pos
        if (t == null || !Playback.isPlaying || elapsed <= 0 || elapsed >= 2) return
        listened += elapsed
        if (listened < MINIMUM) return
        val i = recorded
        val nowSec = System.currentTimeMillis() / 1000
        if (i != null && i in plays.indices) {
            // Only every few seconds (the list is saved after each change).
            if (listened - plays[i].secs < 5) return
            plays = plays.toMutableList().also { it[i] = it[i].copy(secs = Math.round(listened)) }
            dirty += month(plays[i].at)
        } else {
            val start = nowSec - Math.round(listened)
            plays = plays + PlayRecord(t.id, t.title, t.artist, t.artwork(226), start, Math.round(listened))
            recorded = plays.size - 1
            dirty += month(start)
        }
        if (changedAt == 0L) changedAt = System.currentTimeMillis()
        if (uploadAt == 0L) uploadAt = System.currentTimeMillis() + 5 * 60_000
    }

    /** "2026-10" (UTC), the month a play's synced document is for. */
    fun month(at: Long): String {
        val c = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply { timeInMillis = at * 1000 }
        return "%04d-%02d".format(c.get(Calendar.YEAR), c.get(Calendar.MONTH) + 1)
    }

    private fun save() {
        changedAt = 0
        val text = json.encodeToString(Stored.serializer(), Stored(plays, dirty.toList()))
        scope.launch(Dispatchers.IO) {
            runCatching {
                val tmp = File(file.path + ".tmp")
                tmp.writeText(text)
                tmp.renameTo(file)
            }
        }
    }

    /** The synced format: songs once, then [id, start, seconds] for each play. */
    fun encode(list: List<PlayRecord>): String = buildJsonObject {
        put("tracks", buildJsonObject {
            for (p in list.distinctBy { it.id }) put(p.id, buildJsonArray { add(JsonPrimitive(p.title)); add(JsonPrimitive(p.artist)); add(JsonPrimitive(p.art ?: "")) })
        })
        put("plays", buildJsonArray { for (p in list) add(buildJsonArray { add(JsonPrimitive(p.id)); add(JsonPrimitive(p.at)); add(JsonPrimitive(p.secs)) }) })
    }.toString()

    fun decode(s: String?): List<PlayRecord> = runCatching {
        val o = Json.parseToJsonElement(s ?: "") as JsonObject
        val tracks = o["tracks"] as? JsonObject ?: JsonObject(emptyMap())
        (o["plays"] as? JsonArray).orEmpty().mapNotNull { r ->
            val row = (r as? JsonArray) ?: return@mapNotNull null
            if (row.size < 3) return@mapNotNull null
            val id = (row[0] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return@mapNotNull null
            val info = (tracks[id] as? JsonArray)?.takeIf { it.size >= 2 } ?: return@mapNotNull null
            PlayRecord(
                id = id,
                title = info[0].jsonPrimitive.content,
                artist = info[1].jsonPrimitive.content,
                art = info.getOrNull(2)?.jsonPrimitive?.content?.ifEmpty { null },
                at = row[1].jsonPrimitive.let { it.longOrNull ?: it.doubleOrNull?.toLong() } ?: 0,
                secs = row[2].jsonPrimitive.let { it.longOrNull ?: it.doubleOrNull?.toLong() } ?: 0,
            )
        }
    }.getOrDefault(emptyList())

    /** Sends the months with new plays to your synced library. */
    internal suspend fun upload() {
        val uid = Social.me?.id ?: return
        if (dirty.isEmpty()) return
        val device = ThisDevice.id
        for (m in dirty.sorted()) {
            val list = plays.filter { month(it.at) == m }
            withContext(Dispatchers.IO) {
                Firestore.patch(
                    "users/$uid/library/plays-$device-$m",
                    mapOf("plays" to FV.s(encode(list)), "device" to FV.s(device), "updatedAt" to FV.i(System.currentTimeMillis()), "deleted" to FV.b(false)),
                )
            }
            dirty -= m
        }
        save()
    }

    /** Everything you've listened to: this phone, plus your other devices (with a profile). */
    suspend fun everything(): Pair<List<PlayRecord>, Int> {
        val mine = plays
        val uid = Social.me?.id ?: return mine to 1
        val docs = withContext(Dispatchers.IO) { runCatching { Firestore.list("users/$uid/library", listOf("plays", "device")) }.getOrNull() } ?: return mine to 1
        val out = mine.toMutableList()
        val devices = mutableSetOf(ThisDevice.id)
        for ((name, f) in docs) {
            if (!name.startsWith("plays-")) continue
            val device = FV.string(f, "device") ?: continue
            if (device == ThisDevice.id) continue
            devices += device
            out += decode(FV.string(f, "plays"))
        }
        return out to devices.size
    }
}

// MARK: The numbers for a period (same as the computer's)

enum class StatsSpan(val label: String) { MONTH("4 weeks"), HALF_YEAR("6 months"), YEAR("This year"), ALL("All time") }

data class StatsSummary(
    val plays: List<PlayRecord>,
    val minutes: Long,
    val artistCount: Int,
    /** Calendar.DAY_OF_MONTH, WEEK_OF_YEAR or MONTH. */
    val unit: Int,
    /** Start (ms) and minutes of each bar. */
    val buckets: List<Pair<Long, Double>>,
    val topArtists: List<TopArtist>,
    val topSongs: List<TopSong>,
)

data class TopArtist(val name: String, val minutes: Long, val plays: Int, val art: String?)
data class TopSong(val play: PlayRecord, val plays: Int, val secs: Long)

object Stats {
    /** "Artist feat. Someone" and "A, B & C" count for the first artist. */
    fun mainArtist(s: String): String {
        val lower = s.lowercase()
        var cut = s.length
        for (sep in listOf(" feat. ", " ft. ", " featuring ", ", ", " & ", " x ", " · ")) {
            val i = lower.indexOf(sep)
            if (i in 0 until cut) cut = i
        }
        return s.substring(0, cut).trim().ifEmpty { s }
    }

    private fun startOfDay(c: Calendar): Calendar = (c.clone() as Calendar).apply {
        set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
    }

    private fun bucketStart(c: Calendar, unit: Int): Calendar = startOfDay(c).apply {
        when (unit) {
            Calendar.MONTH -> set(Calendar.DAY_OF_MONTH, 1)
            Calendar.WEEK_OF_YEAR -> add(Calendar.DAY_OF_MONTH, -((get(Calendar.DAY_OF_WEEK) + 5) % 7)) // weeks start on Monday
        }
    }

    private fun next(c: Calendar, unit: Int): Calendar = (c.clone() as Calendar).apply {
        when (unit) {
            Calendar.DAY_OF_MONTH -> add(Calendar.DAY_OF_MONTH, 1)
            Calendar.WEEK_OF_YEAR -> add(Calendar.DAY_OF_MONTH, 7)
            else -> add(Calendar.MONTH, 1)
        }
    }

    fun summarize(all: List<PlayRecord>, span: StatsSpan, nowMs: Long = System.currentTimeMillis()): StatsSummary {
        val now = Calendar.getInstance().apply { timeInMillis = nowMs }
        val from = startOfDay(now).apply {
            when (span) {
                StatsSpan.MONTH -> add(Calendar.DAY_OF_MONTH, -27)
                StatsSpan.HALF_YEAR -> add(Calendar.MONTH, -6)
                StatsSpan.YEAR -> set(Calendar.DAY_OF_YEAR, 1)
                StatsSpan.ALL -> timeInMillis = 0
            }
        }
        // The same play can't count twice (one per song and start time).
        val plays = all.filter { it.at * 1000 >= from.timeInMillis }.distinctBy { "${it.id}|${it.at}" }
        val unit = when (span) {
            StatsSpan.MONTH -> Calendar.DAY_OF_MONTH
            StatsSpan.HALF_YEAR -> Calendar.WEEK_OF_YEAR
            else -> Calendar.MONTH
        }
        val first = if (span == StatsSpan.ALL) Calendar.getInstance().apply { timeInMillis = minOf(plays.minOfOrNull { it.at * 1000 } ?: nowMs, nowMs) } else from
        val starts = mutableListOf<Long>()
        var d = bucketStart(first, unit)
        while (d.timeInMillis <= nowMs && starts.size < 400) {
            starts += d.timeInMillis
            d = next(d, unit)
        }
        val minutes = DoubleArray(starts.size)
        for (p in plays) {
            val t = p.at * 1000
            val i = starts.indexOfLast { it <= t }
            if (i >= 0) minutes[i] += p.secs / 60.0
        }
        data class A(val name: String, var secs: Long = 0, var plays: Int = 0, var art: String? = null)
        data class S(val play: PlayRecord, var plays: Int = 0, var secs: Long = 0)
        val artists = linkedMapOf<String, A>()
        val songs = linkedMapOf<String, S>()
        for (p in plays) {
            val name = mainArtist(p.artist)
            val a = artists.getOrPut(name) { A(name) }
            a.secs += p.secs
            a.plays += 1
            if (a.art == null) a.art = p.art
            val s = songs.getOrPut(p.id) { S(p) }
            s.plays += 1
            s.secs += p.secs
        }
        return StatsSummary(
            plays = plays,
            minutes = Math.round(plays.sumOf { it.secs } / 60.0),
            artistCount = artists.size,
            unit = unit,
            buckets = starts.mapIndexed { i, s -> s to minutes[i] },
            topArtists = artists.values.sortedWith(compareByDescending<A> { it.secs }.thenBy { it.name }).take(10)
                .map { TopArtist(it.name, Math.round(it.secs / 60.0), it.plays, it.art) },
            topSongs = songs.values.sortedWith(compareByDescending<S> { it.plays }.thenByDescending { it.secs }).take(10)
                .map { TopSong(it.play, it.plays, it.secs) },
        )
    }
}
