package com.lordxhobo.drift.ui

import androidx.compose.runtime.LaunchedEffect
import androidx.compose.foundation.layout.heightIn
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lordxhobo.drift.spotify.SpotifyImport
import com.lordxhobo.drift.spotify.SpotifyImport.Phase

/** Import a public Spotify playlist or album: paste (or share) its link, and Drift finds every song. */
@Composable
fun ImportScreen(link: String?) {
    val context = LocalContext.current
    var text by remember { mutableStateOf(link ?: "") }
    // A link shared into Drift starts right away.
    LaunchedEffect(link) {
        if (link != null && !SpotifyImport.busy) SpotifyImport.start(context, link)
    }
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        item { BackBar() }
        item {
            Text(
                "Import from Spotify", color = DriftColors.text, fontSize = 26.sp, fontWeight = FontWeight.ExtraBold,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 16.dp),
            )
        }
        when (SpotifyImport.phase) {
            Phase.IDLE, Phase.FAILED -> item {
                Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Text(
                        "Paste the link to a public Spotify playlist or album. In Spotify: ••• → Share → Copy link. You can also share it straight to Drift.",
                        color = DriftColors.text2, fontSize = 15.sp,
                    )
                    OutlinedTextField(
                        value = text, onValueChange = { text = it },
                        placeholder = { Text("https://open.spotify.com/playlist/…") },
                        singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    SpotifyImport.error?.let { Text(it, color = DriftColors.error, fontSize = 13.sp, fontWeight = FontWeight.SemiBold) }
                    Button(
                        onClick = { SpotifyImport.start(context, text) },
                        enabled = text.isNotBlank(),
                        colors = ButtonDefaults.buttonColors(containerColor = DriftColors.accent, contentColor = DriftColors.onAccent),
                        modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp),
                    ) { Text("Import", fontWeight = FontWeight.Bold, fontSize = 16.sp) }
                    Text(
                        "Long playlists take a while: Drift looks up every song on YouTube Music. You can leave this page; the import keeps going.",
                        color = DriftColors.muted, fontSize = 12.sp,
                    )
                }
            }
            Phase.READING -> item {
                Column(Modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator(color = DriftColors.accent)
                    Spacer(Modifier.size(16.dp))
                    Text(
                        if (SpotifyImport.read > 0) "Reading the playlist · ${SpotifyImport.read} songs" else "Opening the playlist…",
                        color = DriftColors.text2, fontSize = 15.sp,
                    )
                }
            }
            Phase.MATCHING -> item {
                Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(SpotifyImport.listName ?: "", color = DriftColors.text, fontSize = 18.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    val total = SpotifyImport.total.coerceAtLeast(1)
                    LinearProgressIndicator(
                        progress = { SpotifyImport.processed.toFloat() / total },
                        color = DriftColors.accent, trackColor = DriftColors.surface2, modifier = Modifier.fillMaxWidth(),
                    )
                    Text("Finding songs · ${SpotifyImport.processed} of ${SpotifyImport.total}", color = DriftColors.text2, fontSize = 14.sp)
                    Text("Songs appear in the new playlist as they're found.", color = DriftColors.muted, fontSize = 12.sp)
                }
            }
            Phase.DONE -> {
                item { DoneHeader(context) }
                items(SpotifyImport.missing) { s ->
                    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)) {
                        Text(s.title, color = DriftColors.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(s.artist, color = DriftColors.muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        }
    }
}

@Composable
private fun DoneHeader(context: Context) {
    val total = SpotifyImport.total
    val missing = SpotifyImport.missing
    Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(SpotifyImport.listName ?: "", color = DriftColors.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
        Text(
            if (missing.isEmpty()) "All $total songs are in Drift." else "${total - missing.size} of $total songs imported.",
            color = DriftColors.text2, fontSize = 15.sp,
        )
        if (SpotifyImport.limited) {
            Text("Spotify only showed the first 100 songs of this playlist.", color = DriftColors.muted, fontSize = 13.sp)
        }
        SpotifyImport.spotifyTotal?.let { t ->
            Text("Spotify lists $t songs; some couldn't be read. Importing again may get the rest.", color = DriftColors.muted, fontSize = 13.sp)
        }
        SpotifyImport.foundAgain?.let { Text(if (it == 0) "Nothing more found." else "Found $it more.", color = DriftColors.accent, fontSize = 13.sp) }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Button(
                onClick = { SpotifyImport.playlistId?.let { Nav.open(Screen.PlaylistPage(it)) } },
                colors = ButtonDefaults.buttonColors(containerColor = DriftColors.accent, contentColor = DriftColors.onAccent),
            ) { Text("Open playlist", fontWeight = FontWeight.Bold) }
            OutlinedButton(onClick = { SpotifyImport.clear() }) { Text("Import another", color = DriftColors.text) }
        }
        if (missing.isNotEmpty()) {
            Spacer(Modifier.size(8.dp))
            Text("Not found (${missing.size})", color = DriftColors.text, fontSize = 16.sp, fontWeight = FontWeight.Bold)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedButton(onClick = { SpotifyImport.retryMissing() }, enabled = !SpotifyImport.retrying) {
                    Text(if (SpotifyImport.retrying) "Looking…" else "Look again", color = DriftColors.text)
                }
                OutlinedButton(onClick = {
                    val list = missing.joinToString("\n") { "${it.artist} – ${it.title}" }
                    val clip = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    clip.setPrimaryClip(ClipData.newPlainText("Songs not found", list))
                }) { Text("Copy list", color = DriftColors.text) }
            }
        }
    }
}
