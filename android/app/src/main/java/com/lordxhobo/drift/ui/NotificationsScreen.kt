package com.lordxhobo.drift.ui

import android.Manifest
import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lordxhobo.drift.Notice
import com.lordxhobo.drift.Notices
import com.lordxhobo.drift.Releases
import com.lordxhobo.drift.data.Library
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

/** The bell on Home: Drift's notifications, with a dot while some are unread. */
@Composable
fun NotificationsButton() {
    Box(
        Modifier.clip(CircleShape).clickable { Nav.open(Screen.Notifications) }.padding(8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Icon(Icons.Filled.Notifications, contentDescription = "Notifications", tint = DriftColors.text)
        if (Notices.unread > 0) {
            Box(Modifier.align(Alignment.TopEnd).size(9.dp).clip(CircleShape).background(DriftColors.accent))
        }
    }
}

private fun ago(ms: Long): String {
    val m = (System.currentTimeMillis() - ms) / 60_000
    return when {
        m < 1 -> "Just now"
        m < 60 -> "$m min ago"
        m < 24 * 60 -> "${m / 60} h ago"
        m < 7 * 24 * 60 -> "${m / (24 * 60)} d ago"
        else -> DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(ms))
    }
}

/** Drift's notifications: new releases from artists you follow. */
@Composable
fun NotificationsScreen() {
    val scope = rememberCoroutineScope()
    var checking by remember { mutableStateOf(false) }
    // Seen once opened (the dot on Home goes).
    LaunchedEffect(Unit) { Notices.markAllRead() }
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) { BackBar("Notifications") }
                if (Notices.list.isNotEmpty()) TextButton(onClick = { Notices.clear() }) { Text("Clear", color = DriftColors.text2, fontWeight = FontWeight.Bold) }
            }
        }
        if (Notices.list.isEmpty()) {
            item {
                Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(
                        if (Library.followed.isEmpty()) "Follow artists (on their page) to hear about their new songs and albums here."
                        else "Nothing new yet. New songs and albums from the ${Library.followed.size} artists you follow show up here.",
                        color = DriftColors.muted, fontSize = 14.sp,
                    )
                    if (Library.followed.isNotEmpty()) {
                        TextButton(enabled = !checking, onClick = {
                            checking = true
                            scope.launch {
                                runCatching { Releases.check(force = true) }
                                checking = false
                            }
                        }) { Text(if (checking) "Looking…" else "Look now", color = DriftColors.accent, fontWeight = FontWeight.Bold) }
                    }
                }
            }
        }
        items(Notices.list, key = { it.id }) { n -> NoticeCard(n) }
    }
}

@Composable
private fun NoticeCard(n: Notice) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp).clip(RoundedCornerShape(14.dp)).background(DriftColors.surface).padding(vertical = 10.dp)) {
        Row(Modifier.padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.AutoAwesome, contentDescription = null, tint = DriftColors.accent, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(n.title, color = DriftColors.text, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                Text(n.detail, color = DriftColors.muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Text(ago(n.date), color = DriftColors.muted, fontSize = 11.sp)
        }
        for (r in n.releases.take(10)) {
            Row(
                Modifier.fillMaxWidth().heightIn(min = 60.dp).clickable { Nav.open(Screen.AlbumPage(r.ref)) }.padding(horizontal = 14.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Artwork(r.thumbnail, r.id, 48.dp)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(r.title, color = DriftColors.text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(r.artist, color = DriftColors.muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
        if (n.releases.size > 10) Text("and ${n.releases.size - 10} more", color = DriftColors.muted, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 14.dp))
    }
}

/** Settings → Notifications: which ones Android shows, and Android's permission for them. */
@Composable
fun NotificationSettingsScreen() {
    val context = LocalContext.current
    var allowed by remember { mutableStateOf(Notices.allowed()) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { allowed = Notices.allowed() }
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        item { BackBar("Notifications") }
        if (!allowed) {
            item {
                Column(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).clip(RoundedCornerShape(14.dp)).background(DriftColors.surface).padding(16.dp),
                ) {
                    Text("Notifications are off for Drift", color = DriftColors.text, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                    Text("Android won't show Drift's notifications until you allow them.", color = DriftColors.muted, fontSize = 13.sp, modifier = Modifier.padding(top = 4.dp))
                    TextButton(onClick = {
                        if (Build.VERSION.SDK_INT >= 33) ask.launch(Manifest.permission.POST_NOTIFICATIONS)
                        else context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName))
                    }) { Text("Allow notifications", color = DriftColors.accent, fontWeight = FontWeight.Bold) }
                }
            }
        }
        item {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp).clip(RoundedCornerShape(14.dp)).background(DriftColors.surface)) {
                NotifyToggle("New releases", "New songs and albums from artists you follow (checked every few hours).", Notices.releasesOn) { Notices.turnReleases(it) }
                NotifyToggle("Listen Together invites", "When a friend invites you to listen together.", Notices.invitesOn) { Notices.turnInvites(it) }
            }
        }
    }
}

@Composable
private fun NotifyToggle(title: String, subtitle: String, on: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable { onChange(!on) }.padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, color = DriftColors.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            Text(subtitle, color = DriftColors.muted, fontSize = 12.sp, modifier = Modifier.padding(top = 2.dp))
        }
        Switch(checked = on, onCheckedChange = onChange, colors = SwitchDefaults.colors(checkedThumbColor = DriftColors.onAccent, checkedTrackColor = DriftColors.accent))
    }
}
