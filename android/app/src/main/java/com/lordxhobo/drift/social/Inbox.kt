package com.lordxhobo.drift.social

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.lordxhobo.drift.Notices
import com.lordxhobo.drift.data.Track
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json

/** A song a friend sent you (users/{you}/inbox/{them}_{ms}). */
data class InboxItem(
    /** The document's name: who sent it and when. */
    val id: String,
    val from: String,
    val fromName: String,
    val track: Track,
    /** What they wrote with it ("" for none). */
    val note: String,
    /** ms since 1970. */
    val at: Long,
    /** Opened on one of your devices. */
    val seen: Boolean,
)

/**
 * Sending songs to friends (from a song's menu) and the inbox of songs friends sent you (Friends →
 * Inbox). The server only accepts a song when you follow each other and they allow it. Same documents
 * as the iPhone and the computer.
 */
object Inbox {
    /** Songs friends sent you, newest first. */
    var items by mutableStateOf(listOf<InboxItem>())
        private set
    val unseen: Int get() = items.count { !it.seen }

    /** Opened from a notification: Friends shows the inbox. */
    var openInbox by mutableStateOf(false)
    /** The song being sent (the send sheet is open). */
    var sending by mutableStateOf<Track?>(null)
    /** Drift is on screen (set by the activity): no notification then. */
    @Volatile var onScreen = false

    /** A note is at most this long (the server checks it too). */
    const val MAX_NOTE = 280
    private const val KEEP_FOR = 30 * 86_400_000L

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val mutex = Mutex()
    private val notified = mutableSetOf<String>()
    private var firstCheck = true
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    /** Looks for new songs every 20 s while Drift is open, 45 s while it plays in the background. */
    fun init() {
        scope.launch {
            delay(4000)
            while (true) {
                runCatching { check() }
                delay(if (onScreen) 20_000 else 45_000)
            }
        }
    }

    /** Friends you can send songs to: they follow you back and accept songs (the server checks this too). */
    fun sendable(friends: List<UserProfile>): List<UserProfile> {
        val uid = Social.me?.id ?: return emptyList()
        return friends.filter { uid in it.following && it.allowSongs != false }
    }

    /** What travels with a sent song: what's needed to play it, nothing from your library. */
    private fun songOnly(t: Track) = t.copy(added = null, addedBy = null)

    /** Sends a song to these friends with an optional note. Returns the ids it couldn't send to. */
    suspend fun send(friendIds: List<String>, track: Track, note: String): List<String> {
        val me = Social.me ?: throw IllegalStateException("Make a Drift profile first (Settings), so friends can find you.")
        val body = json.encodeToString(Track.serializer(), songOnly(track))
        val text = note.trim().take(MAX_NOTE)
        val failed = mutableListOf<String>()
        withContext(Dispatchers.IO) {
            for (id in friendIds) {
                val at = System.currentTimeMillis()
                val fields = mutableMapOf(
                    "from" to FV.s(me.id), "fromName" to FV.s(me.name), "track" to FV.s(body), "at" to FV.i(at),
                )
                if (text.isNotEmpty()) fields["note"] = FV.s(text)
                try {
                    Firestore.patch("users/$id/inbox/${me.id}_$at", fields, mustNotExist = true)
                } catch (e: Exception) {
                    failed.add(id)
                }
            }
        }
        return failed
    }

    suspend fun check() = mutex.withLock {
        val me = Social.me
        if (me == null) {
            if (items.isNotEmpty()) items = emptyList()
            return@withLock
        }
        val docs = withContext(Dispatchers.IO) {
            Firestore.list("users/${me.id}/inbox", listOf("from", "fromName", "track", "note", "at", "seen"))
        }
        val now = System.currentTimeMillis()
        val next = mutableListOf<InboxItem>()
        for ((id, f) in docs) {
            val from = FV.string(f, "from") ?: continue
            val raw = FV.string(f, "track") ?: continue
            val t = runCatching { json.decodeFromString(Track.serializer(), raw) }.getOrNull() ?: continue
            if (t.id.isEmpty() || t.title.isEmpty()) continue
            val i = InboxItem(
                id = id, from = from, fromName = FV.string(f, "fromName") ?: "A friend", track = t,
                note = FV.string(f, "note") ?: "", at = FV.long(f, "at") ?: 0, seen = FV.bool(f, "seen") ?: false,
            )
            // Old ones are cleared.
            if (now - i.at > KEEP_FOR) {
                scope.launch(Dispatchers.IO) { runCatching { Firestore.delete("users/${me.id}/inbox/$id") } }
                continue
            }
            next.add(i)
        }
        next.sortByDescending { it.at }
        // A notification for each new one while Drift isn't on screen (not for what was there before).
        for (i in next) {
            if (!notified.add(i.id)) continue
            if (!firstCheck && !i.seen && !onScreen) Notices.showSong(i)
        }
        firstCheck = false
        if (next != items) items = next
    }

    /** Marks these as seen (on every device). */
    fun markSeen(ids: Collection<String>) {
        val uid = Social.me?.id ?: return
        val todo = items.filter { it.id in ids && !it.seen }
        if (todo.isEmpty()) return
        items = items.map { if (it.id in ids) it.copy(seen = true) else it }
        todo.forEach { Notices.clearSong(it.id) }
        scope.launch(Dispatchers.IO) {
            for (i in todo) runCatching { Firestore.patch("users/$uid/inbox/${i.id}", mapOf("seen" to FV.b(true)), mask = listOf("seen")) }
        }
    }

    /** Clears one from the inbox (on every device). */
    fun clear(item: InboxItem) {
        val uid = Social.me?.id ?: return
        items = items.filter { it.id != item.id }
        Notices.clearSong(item.id)
        scope.launch(Dispatchers.IO) { runCatching { Firestore.delete("users/$uid/inbox/${item.id}") } }
    }

    /** Whether friends can send you songs (the server checks it too). Same setting as on the iPhone and computer. */
    suspend fun setAllowSongs(on: Boolean) {
        val me = Social.me ?: return
        withContext(Dispatchers.IO) {
            Firestore.patch("users/${me.id}", mapOf("allowSongs" to FV.b(on)), mask = listOf("allowSongs"))
        }
        Social.updateMe { it.copy(allowSongs = on) }
    }
}
