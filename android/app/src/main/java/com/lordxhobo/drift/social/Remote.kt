package com.lordxhobo.drift.social

import android.content.Context
import android.os.Build
import android.provider.Settings
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.lordxhobo.drift.data.Track
import com.lordxhobo.drift.playback.Playback
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.util.UUID

/** This phone, as your other devices see it (the same ID names its listening history). */
object ThisDevice {
    lateinit var id: String
        private set
    lateinit var name: String
        private set

    fun init(context: Context) {
        val prefs = context.getSharedPreferences("drift.settings", Context.MODE_PRIVATE)
        // Short, letters and digits only (like the iPhone's "ios…" and the computer's "pc…"): it's part of
        // field names in the synced library, where a "-" isn't allowed.
        id = prefs.getString("deviceId", null)?.takeIf { it.all { c -> c.isLetterOrDigit() } }
            ?: ("and" + UUID.randomUUID().toString().replace("-", "").take(8).lowercase()).also {
                prefs.edit().putString("deviceId", it).apply()
            }
        // The name you gave the phone (Settings → About phone), else its model.
        name = (if (Build.VERSION.SDK_INT >= 25) runCatching { Settings.Global.getString(context.contentResolver, "device_name") }.getOrNull() else null)
            ?.takeIf { it.isNotBlank() }
            ?: (Build.MANUFACTURER.replaceFirstChar { it.uppercase() } + " " + Build.MODEL).trim()
    }
}

/** What a device plays, as all Drift apps write it (one field per device in library/devices). */
@Serializable
data class RemoteDevice(
    val id: String,
    val name: String,
    /** "phone" or "computer". */
    val kind: String = "phone",
    /** When it last said so (ms since 1970). */
    val at: Long = 0,
    val track: Track? = null,
    val queue: List<Track> = emptyList(),
    val playing: Boolean = false,
    /** Seconds; measured at `positionAt` (ms since 1970). */
    val position: Double = 0.0,
    val positionAt: Long = 0,
    val duration: Double = 0.0,
    val volume: Double = 1.0,
    val shuffle: Boolean = false,
    val repeat: String = "off",
    val source: String? = null,
) {
    /** Heard from in the last 75 s. */
    val online: Boolean get() = System.currentTimeMillis() - at < 75_000

    /** Where it is now (moving on from the last report while it plays). */
    fun positionNow(now: Long = System.currentTimeMillis()): Double {
        if (!playing) return position
        val p = position + maxOf(0L, now - positionAt) / 1000.0
        return if (duration > 0) minOf(p, duration) else p
    }
}

@Serializable
data class RemoteCommand(
    val id: Long,
    val from: String,
    /** transfer, play, toggle, resume, pause, next, previous, seek, volume, shuffle, repeat, playNext, addToQueue */
    val type: String,
    val track: Track? = null,
    val tracks: List<Track>? = null,
    val queue: List<Track>? = null,
    val start: Int? = null,
    val position: Double? = null,
    val playing: Boolean? = null,
    val value: Double? = null,
    val on: Boolean? = null,
    val mode: String? = null,
    val source: String? = null,
)

/**
 * Control another device, like Spotify Connect: tells your other devices what this phone plays, runs the
 * commands they send, and sends commands to the one you control from here. Everything goes through your
 * synced library (only you can read it), the same as the iPhone and the computer.
 */
object Remote {
    /** The device controlled from here, or null (playing here). */
    var target by mutableStateOf<String?>(null)
        private set
    var devices by mutableStateOf(listOf<RemoteDevice>())
        private set
    var error by mutableStateOf<String?>(null)
        private set

    val targetDevice: RemoteDevice? get() = devices.firstOrNull { it.id == target }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true }
    private var changed = false
    private var lastPublish = 0L
    private var lastPoll = 0L
    private var lastWake = 0L
    private var awakeUntil = 0L
    private var lastCommand: Long? = null
    private var lastSig = ""

    fun init() {
        Playback.onChange.add { _, _ -> changed = true }
        scope.launch {
            while (true) {
                delay(500)
                if (Social.me != null) runCatching { step() }
            }
        }
    }

    private suspend fun step() {
        val now = System.currentTimeMillis()
        if (now - lastPoll >= if (now < awakeUntil) 1000 else 6000) {
            lastPoll = now
            poll()
        }
        // What plays here: when it changes, and every 30 s while Drift runs (so it shows as online).
        val sig = listOf(Playback.current?.id, Playback.isPlaying, Playback.shuffle, Playback.repeat, Playback.queue.size, Playback.volume).joinToString("|")
        if (sig != lastSig) {
            lastSig = sig
            changed = true
        }
        if ((changed && now - lastPublish >= 400) || now - lastPublish >= 30_000) {
            changed = false
            publish()
        }
        val t = target
        if (t != null && now - lastWake >= 20_000) {
            lastWake = now
            withContext(Dispatchers.IO) {
                Firestore.patch("users/${Social.me?.id}/library/remote-$t", mapOf("awakeUntil" to FV.i(now + 90_000)), mask = listOf("awakeUntil"))
            }
        }
    }

    private fun localState(): RemoteDevice {
        val cur = Playback.current
        return RemoteDevice(
            id = ThisDevice.id,
            name = ThisDevice.name,
            kind = "phone",
            at = System.currentTimeMillis(),
            track = cur,
            queue = if (cur != null) Playback.upNext.take(30) else emptyList(),
            playing = cur != null && Playback.isPlaying,
            position = Playback.position / 1000.0,
            positionAt = System.currentTimeMillis(),
            duration = Playback.duration / 1000.0,
            volume = Playback.volume.toDouble(),
            shuffle = Playback.shuffle,
            repeat = Playback.repeat.name.lowercase(),
            source = Playback.playingFrom.ifEmpty { null },
        )
    }

    private suspend fun publish() {
        val uid = Social.me?.id ?: return
        lastPublish = System.currentTimeMillis()
        val d = localState()
        val field = "d_${d.id}"
        withContext(Dispatchers.IO) {
            Firestore.patch("users/$uid/library/devices", mapOf(field to FV.s(json.encodeToString(RemoteDevice.serializer(), d))), mask = listOf(field))
        }
    }

    private fun parseCommands(s: String?): List<RemoteCommand> =
        runCatching { json.decodeFromString(ListSerializer(RemoteCommand.serializer()), s ?: "[]") }.getOrDefault(emptyList())

    private suspend fun poll() {
        val uid = Social.me?.id ?: return
        val doc = withContext(Dispatchers.IO) { runCatching { Firestore.get("users/$uid/library/remote-${ThisDevice.id}") }.getOrNull() }
        val f = FV.fields(doc)
        awakeUntil = FV.long(f, "awakeUntil") ?: 0
        val list = parseCommands(FV.string(f, "cmds"))
        // First look: what was sent before Drift opened doesn't count.
        val last = lastCommand
        if (last == null) {
            lastCommand = list.maxOfOrNull { it.id } ?: 0
            return
        }
        val fresh = list.filter { it.id > last }.sortedBy { it.id }
        if (fresh.isEmpty()) return
        lastCommand = fresh.last().id
        val now = System.currentTimeMillis()
        for (c in fresh) if (now - c.id / 1000 < 60_000) run(c)
        awakeUntil = maxOf(awakeUntil, now + 90_000)
    }

    /** Does what another device asked. */
    private fun run(c: RemoteCommand) {
        if (c.type == "transfer" || c.type == "play") stopControlling()
        when (c.type) {
            "transfer" -> c.track?.let { Playback.transferIn(it, c.queue.orEmpty(), c.position ?: 0.0, c.playing ?: true, c.source ?: "") }
            "play" -> c.tracks?.takeIf { it.isNotEmpty() }?.let { Playback.play(it, c.start ?: 0, c.source?.ifEmpty { null } ?: "Another device") }
            "toggle" -> Playback.toggle()
            "resume" -> Playback.resume()
            "pause" -> Playback.pause()
            "next" -> Playback.next()
            "previous" -> Playback.previous()
            "seek" -> c.position?.let { Playback.seek((it * 1000).toLong()) }
            // The other apps send the sound's real level; the player's volume is on the same scale.
            "volume" -> c.value?.let { Playback.changeVolume(it.toFloat()) }
            "shuffle" -> c.on?.let { Playback.shuffleTo(it) }
            "repeat" -> c.mode?.let { Playback.repeatTo(it) }
            "playNext" -> c.track?.let { Playback.playNext(it) }
            "addToQueue" -> c.track?.let { Playback.addToQueue(it) }
        }
    }

    // MARK: Controlling another device

    /** Your other devices (not this phone), newest first. */
    suspend fun refresh() {
        val uid = Social.me?.id ?: return
        try {
            val f = withContext(Dispatchers.IO) { FV.fields(Firestore.get("users/$uid/library/devices")) }
            val me = "d_${ThisDevice.id}"
            devices = f.orEmpty().keys.filter { it.startsWith("d_") && it != me }.mapNotNull { k ->
                runCatching { json.decodeFromString(RemoteDevice.serializer(), FV.string(f, k) ?: "") }.getOrNull()
            }.sortedByDescending { it.at }
            error = null
        } catch (e: Exception) {
            error = "Couldn't reach Drift's server. Check your connection."
        }
    }

    /** Sends a command to the device you control (or `to`), and shows the change right away. */
    fun send(type: String, to: String? = null, build: (RemoteCommand) -> RemoteCommand = { it }) {
        val id = to ?: target ?: return
        val uid = Social.me?.id ?: return
        val c = build(RemoteCommand(id = System.currentTimeMillis() * 1000 + (0..999).random(), from = ThisDevice.id, type = type))
        devices = devices.map { if (it.id == id) optimistic(it, c) else it }
        scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    val path = "users/$uid/library/remote-$id"
                    val list = (parseCommands(FV.string(FV.fields(runCatching { Firestore.get(path) }.getOrNull()), "cmds")) + c).takeLast(20)
                    Firestore.patch(
                        path,
                        mapOf("cmds" to FV.s(json.encodeToString(ListSerializer(RemoteCommand.serializer()), list)), "awakeUntil" to FV.i(System.currentTimeMillis() + 90_000)),
                        mask = listOf("cmds", "awakeUntil"),
                    )
                }
                delay(700)
                refresh()
            } catch (e: Exception) {
                error = "Couldn't reach your other device. Check your connection."
            }
        }
    }

    private fun optimistic(d: RemoteDevice, c: RemoteCommand): RemoteDevice {
        val now = System.currentTimeMillis()
        return when (c.type) {
            "toggle", "resume", "pause" -> d.copy(
                position = d.positionNow(now), positionAt = now,
                playing = if (c.type == "toggle") !d.playing else c.type == "resume",
            )
            "seek" -> d.copy(position = c.position ?: d.position, positionAt = now)
            "volume" -> d.copy(volume = c.value ?: d.volume)
            "shuffle" -> d.copy(shuffle = c.on ?: d.shuffle)
            "repeat" -> d.copy(repeat = c.mode ?: d.repeat)
            else -> d
        }
    }

    /** Plays on another device: what plays here moves there (and stops here). */
    fun connect(id: String) {
        if (target == id) return
        stopControlling()
        val cur = Playback.current
        if (cur != null) {
            send("transfer", to = id) {
                it.copy(
                    track = cur, queue = Playback.upNext.take(50), position = Playback.position / 1000.0,
                    playing = Playback.isPlaying, source = Playback.playingFrom,
                )
            }
            Playback.pause()
        }
        target = id
        lastWake = 0
    }

    /** Back to playing on this phone: picks up where the other device is, and pauses it. */
    fun playHere() {
        val d = targetDevice
        if (d?.playing == true) send("pause")
        stopControlling()
        val t = d?.track ?: return
        Playback.transferIn(t, d.queue, d.positionNow(), d.playing, d.source ?: "")
    }

    /** Stops controlling the other device (it keeps playing). */
    fun stopControlling() {
        target = null
    }
}
