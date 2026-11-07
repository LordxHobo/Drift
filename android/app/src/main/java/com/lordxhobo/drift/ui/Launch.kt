package com.lordxhobo.drift.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** What's new: the same notes as the iPhone and the computer, the ones marked for Android. */
@Serializable
private data class Notes(val entries: List<Entry> = emptyList()) {
    @Serializable
    data class Entry(val id: Int, val date: String = "", val title: String = "", val notes: List<Note> = emptyList())

    @Serializable
    data class Note(val text: String, val platforms: List<String>? = null)
}

private fun loadNotes(context: Context): List<Notes.Entry> = runCatching {
    val text = context.assets.open("patchNotes.json").bufferedReader().use { it.readText() }
    Json { ignoreUnknownKeys = true }.decodeFromString(Notes.serializer(), text).entries
        .map { e -> e.copy(notes = e.notes.filter { it.platforms?.contains("android") == true }) }
        .filter { it.notes.isNotEmpty() }
}.getOrDefault(emptyList())

/** Shows the notes not seen yet. True while they're showing. */
@Composable
fun WhatsNewOnLaunch(): Boolean {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences("drift", Context.MODE_PRIVATE) }
    var entries by remember {
        val all = loadNotes(context)
        val seen = prefs.getInt("patchNotesSeen", -1)
        // A fresh install sees only the newest notes.
        val unseen = if (seen < 0) all.take(1) else all.filter { it.id > seen }
        mutableStateOf(unseen)
    }
    if (entries.isEmpty()) return false
    val done = {
        prefs.edit().putInt("patchNotesSeen", entries.maxOf { it.id }).apply()
        entries = emptyList()
    }
    NotesDialog(entries, done)
    return true
}

/** Every note for Android, newest first (Settings → What's new). */
@Composable
fun AllNotes(onDone: () -> Unit) {
    val context = LocalContext.current
    val entries = remember { loadNotes(context) }
    NotesDialog(entries, onDone)
}

@Composable
private fun NotesDialog(entries: List<Notes.Entry>, done: () -> Unit) {
    AlertDialog(
        onDismissRequest = done,
        title = { Text("What's new") },
        text = {
            Column(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState())) {
                for (e in entries) {
                    Text(e.title, fontWeight = FontWeight.Bold, fontSize = 16.sp, color = DriftColors.text, modifier = Modifier.padding(top = 8.dp, bottom = 4.dp))
                    Text(e.date, fontSize = 12.sp, color = DriftColors.muted)
                    for (n in e.notes) {
                        Text("• ${n.text}", fontSize = 14.sp, color = DriftColors.text2, modifier = Modifier.padding(top = 6.dp))
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = done) { Text("Got it") } },
        containerColor = DriftColors.surface,
    )
}

/**
 * Once: phones (Samsung especially) put apps to sleep to save battery, which can stop the music.
 * Offers the setting that lets Drift keep playing.
 */
@Composable
fun BatteryTip() {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences("drift", Context.MODE_PRIVATE) }
    var show by remember {
        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        mutableStateOf(!prefs.getBoolean("batteryTipShown", false) && !power.isIgnoringBatteryOptimizations(context.packageName))
    }
    if (!show) return
    val done = {
        prefs.edit().putBoolean("batteryTipShown", true).apply()
        show = false
    }
    AlertDialog(
        onDismissRequest = done,
        title = { Text("Keep the music going") },
        text = {
            Text(
                "To save battery, your phone may stop apps it thinks you aren't using, and with them the music. " +
                    "Let Drift run in the background so it keeps playing with the screen off." +
                    if (Build.MANUFACTURER.equals("samsung", ignoreCase = true)) "\n\nOn Samsung phones, also make sure Drift isn't in Settings › Battery › Background usage limits › Sleeping apps." else "",
            )
        },
        confirmButton = {
            TextButton(onClick = {
                done()
                val ask = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}"))
                runCatching { context.startActivity(ask.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }.onFailure {
                    runCatching { context.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                }
            }) { Text("Allow") }
        },
        dismissButton = { TextButton(onClick = done) { Text("Not now") } },
        containerColor = DriftColors.surface,
    )
}
