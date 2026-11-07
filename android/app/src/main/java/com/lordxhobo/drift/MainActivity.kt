package com.lordxhobo.drift

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.lordxhobo.drift.playback.Playback
import com.lordxhobo.drift.social.LibrarySync
import com.lordxhobo.drift.social.Social
import com.lordxhobo.drift.ui.DriftRoot
import com.lordxhobo.drift.ui.DriftTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        Playback.connect(applicationContext)
        setContent {
            DriftTheme { DriftRoot() }
        }
    }

    override fun onResume() {
        super.onResume()
        // Back in Drift: pick up changes made on other devices.
        if (Social.me != null) LibrarySync.syncNow()
    }
}
