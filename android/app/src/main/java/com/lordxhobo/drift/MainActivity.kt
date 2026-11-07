package com.lordxhobo.drift

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.lordxhobo.drift.playback.Playback
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
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShare(intent)
    }

    /** A Spotify link shared to Drift (from Spotify's share menu): open the import with it. */
    private fun handleShare(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return
        if (!text.contains("spotify", ignoreCase = true) && !text.contains("spoti.fi")) return
        Nav.tab = Tab.LIBRARY
        Nav.open(Screen.Import(text))
        // Handled once (not again after the screen turns).
        intent.action = null
    }

    override fun onResume() {
        super.onResume()
        // Back in Drift: pick up changes made on other devices.
        if (Social.me != null) LibrarySync.syncNow()
    }
}
