package com.lordxhobo.drift.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lordxhobo.drift.playback.Playback
import com.lordxhobo.drift.social.Friends
import com.lordxhobo.drift.social.Inbox
import com.lordxhobo.drift.social.InboxItem
import com.lordxhobo.drift.social.Social
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

/** "Send to a friend" from a song's menu: pick friends who follow you back, add a note. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SendSongSheet() {
    val track = Inbox.sending ?: return
    val scope = rememberCoroutineScope()
    var picked by remember(track) { mutableStateOf(setOf<String>()) }
    var note by remember(track) { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember(track) { mutableStateOf<String?>(null) }
    LaunchedEffect(track) { Friends.refresh() }
    val close: () -> Unit = { Inbox.sending = null }
    val people = Inbox.sendable(Friends.friends)
    val nameOf = { id: String -> people.firstOrNull { it.id == id }?.name ?: "someone" }
    ModalBottomSheet(onDismissRequest = close, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = DriftColors.surface) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp)) {
            Text("Send to a friend", color = DriftColors.text, fontSize = 20.sp, fontWeight = FontWeight.ExtraBold)
            Row(Modifier.padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Artwork(track.artwork(120), track.id, 44.dp)
                Spacer(Modifier.width(12.dp))
                Column {
                    Text(track.title, color = DriftColors.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(track.artist, color = DriftColors.muted, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            when {
                Social.me == null -> Text("Make a Drift profile in Settings first, so friends can find you.", color = DriftColors.text2, fontSize = 14.sp)
                Friends.loading && Friends.friends.isEmpty() -> Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = DriftColors.accent) }
                people.isEmpty() -> Text(
                    if (Friends.friends.isEmpty()) "Follow your friends first (Friends), then send them songs here."
                    else "None of the people you follow can get songs from you yet. They need to follow you back.",
                    color = DriftColors.muted, fontSize = 14.sp, modifier = Modifier.padding(vertical = 8.dp),
                )
            }
            for (f in people) {
                val on = f.id in picked
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable { picked = if (on) picked - f.id else picked + f.id },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Avatar(f, 38.dp)
                    Spacer(Modifier.width(12.dp))
                    Text(f.name, color = DriftColors.text, fontSize = 15.sp, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Checkbox(
                        checked = on, onCheckedChange = { picked = if (on) picked - f.id else picked + f.id },
                        colors = CheckboxDefaults.colors(checkedColor = DriftColors.accent, checkmarkColor = DriftColors.onAccent),
                    )
                }
            }
            val left: (@Composable () -> Unit)? =
                if (note.length > Inbox.MAX_NOTE - 40) { { Text("${Inbox.MAX_NOTE - note.length} characters left") } } else null
            OutlinedTextField(
                value = note,
                onValueChange = { note = it.take(Inbox.MAX_NOTE) },
                placeholder = { Text("Add a note (optional)") },
                maxLines = 4,
                supportingText = left,
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            )
            error?.let { Text(it, color = DriftColors.error, fontSize = 13.sp, modifier = Modifier.padding(top = 8.dp)) }
            Spacer(Modifier.size(12.dp))
            Button(
                enabled = !busy && picked.isNotEmpty(), modifier = Modifier.fillMaxWidth(),
                onClick = {
                    busy = true
                    error = null
                    val ids = picked.toList()
                    scope.launch {
                        runCatching { Inbox.send(ids, track, note) }
                            .onSuccess { failed ->
                                val sent = ids.filter { it !in failed }
                                if (failed.isEmpty()) {
                                    com.lordxhobo.drift.social.Jam.notice = "Sent to " + sent.joinToString(", ") { nameOf(it) }
                                    close()
                                } else {
                                    picked = failed.toSet()
                                    error = "Couldn't send it to ${failed.joinToString(", ") { nameOf(it) }}. They may have turned this off or stopped following you, or the security rules need updating."
                                }
                            }
                            .onFailure { error = it.message ?: "That didn't work. Check your connection." }
                        busy = false
                    }
                },
                colors = ButtonDefaults.buttonColors(containerColor = DriftColors.accent, contentColor = DriftColors.onAccent),
            ) {
                Text(
                    when {
                        busy -> "Sending…"
                        picked.size == 1 -> "Send to ${nameOf(picked.first())}"
                        picked.size > 1 -> "Send to ${picked.size} friends"
                        else -> "Send"
                    },
                    fontWeight = FontWeight.Bold,
                )
            }
        }
    }
}

/** A song a friend sent: who, when, their note, and the song (like, play). */
@Composable
fun InboxRow(item: InboxItem) {
    val t = item.track
    val playing = Playback.current?.id == t.id && Playback.isPlaying
    val sender = Friends.friends.firstOrNull { it.id == item.from }
    Column(
        Modifier.padding(horizontal = 16.dp, vertical = 5.dp).fillMaxWidth().clip(RoundedCornerShape(14.dp))
            .background(if (item.seen) DriftColors.bg else DriftColors.surface).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (sender != null) Avatar(sender, 28.dp) else Box(Modifier.size(28.dp).clip(CircleShape).background(DriftColors.accent), contentAlignment = Alignment.Center) {
                Text(item.fromName.take(1).uppercase(), color = DriftColors.onAccent, fontSize = 13.sp, fontWeight = FontWeight.Bold)
            }
            Spacer(Modifier.width(10.dp))
            Text(
                buildAnnotatedString {
                    withStyle(SpanStyle(color = DriftColors.text, fontWeight = FontWeight.Bold)) { append(item.fromName) }
                    append(" sent you a song")
                },
                color = DriftColors.text2, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
            )
            Text(when_(item.at), color = DriftColors.muted, fontSize = 12.sp)
            if (!item.seen) {
                Spacer(Modifier.width(6.dp))
                Box(Modifier.size(8.dp).clip(CircleShape).background(DriftColors.accent))
            }
            IconButton(onClick = { Inbox.clear(item) }, modifier = Modifier.size(32.dp)) {
                Icon(Icons.Filled.Close, contentDescription = "Clear", tint = DriftColors.muted, modifier = Modifier.size(16.dp))
            }
        }
        if (item.note.isNotEmpty()) {
            Text(
                item.note, color = DriftColors.text, fontSize = 14.sp, lineHeight = 19.sp,
                modifier = Modifier.padding(start = 38.dp)
                    .clip(RoundedCornerShape(topStart = 4.dp, topEnd = 14.dp, bottomEnd = 14.dp, bottomStart = 14.dp))
                    .background(DriftColors.surface2).padding(horizontal = 12.dp, vertical = 8.dp),
            )
        }
        Row(Modifier.padding(start = 38.dp), verticalAlignment = Alignment.CenterVertically) {
            Artwork(t.artwork(120), t.id, 48.dp, RoundedCornerShape(6.dp))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(t.title, color = DriftColors.text, fontSize = 15.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(t.artist, color = DriftColors.muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (!t.isEpisode) LikeButton(t, 22.dp)
            Box(
                Modifier.size(40.dp).clip(CircleShape).background(DriftColors.text).clickable {
                    if (Playback.current?.id == t.id) Playback.toggle() else Playback.play(listOf(t), 0, "From ${item.fromName}")
                },
                contentAlignment = Alignment.Center,
            ) {
                Icon(if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, contentDescription = if (playing) "Pause" else "Play ${t.title}", tint = DriftColors.bg, modifier = Modifier.size(26.dp))
            }
        }
    }
}

/** "5 min", "3 h", "Yesterday", or the date. */
private fun when_(ms: Long): String {
    val m = (System.currentTimeMillis() - ms) / 60_000
    return when {
        m < 1 -> "now"
        m < 60 -> "$m min"
        m < 24 * 60 -> "${m / 60} h"
        m < 48 * 60 -> "Yesterday"
        else -> DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(ms))
    }
}
