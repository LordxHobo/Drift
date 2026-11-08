package com.lordxhobo.drift.social

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
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/** A Listen Together session, as all Drift apps write it (jams/{code}). */
data class JamState(
    val code: String,
    val host: String,
    val members: List<String>,
    /** Profile ID → name. */
    val names: Map<String, String>,
    val track: Track?,
    /** What plays after it. */
    val queue: List<Track>,
    val playing: Boolean,
    /** Seconds, as of `at`. */
    val position: Double,
    /** When `position` was true (ms, the server's clock). */
    val at: Long,
    val version: Long,
    val updatedBy: String,
)

/** Someone inviting you to their session (users/{you}/invites/{them}). */
data class JamInvite(val from: String, val fromName: String, val code: String, val title: String, val artist: String, val at: Long)

/**
 * Listen Together: everyone's own Drift plays the music; one shared document keeps them in step.
 * What you do here (pick a song, play/pause, skip, jump, change what's next) goes to the session; what
 * someone else does is played here. When a song ends by itself, only the host says what's next.
 * Same documents and rules as the iPhone and the computer.
 */
object Jam {
    var state by mutableStateOf<JamState?>(null)
        private set
    /** Invites waiting for an answer (the first is shown). */
    var invites by mutableStateOf(listOf<JamInvite>())
        private set
    /** A short message to show (joined, ended…), cleared once shown. */
    var notice by mutableStateOf<String?>(null)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true }
    private val trackList = ListSerializer(Track.serializer())

    /** This phone's clock minus the server's (ms), from the quickest round trip so far. */
    private var offset = 0L
    private var bestTrip = Long.MAX_VALUE

    private var lastSignature = ""
    private var lastSeenAt = 0L
    private var lastPublishLocal = 0L
    private var lastSeeks = 0
    private var applyingUntil = 0L
    private var lastCorrection = 0L
    private var wasLoading = false
    private var loadedSettleUntil = 0L
    private var lastPoll = 0L
    private var lastInviteCheck = 0L
    private val asked = mutableSetOf<String>()

    private const val LETTERS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    private const val INVITE_MAX_AGE = 15 * 60_000L

    private fun path(c: String) = "jams/$c"
    private fun serverNow() = System.currentTimeMillis() - offset
    private fun me(): UserProfile = Social.me ?: throw IllegalStateException("Make a Drift profile first (Settings), so friends can find you.")

    fun init() {
        scope.launch {
            while (true) {
                delay(500)
                if (Social.me == null) continue
                runCatching { tick() }
                val now = System.currentTimeMillis()
                if (state != null && now - lastPoll >= 2000) {
                    lastPoll = now
                    runCatching { poll() }
                }
                if (now - lastInviteCheck >= 10_000) {
                    lastInviteCheck = now
                    runCatching { checkInvites() }
                }
            }
        }
    }

    // MARK: The server's clock

    private val rfc = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }

    /** "2026-11-08T12:00:00.123456Z" → ms. */
    internal fun parseTime(s: String?): Long? {
        if (s == null || s.length < 19) return null
        val base = runCatching { synchronized(rfc) { rfc.parse(s.substring(0, 19)) } }.getOrNull()?.time ?: return null
        val frac = if (s.length > 19 && s[19] == '.') s.substring(20).takeWhile { it.isDigit() } else ""
        return base + (frac.padEnd(3, '0').take(3).toLongOrNull() ?: 0)
    }

    /** Learns how far this clock is from the server's, from a write's own time stamp. */
    private fun timed(write: () -> String?): String? {
        val sent = System.currentTimeMillis()
        val updateTime = write()
        val back = System.currentTimeMillis()
        val server = parseTime(updateTime)
        if (server != null && back - sent < bestTrip) {
            bestTrip = back - sent
            offset = (sent + back) / 2 - server
        }
        return updateTime
    }

    // MARK: The session document

    private fun parse(c: String, doc: JsonObject?): JamState? {
        val f = FV.fields(doc) ?: return null
        val host = FV.string(f, "host") ?: return null
        val names = FV.mapFields(f, "names").orEmpty().mapNotNull { (k, v) -> FV.str((v as? JsonObject)?.get("stringValue"))?.let { k to it } }.toMap()
        return JamState(
            code = c,
            host = host,
            members = FV.stringArray(f, "members"),
            names = names,
            track = runCatching { json.decodeFromString(Track.serializer(), FV.string(f, "track") ?: "null") }.getOrNull(),
            queue = runCatching { json.decodeFromString(trackList, FV.string(f, "queue") ?: "[]") }.getOrDefault(emptyList()),
            playing = FV.bool(f, "playing") ?: false,
            position = FV.number(f, "position") ?: 0.0,
            at = FV.long(f, "at") ?: 0,
            version = FV.long(f, "version") ?: 0,
            updatedBy = FV.string(f, "updatedBy") ?: host,
        )
    }

    private fun namesField(names: Map<String, String>): JsonElement = FV.map(names.mapValues { FV.s(it.value) })

    /** Shows the code on your profile, so friends can join from their Friends list. */
    private suspend fun showOnProfile(c: String?) {
        val uid = Social.me?.id ?: return
        withContext(Dispatchers.IO) {
            runCatching { Firestore.patch("users/$uid", mapOf("jam" to (c?.let { FV.s(it) } ?: FV.nul)), mask = listOf("jam")) }
        }
        Social.updateMe { it.copy(jam = c) }
    }

    private suspend fun poll() {
        val uid = Social.me?.id ?: return
        val c = state?.code ?: return
        val doc = withContext(Dispatchers.IO) { Firestore.get(path(c)) }
        if (state?.code != c) return
        val s = parse(c, doc)
        if (s == null || uid !in s.members) return end()
        received(s)
    }

    private fun end() {
        if (state == null) return
        state = null
        notice = "Listen Together ended"
        scope.launch { showOnProfile(null) }
    }

    suspend fun start() {
        val me = me()
        if (state != null) leave()
        repeat(5) {
            val c = (1..6).map { LETTERS.random() }.joinToString("")
            try {
                withContext(Dispatchers.IO) {
                    timed {
                        Firestore.patch(
                            path(c),
                            mapOf(
                                "host" to FV.s(me.id), "members" to FV.strings(listOf(me.id)), "names" to namesField(mapOf(me.id to me.name)),
                                "track" to FV.s("null"), "queue" to FV.s("[]"), "playing" to FV.b(false), "position" to FV.d(0.0),
                                "at" to FV.i(serverNow()), "version" to FV.i(1), "updatedBy" to FV.s(me.id), "createdAt" to FV.i(System.currentTimeMillis()),
                            ),
                            mustNotExist = true,
                        )
                    }
                }
            } catch (e: UsernameTakenException) {
                return@repeat // that code is taken: another one
            }
            val s = withContext(Dispatchers.IO) { parse(c, Firestore.get(path(c))) } ?: throw IllegalStateException("Couldn't start a session. Try again.")
            state = s
            lastSeenAt = s.at
            showOnProfile(c)
            // Share what's on here.
            if (Playback.current != null) publish()
            return
        }
        throw IllegalStateException("Couldn't start a session. Try again.")
    }

    suspend fun join(raw: String) {
        val me = me()
        val c = raw.trim().uppercase().filter { it in 'A'..'Z' || it in '0'..'9' }
        if (c == state?.code) return
        if (state != null) leave()
        repeat(3) {
            val doc = withContext(Dispatchers.IO) {
                try {
                    Firestore.get(path(c))
                } catch (e: SocialException) {
                    if (e.status == 403) null else throw e
                }
            } ?: throw IllegalStateException("No session with that code. It may have ended.")
            val s = parse(c, doc) ?: throw IllegalStateException("No session with that code.")
            if (me.id !in s.members) {
                try {
                    withContext(Dispatchers.IO) {
                        timed {
                            Firestore.patch(
                                path(c),
                                mapOf("members" to FV.strings(s.members + me.id), "names" to namesField(s.names + (me.id to me.name))),
                                mask = listOf("members", "names"),
                                updateTime = FV.str(doc["updateTime"]),
                            )
                        }
                    }
                } catch (e: ChangedMeanwhileException) {
                    return@repeat // someone else joined at the same moment
                }
            }
            val now = withContext(Dispatchers.IO) { parse(c, Firestore.get(path(c))) } ?: throw IllegalStateException("Couldn't join. Try again.")
            state = now
            showOnProfile(c)
            invites = invites.filter { it.code != c }
            if (now.track != null) apply(now)
            return
        }
        throw IllegalStateException("Couldn't join. Try again.")
    }

    /** Leaving: the host ends it for everyone; anyone else just leaves. */
    suspend fun leave() {
        val s = state ?: return
        val uid = Social.me?.id
        state = null
        try {
            withContext(Dispatchers.IO) {
                if (s.host == uid) Firestore.delete(path(s.code))
                else if (uid != null) {
                    for (attempt in 0 until 3) {
                        val doc = Firestore.get(path(s.code)) ?: break
                        val now = parse(s.code, doc) ?: break
                        try {
                            Firestore.patch(path(s.code), mapOf("members" to FV.strings(now.members - uid)), mask = listOf("members"), updateTime = FV.str(doc["updateTime"]))
                            break
                        } catch (e: ChangedMeanwhileException) {
                            // someone changed it at the same moment: try again
                        }
                    }
                }
            }
        } catch (e: Exception) {
            // offline: the session notices we're gone when it's next checked
        } finally {
            showOnProfile(null)
        }
    }

    // MARK: Keeping in step

    private fun signature(track: Track?, playing: Boolean, queue: List<Track>) =
        "${track?.id ?: ""}|$playing|${queue.take(30).joinToString(",") { it.id }}"

    /** Where the session is now (seconds). */
    private fun expected(s: JamState): Double {
        if (!s.playing) return s.position
        return s.position + maxOf(0L, serverNow() - s.at) / 1000.0
    }

    private fun apply(s: JamState) {
        lastSeenAt = s.at
        val t = s.track ?: return
        // A moment for the player to settle, so it isn't mistaken for a change here.
        applyingUntil = System.currentTimeMillis() + 1200
        Playback.jamPlay(t, s.queue, expected(s), s.playing)
        lastSignature = signature(t, s.playing, s.queue)
        lastSeeks = Playback.seeks
    }

    private fun received(s: JamState) {
        val me = Social.me?.id
        state = s
        if (s.at == lastSeenAt) return
        // Someone else's change, made after this phone's last one (older answers are ignored).
        if (s.updatedBy != me && s.at + offset > lastPublishLocal - 300) apply(s) else lastSeenAt = s.at
    }

    /** Someone here changed what's playing: send it to everyone. */
    private fun publish() {
        val s = state ?: return
        val track = Playback.current
        val queue = if (track != null) Playback.upNext.take(30) else emptyList()
        val playing = track != null && Playback.isPlaying
        val position = Playback.exactPosition() / 1000.0
        lastSignature = signature(track, playing, queue)
        lastSeeks = Playback.seeks
        lastPublishLocal = System.currentTimeMillis()
        val uid = Social.me?.id ?: return
        val at = serverNow()
        val version = s.version + 1
        state = s.copy(track = track, queue = queue, playing = playing, position = position, at = at, version = version, updatedBy = uid)
        lastSeenAt = at
        val fields = mapOf(
            "track" to FV.s(if (track != null) json.encodeToString(Track.serializer(), track) else "null"),
            "queue" to FV.s(json.encodeToString(trackList, queue)),
            "playing" to FV.b(playing),
            "position" to FV.d(position),
            "at" to FV.i(at),
            "version" to FV.i(version),
            "updatedBy" to FV.s(uid),
        )
        scope.launch {
            withContext(Dispatchers.IO) { runCatching { timed { Firestore.patch(path(s.code), fields, mask = fields.keys.toList()) } } }
        }
    }

    /** Twice a second while in a session. */
    private fun tick() {
        val s = state ?: return
        val now = System.currentTimeMillis()
        if (now < applyingUntil) return
        // Still loading the song: nothing to tell the others yet (it looks paused at 0:00 meanwhile).
        if (Playback.isBuffering) {
            wasLoading = true
            return
        }
        // …and a moment after, while it settles into playing.
        if (wasLoading) {
            wasLoading = false
            loadedSettleUntil = now + 800
        }
        if (now < loadedSettleUntil) return
        val track = Playback.current
        val queue = if (track != null) Playback.upNext.take(30) else emptyList()
        val playing = track != null && Playback.isPlaying
        val sig = signature(track, playing, queue)
        if (sig != lastSignature) {
            // A song ended by itself and the next one started: the host announces it, everyone else waits.
            val natural = now - Playback.naturalEndAt < 4000
            if (natural && s.host != Social.me?.id) {
                lastSignature = sig
                return
            }
            publish()
            return
        }
        if (Playback.seeks != lastSeeks) {
            publish()
            return
        }
        // Drifted apart (a slow connection, a pause to load): catch up quietly, at most every 5 s.
        if (s.playing && playing && s.track?.id == track?.id && now - lastCorrection > 5000) {
            val gap = Playback.exactPosition() / 1000.0 - expected(s)
            if (kotlin.math.abs(gap) > 1.2) {
                lastCorrection = now
                apply(s)
            }
        }
    }

    // MARK: Invites

    /** Friends you can invite: they follow you back and accept invites (the server checks this too). */
    fun invitable(friends: List<UserProfile>): List<UserProfile> {
        val uid = Social.me?.id ?: return emptyList()
        return friends.filter { uid in it.following && it.allowInvites != false }
    }

    /** Plays the song, starts a session if needed, and invites these friends. Returns how many failed. */
    suspend fun invite(friendIds: List<String>, track: Track): Int {
        val me = me()
        Playback.play(listOf(track), 0, track.title)
        if (state == null) start()
        val c = state?.code ?: return friendIds.size
        var failed = 0
        withContext(Dispatchers.IO) {
            for (id in friendIds) {
                try {
                    Firestore.patch(
                        "users/$id/invites/${me.id}",
                        mapOf(
                            "from" to FV.s(me.id), "fromName" to FV.s(me.name), "code" to FV.s(c),
                            "title" to FV.s(track.title), "artist" to FV.s(track.artist), "at" to FV.i(System.currentTimeMillis()),
                        ),
                    )
                } catch (e: Exception) {
                    failed++
                }
            }
        }
        return failed
    }

    private suspend fun checkInvites() {
        val mine = Social.me ?: return
        if (mine.allowInvites == false) return
        val docs = withContext(Dispatchers.IO) { Firestore.list("users/${mine.id}/invites", listOf("from", "fromName", "code", "title", "artist", "at")) }
        val fresh = mutableListOf<JamInvite>()
        for ((_, f) in docs) {
            val from = FV.string(f, "from") ?: continue
            val code = FV.string(f, "code") ?: continue
            val i = JamInvite(from, FV.string(f, "fromName") ?: "A friend", code, FV.string(f, "title") ?: "", FV.string(f, "artist") ?: "", FV.long(f, "at") ?: 0)
            val key = "${i.from}|${i.code}|${i.at}"
            // Old, already asked about, or for the session you're in: cleared quietly.
            if (System.currentTimeMillis() - i.at > INVITE_MAX_AGE || key in asked || state?.code == i.code) {
                withContext(Dispatchers.IO) { runCatching { Firestore.delete("users/${mine.id}/invites/$from") } }
                continue
            }
            asked += key
            fresh += i
        }
        if (fresh.isNotEmpty()) invites = invites + fresh.filter { n -> invites.none { it.from == n.from && it.code == n.code } }
    }

    /** Answers the first invite: joins, or declines. */
    suspend fun answer(invite: JamInvite, accept: Boolean) {
        invites = invites.filter { it !== invite }
        val uid = Social.me?.id
        if (uid != null) withContext(Dispatchers.IO) { runCatching { Firestore.delete("users/$uid/invites/${invite.from}") } }
        if (accept) {
            join(invite.code)
            notice = "Listening together with ${invite.fromName}"
        }
    }
}
