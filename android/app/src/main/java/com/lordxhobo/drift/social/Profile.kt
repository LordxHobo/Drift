package com.lordxhobo.drift.social

import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Rect
import android.net.Uri
import android.util.Base64
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import java.io.ByteArrayOutputStream
import java.text.Normalizer

/** A Drift profile, as stored in Firebase (users/{id}): the same fields as on the iPhone. */
@Serializable
data class UserProfile(
    val id: String,
    val username: String,
    val displayName: String? = null,
    /** A small JPEG, Base64 (so the profile can be cached as JSON). */
    val avatar64: String? = null,
    val following: List<String> = emptyList(),
    val shareActivity: Boolean = true,
) {
    /** What to call them: their display name, or their username until they set one. */
    val name: String get() = displayName?.trim()?.takeIf { it.isNotEmpty() } ?: username

    val avatar: ByteArray? get() = avatar64?.let { runCatching { Base64.decode(it, Base64.DEFAULT) }.getOrNull() }

    companion object {
        fun from(doc: JsonObject): UserProfile? {
            val name = FV.str(doc["name"]) ?: return null
            val f = FV.fields(doc)
            val username = FV.string(f, "username") ?: return null
            return UserProfile(
                id = name.substringAfterLast('/'),
                username = username,
                displayName = FV.string(f, "displayName")?.takeIf { it.isNotBlank() },
                avatar64 = FV.data(f, "avatar")?.let { Base64.encodeToString(it, Base64.NO_WRAP) },
                following = FV.stringArray(f, "following"),
                shareActivity = FV.bool(f, "shareActivity") ?: true,
            )
        }
    }
}

/** Your Drift profile: creating it, changing it, and keeping it on this phone between launches. */
object Social {
    enum class Status { LOADING, NO_PROFILE, READY }

    var status by mutableStateOf(Status.LOADING)
        private set
    var me by mutableStateOf<UserProfile?>(null)
        private set

    private lateinit var prefs: SharedPreferences
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val json = Json { ignoreUnknownKeys = true }

    const val USERNAME_RULE = "3–20 characters: letters, numbers, . and _"
    const val DISPLAY_NAME_LIMIT = 30

    fun init(context: Context) {
        FirebaseAuth.init(context)
        prefs = context.getSharedPreferences("drift.social", Context.MODE_PRIVATE)
        prefs.getString("me", null)?.let { cached ->
            me = runCatching { json.decodeFromString(UserProfile.serializer(), cached) }.getOrNull()
            if (me != null) status = Status.READY
        }
        scope.launch { bootstrap() }
    }

    private fun cache() {
        val p = me
        if (p != null) prefs.edit().putString("me", json.encodeToString(UserProfile.serializer(), p)).apply()
        else prefs.edit().remove("me").apply()
    }

    /** Restores the profile at launch (or notices it's gone). */
    private suspend fun bootstrap() {
        val uid = FirebaseAuth.currentUid()
        if (uid == null) {
            status = Status.NO_PROFILE
            return
        }
        try {
            val doc = withContext(Dispatchers.IO) { Firestore.get("users/$uid") }
            val profile = doc?.let { UserProfile.from(it) }
            me = profile
            status = if (profile != null) Status.READY else Status.NO_PROFILE
            cache()
            if (profile != null) LibrarySync.syncNow()
        } catch (e: SessionLostException) {
            FirebaseAuth.forget()
            LibrarySync.forget()
            me = null
            status = Status.NO_PROFILE
            cache()
        } catch (e: Exception) {
            // Offline: keep the cached profile; try again next launch.
            if (me == null) status = Status.NO_PROFILE
        }
    }

    // MARK: Usernames

    fun cleaned(s: String): String = s.lowercase().filter { it in 'a'..'z' || it in '0'..'9' || it == '_' || it == '.' }

    /** What's wrong with a username, or null when it's fine. */
    fun validate(name: String): String? = when {
        name.length < 3 -> "At least 3 characters"
        name.length > 20 -> "At most 20 characters"
        name.startsWith(".") || name.endsWith(".") -> "Can't start or end with a dot"
        else -> null
    }

    /** null = couldn't check (offline, or the server said no). */
    suspend fun isAvailable(name: String): Boolean? = withContext(Dispatchers.IO) {
        runCatching {
            val doc = Firestore.get("usernames/$name") ?: return@runCatching true
            val owner = FV.string(FV.fields(doc), "uid")
            owner != null && owner == FirebaseAuth.currentUid()
        }.getOrNull()
    }

    // MARK: Display name

    /** Trimmed, on one line, at most 30 characters. */
    fun cleanedDisplayName(s: String): String = s.replace('\n', ' ').trim().take(DISPLAY_NAME_LIMIT)

    /** For searching: lowercase, without accents ("João" is found by "joao"). */
    fun searchKey(s: String): String =
        Normalizer.normalize(s, Normalizer.Form.NFD).replace(Regex("\\p{Mn}+"), "").lowercase()

    // MARK: Profile

    suspend fun createProfile(username: String, displayName: String, avatar: ByteArray?) = withContext(Dispatchers.IO) {
        val uid = FirebaseAuth.signedInUid()
        Firestore.patch("usernames/$username", mapOf("uid" to FV.s(uid)), mustNotExist = true)
        val display = cleanedDisplayName(displayName)
        val profile = UserProfile(
            id = uid, username = username, displayName = display.ifEmpty { null },
            avatar64 = avatar?.let { Base64.encodeToString(it, Base64.NO_WRAP) },
        )
        val fields: Map<String, JsonElement> = mapOf(
            "username" to FV.s(username),
            "usernameLower" to FV.s(username),
            "displayName" to FV.s(display),
            "displayNameLower" to FV.s(searchKey(profile.name)),
            "avatar" to (avatar?.let { FV.bytes(it) } ?: FV.nul),
            "following" to FV.strings(emptyList()),
            "shareActivity" to FV.b(true),
            "nowPlaying" to FV.nul,
            "playing" to FV.b(false),
            "updatedAt" to FV.i(System.currentTimeMillis() / 1000),
        )
        Firestore.patch("users/$uid", fields)
        withContext(Dispatchers.Main) {
            me = profile
            status = Status.READY
            cache()
            LibrarySync.syncNow()
        }
    }

    suspend fun changeUsername(newName: String) = withContext(Dispatchers.IO) {
        val p = me ?: return@withContext
        if (newName == p.username) return@withContext
        Firestore.patch("usernames/$newName", mapOf("uid" to FV.s(p.id)), mustNotExist = true)
        Firestore.patch(
            "users/${p.id}",
            mapOf(
                "username" to FV.s(newName),
                "usernameLower" to FV.s(newName),
                "displayNameLower" to FV.s(searchKey(p.displayName ?: newName)),
            ),
            mask = listOf("username", "usernameLower", "displayNameLower"),
        )
        runCatching { Firestore.delete("usernames/${p.username}") }
        withContext(Dispatchers.Main) {
            me = p.copy(username = newName)
            cache()
        }
    }

    /** Changes the name shown everywhere (empty = show the username). */
    suspend fun setDisplayName(raw: String) = withContext(Dispatchers.IO) {
        val p = me ?: return@withContext
        val name = cleanedDisplayName(raw)
        val updated = p.copy(displayName = name.ifEmpty { null })
        Firestore.patch(
            "users/${p.id}",
            mapOf("displayName" to FV.s(name), "displayNameLower" to FV.s(searchKey(updated.name))),
            mask = listOf("displayName", "displayNameLower"),
        )
        withContext(Dispatchers.Main) {
            me = updated
            cache()
        }
    }

    suspend fun setPhoto(avatar: ByteArray?) = withContext(Dispatchers.IO) {
        val p = me ?: return@withContext
        Firestore.patch("users/${p.id}", mapOf("avatar" to (avatar?.let { FV.bytes(it) } ?: FV.nul)), mask = listOf("avatar"))
        withContext(Dispatchers.Main) {
            me = p.copy(avatar64 = avatar?.let { Base64.encodeToString(it, Base64.NO_WRAP) })
            cache()
        }
    }

    suspend fun deleteProfile() = withContext(Dispatchers.IO) {
        val p = me ?: return@withContext
        // The synced library too, so a new profile starts empty.
        LibrarySync.removeAll(p.id)
        Firestore.delete("users/${p.id}")
        runCatching { Firestore.delete("usernames/${p.username}") }
        FirebaseAuth.forget()
        withContext(Dispatchers.Main) {
            LibrarySync.forget()
            me = null
            status = Status.NO_PROFILE
            cache()
        }
    }

    /** A picked photo as a small square JPEG (160 × 160), like the iPhone's. */
    fun avatarData(context: Context, uri: Uri): ByteArray? = runCatching {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        var sample = 1
        while (minOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= 160) sample *= 2
        val src = context.contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
        } ?: return null
        val side = minOf(src.width, src.height)
        val out = Bitmap.createBitmap(160, 160, Bitmap.Config.ARGB_8888)
        val left = (src.width - side) / 2
        val top = (src.height - side) / 2
        Canvas(out).drawBitmap(src, Rect(left, top, left + side, top + side), Rect(0, 0, 160, 160), null)
        ByteArrayOutputStream().also { out.compress(Bitmap.CompressFormat.JPEG, 70, it) }.toByteArray()
    }.getOrNull()
}
