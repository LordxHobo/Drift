package com.lordxhobo.drift.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lordxhobo.drift.social.Friends
import com.lordxhobo.drift.social.Jam
import com.lordxhobo.drift.social.Social
import com.lordxhobo.drift.social.UserProfile
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private fun message(e: Throwable) = e.message?.takeIf { it.isNotBlank() } ?: "That didn't work. Check your connection."

/** Listen Together: start a session, join one (a friend's, or with a code), see who's in it, leave. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun JamSheet() {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var busy by remember { mutableStateOf(false) }
    var code by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { Friends.refresh() }
    val close = { UiState.showJam = false }
    val act = { task: suspend () -> Unit ->
        busy = true
        error = null
        scope.launch {
            runCatching { task() }.onFailure { error = message(it) }
            busy = false
        }
        Unit
    }
    ModalBottomSheet(onDismissRequest = close, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = DriftColors.surface) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp)) {
            Text("Listen Together", color = DriftColors.text, fontSize = 22.sp, fontWeight = FontWeight.ExtraBold)
            Spacer(Modifier.size(8.dp))
            val s = Jam.state
            val me = Social.me
            when {
                me == null -> Text("Make a Drift profile in Settings first, so friends can find you.", color = DriftColors.text2, fontSize = 14.sp)
                s != null -> {
                    Text(
                        "Everyone hears the same songs at the same time, each on their own device. Anyone can pick songs, play, pause, skip and change what's next.",
                        color = DriftColors.text2, fontSize = 14.sp,
                    )
                    Row(
                        Modifier.padding(vertical = 14.dp).clip(RoundedCornerShape(10.dp)).background(DriftColors.surface2).padding(start = 16.dp, end = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(s.code, color = DriftColors.text, fontSize = 26.sp, fontWeight = FontWeight.ExtraBold, fontFamily = FontFamily.Monospace, letterSpacing = 3.sp)
                        IconButton(onClick = {
                            (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("Drift session", s.code))
                            Jam.notice = "Code copied"
                        }) { Icon(Icons.Filled.ContentCopy, contentDescription = "Copy code", tint = DriftColors.text2) }
                    }
                    Text("Friends can join from their Friends list, or with this code.", color = DriftColors.muted, fontSize = 13.sp)
                    Spacer(Modifier.size(12.dp))
                    for (m in s.members) {
                        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
                            Avatar(Friends.friends.firstOrNull { it.id == m } ?: if (m == me.id) me else null, 32.dp)
                            Spacer(Modifier.width(12.dp))
                            Text(if (m == me.id) "You" else s.names[m] ?: "Someone", color = DriftColors.text, fontSize = 15.sp, modifier = Modifier.weight(1f))
                            if (m == s.host) Text("Host", color = DriftColors.muted, fontSize = 12.sp)
                        }
                    }
                    Spacer(Modifier.size(12.dp))
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        TextButton(enabled = !busy, onClick = { act { Jam.leave(); close() } }) {
                            Text(if (s.host == me.id) "End for everyone" else "Leave", color = DriftColors.error, fontWeight = FontWeight.Bold)
                        }
                        Button(onClick = close, colors = ButtonDefaults.buttonColors(containerColor = DriftColors.accent, contentColor = DriftColors.onAccent)) {
                            Text("Done", fontWeight = FontWeight.Bold)
                        }
                    }
                }
                else -> {
                    Text(
                        "Listen to the same songs at the same time as your friends, each on your own phone or computer. Anyone in it can pick songs, play, pause and skip.",
                        color = DriftColors.text2, fontSize = 14.sp,
                    )
                    Spacer(Modifier.size(14.dp))
                    Button(
                        enabled = !busy, modifier = Modifier.fillMaxWidth(),
                        onClick = { act { Jam.start(); Jam.notice = "Session started" } },
                        colors = ButtonDefaults.buttonColors(containerColor = DriftColors.accent, contentColor = DriftColors.onAccent),
                    ) { Text("Start a session", fontWeight = FontWeight.Bold) }
                    Spacer(Modifier.size(10.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        OutlinedTextField(
                            value = code, onValueChange = { code = it.uppercase().take(8) }, singleLine = true,
                            placeholder = { Text("Code (e.g. K7QM4X)") },
                            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters),
                            modifier = Modifier.weight(1f),
                        )
                        Spacer(Modifier.width(8.dp))
                        OutlinedButton(enabled = !busy && code.trim().length >= 6, onClick = { act { Jam.join(code); Jam.notice = "Joined"; close() } }) {
                            Text("Join", color = DriftColors.text, fontWeight = FontWeight.Bold)
                        }
                    }
                    Spacer(Modifier.size(16.dp))
                    SectionTitle("Friends listening together")
                    val inSessions = Friends.friends.filter { it.jam != null }
                    if (Friends.loading && Friends.friends.isEmpty()) {
                        Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = DriftColors.accent) }
                    } else if (inSessions.isEmpty()) {
                        Text("None of your friends are in a session right now.", color = DriftColors.muted, fontSize = 13.sp, modifier = Modifier.padding(vertical = 8.dp))
                    }
                    for (f in inSessions) {
                        Row(Modifier.fillMaxWidth().heightIn(min = 52.dp), verticalAlignment = Alignment.CenterVertically) {
                            Avatar(f, 36.dp)
                            Spacer(Modifier.width(12.dp))
                            Text(f.name, color = DriftColors.text, fontSize = 15.sp, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                            OutlinedButton(enabled = !busy, onClick = { act { joinFriend(f); close() } }) {
                                Text("Join", color = DriftColors.text, fontWeight = FontWeight.Bold)
                            }
                        }
                    }
                }
            }
            error?.let { Text(it, color = DriftColors.error, fontSize = 13.sp, modifier = Modifier.padding(top = 10.dp)) }
        }
    }
}

/** Joins a friend's session (from their profile or the Listen Together sheet). */
suspend fun joinFriend(u: UserProfile) {
    val c = u.jam ?: return
    Jam.join(c)
    Jam.notice = "Listening together with ${u.name}"
}

/** "Invite to listen together" from a song's menu: pick friends who follow you back. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InviteSheet() {
    val track = UiState.inviteTrack ?: return
    val scope = rememberCoroutineScope()
    var picked by remember(track) { mutableStateOf(setOf<String>()) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(track) { Friends.refresh() }
    val close = { UiState.inviteTrack = null }
    ModalBottomSheet(onDismissRequest = close, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = DriftColors.surface) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp)) {
            Text("Invite to listen together", color = DriftColors.text, fontSize = 20.sp, fontWeight = FontWeight.ExtraBold)
            Row(Modifier.padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Artwork(track.artwork(120), track.id, 44.dp)
                Spacer(Modifier.width(12.dp))
                Column {
                    Text(track.title, color = DriftColors.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(track.artist, color = DriftColors.muted, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            val people = Jam.invitable(Friends.friends)
            when {
                Social.me == null -> Text("Make a Drift profile in Settings first, so friends can find you.", color = DriftColors.text2, fontSize = 14.sp)
                Friends.loading && Friends.friends.isEmpty() -> Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = DriftColors.accent) }
                people.isEmpty() -> Text(
                    "You can invite friends who follow you back and allow invites.",
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
            error?.let { Text(it, color = DriftColors.error, fontSize = 13.sp, modifier = Modifier.padding(top = 8.dp)) }
            Spacer(Modifier.size(12.dp))
            Button(
                enabled = !busy && picked.isNotEmpty(), modifier = Modifier.fillMaxWidth(),
                onClick = {
                    busy = true
                    error = null
                    scope.launch {
                        runCatching { Jam.invite(picked.toList(), track) }
                            .onSuccess { failed ->
                                Jam.notice = if (failed == 0) "Invited · playing together when they join" else "Couldn't invite $failed of them"
                                close()
                            }
                            .onFailure { error = message(it) }
                        busy = false
                    }
                },
                colors = ButtonDefaults.buttonColors(containerColor = DriftColors.accent, contentColor = DriftColors.onAccent),
            ) { Text(if (picked.size > 1) "Invite ${picked.size} friends" else "Invite", fontWeight = FontWeight.Bold) }
        }
    }
}

/** A friend invited you: join or not. */
@Composable
fun IncomingInvite() {
    val invite = Jam.invites.firstOrNull() ?: return
    val scope = rememberCoroutineScope()
    var busy by remember(invite) { mutableStateOf(false) }
    var error by remember(invite) { mutableStateOf<String?>(null) }
    AlertDialog(
        onDismissRequest = {},
        title = { Text("${invite.fromName} invited you to listen together") },
        text = {
            Column {
                if (invite.title.isNotEmpty()) Text("“${invite.title}” by ${invite.artist}", color = DriftColors.text2)
                error?.let { Text(it, color = DriftColors.error, fontSize = 13.sp, modifier = Modifier.padding(top = 8.dp)) }
            }
        },
        confirmButton = {
            TextButton(enabled = !busy, onClick = {
                busy = true
                scope.launch {
                    runCatching { Jam.answer(invite, accept = true) }.onFailure { error = message(it) }
                    busy = false
                }
            }) { Text("Join", color = DriftColors.accent, fontWeight = FontWeight.Bold) }
        },
        dismissButton = {
            TextButton(enabled = !busy, onClick = { scope.launch { Jam.answer(invite, accept = false) } }) { Text("Not now", color = DriftColors.text2) }
        },
        containerColor = DriftColors.surface,
    )
}

/** A short message at the bottom (joined, ended, copied…). */
@Composable
fun NoticeBar() {
    val n = Jam.notice ?: return
    LaunchedEffect(n) {
        delay(2500)
        if (Jam.notice == n) Jam.notice = null
    }
    Box(Modifier.fillMaxSize().navigationBarsPadding().padding(bottom = 140.dp), contentAlignment = Alignment.BottomCenter) {
        Text(
            n, color = DriftColors.bg, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.clip(RoundedCornerShape(20.dp)).background(DriftColors.text).padding(horizontal = 16.dp, vertical = 10.dp),
        )
    }
}
