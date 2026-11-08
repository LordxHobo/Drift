package com.lordxhobo.drift

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.FileProvider
import com.lordxhobo.drift.youtube.HttpDownloader
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.Request
import java.io.File

/**
 * Updates from inside Drift: each build publishes `latest.json` on GitHub (see android.yml). Drift
 * checks it on launch, downloads the new version, and hands it to Android's installer, which updates
 * Drift in place (same signing key, so the library stays).
 */
object AppUpdates {
    @Serializable
    data class Latest(val versionCode: Int, val versionName: String, val url: String, val title: String = "", val notes: String = "")

    private const val LATEST = "https://github.com/LordxHobo/Drift/releases/download/android-latest/latest.json"

    var available by mutableStateOf<Latest?>(null)
        private set
    /** Shown on launch until "Later" (per version). */
    var prompt by mutableStateOf(false)
        private set
    var downloading by mutableStateOf(false)
        private set
    var progress by mutableStateOf(0f)
        private set
    var error by mutableStateOf<String?>(null)
        private set
    var checking by mutableStateOf(false)
        private set
    /** When it last looked (for "Up to date"). */
    var lastCheck by mutableStateOf<Long?>(null)
        private set

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val json = Json { ignoreUnknownKeys = true }

    /** Looks for a newer version. `manual`: from Settings (shows the prompt even if put off before). */
    fun check(context: Context, manual: Boolean = false) {
        if (checking) return
        val prefs = context.getSharedPreferences("drift.settings", Context.MODE_PRIVATE)
        // On launch at most every 3 hours.
        if (!manual && System.currentTimeMillis() - prefs.getLong("updateCheckedAt", 0) < 3 * 3600_000L && available == null) return
        checking = true
        error = null
        scope.launch {
            val latest = withContext(Dispatchers.IO) {
                runCatching {
                    val r = Request.Builder().url(LATEST).build()
                    HttpDownloader.shared.client.newCall(r).execute().use { res ->
                        if (!res.isSuccessful) null else json.decodeFromString(Latest.serializer(), res.body?.string() ?: "")
                    }
                }.getOrNull()
            }
            checking = false
            lastCheck = System.currentTimeMillis()
            prefs.edit().putLong("updateCheckedAt", System.currentTimeMillis()).apply()
            if (latest != null && latest.versionCode > BuildConfig.VERSION_CODE) {
                available = latest
                prompt = manual || prefs.getInt("updateLater", 0) != latest.versionCode
            } else {
                available = null
                if (manual && latest == null) error = "Couldn't check for updates. Check your connection."
            }
        }
    }

    /** "Later": don't ask again for this version (Settings still offers it). */
    fun later(context: Context) {
        available?.let { context.getSharedPreferences("drift.settings", Context.MODE_PRIVATE).edit().putInt("updateLater", it.versionCode).apply() }
        prompt = false
    }

    fun install(context: Context) {
        val latest = available ?: return
        if (downloading) return
        // Android asks once to let Drift install updates.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !context.packageManager.canRequestPackageInstalls()) {
            error = "Allow Drift to install updates, then tap Update again."
            runCatching {
                context.startActivity(
                    Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            }
            return
        }
        downloading = true
        progress = 0f
        error = null
        scope.launch {
            val file = withContext(Dispatchers.IO) { runCatching { download(context, latest) }.getOrNull() }
            downloading = false
            if (file == null) {
                error = "The download didn't finish. Try again."
                return@launch
            }
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
            val intent = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            runCatching { context.startActivity(intent) }.onFailure { error = "Couldn't open the installer." }
            prompt = false
        }
    }

    private suspend fun download(context: Context, latest: Latest): File {
        val dir = File(context.cacheDir, "updates").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() } // older downloads
        val file = File(dir, "Drift-${latest.versionCode}.apk")
        val r = Request.Builder().url(latest.url).build()
        HttpDownloader.shared.client.newCall(r).execute().use { res ->
            if (!res.isSuccessful) throw IllegalStateException("HTTP ${res.code}")
            val body = res.body ?: throw IllegalStateException("Empty")
            val total = body.contentLength()
            var done = 0L
            var lastShown = 0f
            body.byteStream().use { input ->
                file.outputStream().use { out ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        out.write(buffer, 0, n)
                        done += n
                        if (total > 0) {
                            val p = done.toFloat() / total
                            if (p - lastShown >= 0.02f) {
                                lastShown = p
                                withContext(Dispatchers.Main) { progress = p }
                            }
                        }
                    }
                }
            }
        }
        return file
    }
}
