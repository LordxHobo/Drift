package com.lordxhobo.drift

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.lordxhobo.drift.data.AlbumRef
import com.lordxhobo.drift.data.Library
import com.lordxhobo.drift.data.nowApple
import com.lordxhobo.drift.social.InboxItem
import com.lordxhobo.drift.social.JamInvite
import com.lordxhobo.drift.youtube.YouTube
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.put
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit

/** A release in a notification (an album or single page on YouTube Music). */
@Serializable
data class ReleaseItem(val id: String, val title: String, val artist: String, val thumbnail: String? = null) {
    val ref: AlbumRef get() = AlbumRef(id, title, artist, thumbnail)
}

/** Something in Drift's notifications list. */
@Serializable
data class Notice(
    val id: String = UUID.randomUUID().toString(),
    /** "newReleases" for now. */
    val kind: String,
    /** ms since 1970. */
    val date: Long = System.currentTimeMillis(),
    val title: String,
    val detail: String,
    val read: Boolean = false,
    val releases: List<ReleaseItem> = emptyList(),
)

/**
 * Drift's notifications: the list in the app (new releases from artists you follow), and Android's own
 * notifications for them and for Listen Together invites (each can be turned off).
 */
object Notices {
    var list by mutableStateOf(listOf<Notice>())
        private set
    var releasesOn by mutableStateOf(true)
        private set
    var invitesOn by mutableStateOf(true)
        private set
    var songsOn by mutableStateOf(true)
        private set

    val unread: Int get() = list.count { !it.read }

    private const val RELEASES = "releases"
    private const val INVITES = "invites"
    private const val SONGS = "songs"
    const val OPEN = "drift.open"

    private lateinit var app: Context
    private lateinit var prefs: SharedPreferences
    private lateinit var file: File
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun init(context: Context) {
        app = context.applicationContext
        prefs = app.getSharedPreferences("drift.settings", Context.MODE_PRIVATE)
        releasesOn = prefs.getBoolean("notifyReleases", true)
        invitesOn = prefs.getBoolean("notifyInvites", true)
        songsOn = prefs.getBoolean("notifySongs", true)
        file = File(app.filesDir, "notifications.json")
        list = runCatching { json.decodeFromString(ListSerializer(Notice.serializer()), file.readText()) }.getOrDefault(emptyList())
        if (Build.VERSION.SDK_INT >= 26) {
            val m = app.getSystemService(NotificationManager::class.java)
            m.createNotificationChannel(NotificationChannel(RELEASES, "New releases", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "New songs and albums from artists you follow"
            })
            m.createNotificationChannel(NotificationChannel(INVITES, "Listen Together invites", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Friends inviting you to listen together"
            })
            m.createNotificationChannel(NotificationChannel(SONGS, "Songs from friends", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Friends sending you a song"
            })
        }
    }

    private fun save() {
        val text = json.encodeToString(ListSerializer(Notice.serializer()), list)
        runCatching {
            val tmp = File(file.path + ".tmp")
            tmp.writeText(text)
            tmp.renameTo(file)
        }
    }

    fun post(n: Notice) {
        list = (listOf(n) + list).take(100)
        save()
    }

    fun markAllRead() {
        if (list.none { !it.read }) return
        list = list.map { it.copy(read = true) }
        save()
    }

    fun clear() {
        list = emptyList()
        save()
        NotificationManagerCompat.from(app).cancel(RELEASES, 1)
    }

    fun turnReleases(on: Boolean) {
        releasesOn = on
        prefs.edit().putBoolean("notifyReleases", on).apply()
    }

    fun turnInvites(on: Boolean) {
        invitesOn = on
        prefs.edit().putBoolean("notifyInvites", on).apply()
    }

    fun turnSongs(on: Boolean) {
        songsOn = on
        prefs.edit().putBoolean("notifySongs", on).apply()
    }

    /** Android lets Drift show notifications (asked once on Android 13 and later). */
    fun allowed(): Boolean =
        (Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(app, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
            NotificationManagerCompat.from(app).areNotificationsEnabled()

    private fun open(what: String, code: Int): PendingIntent = PendingIntent.getActivity(
        app, code,
        Intent(app, MainActivity::class.java).putExtra(OPEN, what).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    @Suppress("MissingPermission") // checked by allowed()
    fun showReleases(n: Notice) {
        if (!releasesOn || !allowed()) return
        val note = NotificationCompat.Builder(app, RELEASES)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(n.title)
            .setContentText(n.detail)
            .setContentIntent(open("notifications", 1))
            .setAutoCancel(true)
            .build()
        NotificationManagerCompat.from(app).notify(RELEASES, 1, note)
    }

    @Suppress("MissingPermission") // checked by allowed()
    fun showInvite(i: JamInvite) {
        if (!invitesOn || !allowed()) return
        val note = NotificationCompat.Builder(app, INVITES)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("${i.fromName} invited you to listen together")
            .setContentText(if (i.title.isNotEmpty()) "“${i.title}” by ${i.artist}" else "Open Drift to join")
            .setContentIntent(open("invite", 2))
            .setCategory(NotificationCompat.CATEGORY_SOCIAL)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .build()
        NotificationManagerCompat.from(app).notify(INVITES, i.from.hashCode(), note)
    }

    fun clearInvite(i: JamInvite) {
        if (::app.isInitialized) NotificationManagerCompat.from(app).cancel(INVITES, i.from.hashCode())
    }

    @Suppress("MissingPermission") // checked by allowed()
    fun showSong(i: InboxItem) {
        if (!::app.isInitialized || !songsOn || !allowed()) return
        val text = "“${i.track.title}” by ${i.track.artist}" + if (i.note.isNotEmpty()) " · ${i.note}" else ""
        val note = NotificationCompat.Builder(app, SONGS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("${i.fromName} sent you a song")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(open("inbox", 3))
            .setCategory(NotificationCompat.CATEGORY_SOCIAL)
            .setAutoCancel(true)
            .build()
        NotificationManagerCompat.from(app).notify(SONGS, i.id.hashCode(), note)
    }

    fun clearSong(id: String) {
        if (::app.isInitialized) NotificationManagerCompat.from(app).cancel(SONGS, id.hashCode())
    }

    /** Checks for new releases every 6 hours, also while Drift is closed (when there's internet). */
    fun schedule(context: Context) {
        val work = PeriodicWorkRequestBuilder<ReleaseWorker>(6, TimeUnit.HOURS)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        WorkManager.getInstance(context).enqueueUniquePeriodicWork("releases", ExistingPeriodicWorkPolicy.KEEP, work)
    }
}

class ReleaseWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        runCatching { Releases.check() }
        return Result.success()
    }
}

/**
 * New releases from artists you follow: anything on their page that wasn't there before. Same records as the
 * iPhone and the computer (`known` and `newReleases` on each followed artist), so they sync.
 */
object Releases {
    /** How long a release counts as new (30 days, in seconds). */
    private const val NEW_FOR = 30 * 86400.0
    private val mutex = Mutex()
    private const val LAST = "releases.lastCheck"

    private fun str(e: JsonElement?): String? = (e as? JsonPrimitive)?.contentOrNull

    /** Checks every followed artist, at most every 3 hours unless forced. Returns what's new. */
    suspend fun check(force: Boolean = false): List<ReleaseItem> = mutex.withLock {
        val ctx = appContext ?: return@withLock emptyList()
        val prefs = ctx.getSharedPreferences("drift.settings", Context.MODE_PRIVATE)
        val last = prefs.getLong(LAST, 0)
        if (!force && System.currentTimeMillis() - last < 3 * 3600_000L) return@withLock emptyList()
        val artists = withContext(Dispatchers.Main) { Library.followed }
        if (artists.isEmpty()) return@withLock emptyList()

        val pages = mutableMapOf<String, Pair<String, List<AlbumRef>>>()
        val thumbs = mutableMapOf<String, String?>()
        for (a in artists) {
            runCatching { YouTube.artist(a) }.getOrNull()?.let { p ->
                pages[a.url] = p.artist.name to p.albums
                thumbs[a.url] = p.artist.thumbnail
            }
        }
        val found = mutableListOf<ReleaseItem>()
        withContext(Dispatchers.Main) {
            val now = nowApple()
            val updated = Library.artists.map { entry ->
                val ref = Library.artistRef(entry) ?: return@map entry
                val (name, releases) = pages[ref.url] ?: return@map entry
                val (e, f) = update(entry, name, thumbs[ref.url], releases, now)
                found += f
                e
            }
            Library.updateArtists(updated)
            prefs.edit().putLong(LAST, System.currentTimeMillis()).apply()
            notify(found)
        }
        found
    }

    var appContext: Context? = null

    /** Compares an artist's releases with what was seen before: the entry with the new ones added, and them. */
    fun update(entry: JsonObject, name: String, thumbnail: String?, releases: List<AlbumRef>, now: Double): Pair<JsonObject, List<ReleaseItem>> {
        val known = (entry["known"] as? JsonArray).orEmpty().mapNotNull { str(it) }.toMutableSet()
        val fresh = mutableListOf<JsonElement>()
        val found = mutableListOf<ReleaseItem>()
        if (known.isEmpty()) {
            // First look: nothing counts as new yet.
            known += releases.map { it.url }
        } else {
            for (r in releases) {
                if (!known.add(r.url)) continue
                fresh += buildJsonObject {
                    put("album", buildJsonObject {
                        put("id", r.url)
                        put("title", r.title)
                        put("subtitle", r.artist)
                        r.thumbnail?.let { put("thumbnail", it) }
                    })
                    put("artistName", name)
                    put("foundAt", now)
                }
                found += ReleaseItem(r.url, r.title, name, r.thumbnail)
            }
        }
        val kept = (entry["newReleases"] as? JsonArray).orEmpty().filter { n ->
            ((n as? JsonObject)?.get("foundAt") as? JsonPrimitive)?.doubleOrNull?.let { it >= now - NEW_FOR } ?: false
        }
        val artist = (entry["artist"] as? JsonObject).orEmpty().toMutableMap()
        artist["name"] = JsonPrimitive(name)
        if (thumbnail != null) artist["thumbnail"] = JsonPrimitive(thumbnail)
        val out = entry.toMutableMap()
        out["artist"] = JsonObject(artist)
        out["known"] = JsonArray(known.map { JsonPrimitive(it) })
        out["newReleases"] = JsonArray(fresh + kept)
        return JsonObject(out) to found
    }

    /** One notice for everything found in one go. */
    private fun notify(found: List<ReleaseItem>) {
        val first = found.firstOrNull() ?: return
        val artists = found.map { it.artist }.distinct()
        val n = Notice(
            kind = "newReleases",
            title = if (found.size == 1) "New from ${first.artist}" else "${found.size} new releases",
            detail = if (found.size == 1) first.title else artists.take(3).joinToString(", ") + if (artists.size > 3) " and more" else "",
            releases = found,
        )
        Notices.post(n)
        Notices.showReleases(n)
    }
}
