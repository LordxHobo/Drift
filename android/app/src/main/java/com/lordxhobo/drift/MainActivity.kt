package com.lordxhobo.drift

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import com.lordxhobo.drift.podcasts.YouTubePodcasts
import com.lordxhobo.drift.social.Jam
import com.lordxhobo.drift.ui.UiState
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.lordxhobo.drift.playback.Playback
import com.lordxhobo.drift.podcasts.PodcastStore
import com.lordxhobo.drift.social.LibrarySync
import com.lordxhobo.drift.social.Social
import com.lordxhobo.drift.ui.DriftRoot
import com.lordxhobo.drift.ui.Nav
import com.lordxhobo.drift.ui.Screen
import com.lordxhobo.drift.ui.Tab
import com.lordxhobo.drift.ui.DriftTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        Playback.connect(applicationContext)
        setContent {
            DriftTheme { DriftRoot() }
        }
        handleShare(intent)
        handleOpen(intent)
        AppUpdates.check(this)
        askForNotifications()
    }

    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}

    /** Android 13 and later: asks once whether Drift may show notifications (new releases, invites). */
    private fun askForNotifications() {
        if (Build.VERSION.SDK_INT < 33) return
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        val prefs = getSharedPreferences("drift.settings", MODE_PRIVATE)
        if (prefs.getBoolean("askedNotifications", false)) return
        prefs.edit().putBoolean("askedNotifications", true).apply()
        notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    /** Opened from one of Drift's notifications: the list, or an invite (it shows by itself). */
    private fun handleOpen(intent: Intent?) {
        when (intent?.getStringExtra(Notices.OPEN)) {
            "notifications" -> {
                Nav.tab = Tab.HOME
                if (Nav.top != Screen.Notifications) Nav.open(Screen.Notifications)
            }
            "invite" -> UiState.showPlayer = false
            else -> return
        }
        intent.removeExtra(Notices.OPEN)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShare(intent)
        handleOpen(intent)
    }

    /** A link shared to Drift or opened with it: a Spotify one opens the import, a YouTube one plays. */
    private fun handleShare(intent: Intent?) {
        if (intent == null) return
        val text = when (intent.action) {
            Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)
            // A YouTube or YouTube Music link opened with Drift.
            Intent.ACTION_VIEW -> intent.dataString
            else -> null
        } ?: return
        // Handled once (not again after the screen turns).
        intent.action = null
        if (text.contains("spotify", ignoreCase = true) || text.contains("spoti.fi")) {
            Nav.tab = Tab.LIBRARY
            Nav.open(Screen.Import(text))
            return
        }
        // A song shared from YouTube or YouTube Music (or a friend's Drift): play it.
        if (YouTubePodcasts.videoId(text) != null) {
            Jam.notice = "Opening the link…"
            lifecycleScope.launch {
                val t = withContext(Dispatchers.IO) { runCatching { YouTubePodcasts.songFromLink(text) }.getOrNull() }
                if (t == null) {
                    Jam.notice = "Couldn't open that link."
                    return@launch
                }
                Playback.play(listOf(t), 0, "Shared link")
                UiState.showPlayer = true
            }
        }
    }

    override fun onPause() {
        super.onPause()
        // Where each episode was left, saved before Android may close Drift.
        PodcastStore.flush()
    }

    override fun onResume() {
        super.onResume()
        // Back in Drift: pick up changes made on other devices.
        if (Social.me != null) LibrarySync.syncNow()
        // New releases, at most every few hours.
        lifecycleScope.launch { runCatching { Releases.check() } }
    }
}
