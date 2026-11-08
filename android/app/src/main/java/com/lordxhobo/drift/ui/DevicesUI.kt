package com.lordxhobo.drift.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.RepeatOne
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lordxhobo.drift.data.formatTime
import com.lordxhobo.drift.social.Remote
import com.lordxhobo.drift.social.RemoteDevice
import com.lordxhobo.drift.social.Social
import com.lordxhobo.drift.social.ThisDevice
import kotlinx.coroutines.delay

private fun kindIcon(d: RemoteDevice): ImageVector = if (d.kind == "computer") Icons.Filled.Computer else Icons.Filled.PhoneAndroid

/** "Devices" in the player: play on this phone or on one of your other devices. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DevicesSheet() {
    LaunchedEffect(Unit) {
        while (true) {
            Remote.refresh()
            delay(1500)
        }
    }
    val close = { UiState.showDevices = false }
    ModalBottomSheet(onDismissRequest = close, sheetState = rememberModalBottomSheetState(), containerColor = DriftColors.surface) {
        Column(Modifier.padding(bottom = 24.dp)) {
            Text("Play on", color = DriftColors.text, fontSize = 20.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp))
            if (Social.me == null) {
                Text(
                    "Make a Drift profile and link your computer to control one from the other.",
                    color = DriftColors.text2, fontSize = 14.sp, modifier = Modifier.padding(20.dp),
                )
                return@Column
            }
            DeviceRow(Icons.Filled.PhoneAndroid, "This phone", ThisDevice.name, selected = Remote.target == null, enabled = true) {
                if (Remote.target != null) Remote.playHere()
                close()
            }
            val online = Remote.devices.filter { it.online }
            for (d in online) {
                val np = d.track?.let { (if (d.playing) "Playing " else "Paused · ") + it.title } ?: "Ready"
                DeviceRow(kindIcon(d), d.name, np, selected = Remote.target == d.id, enabled = true) {
                    Remote.connect(d.id)
                    close()
                }
            }
            if (online.isEmpty()) {
                Text(
                    "Open Drift on your computer or another phone with the same profile, and it shows up here.",
                    color = DriftColors.muted, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
                )
            }
            Remote.error?.let { Text(it, color = DriftColors.error, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 20.dp)) }
        }
    }
}

@Composable
private fun DeviceRow(icon: ImageVector, name: String, detail: String, selected: Boolean, enabled: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 60.dp).clickable(enabled = enabled, onClick = onClick).padding(horizontal = 20.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = if (selected) DriftColors.accent else DriftColors.text, modifier = Modifier.size(28.dp))
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(name, color = if (selected) DriftColors.accent else DriftColors.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(detail, color = DriftColors.muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** The bottom bar while another device plays: what it plays, and play/pause. */
@Composable
fun RemoteMiniBar() {
    val d = Remote.targetDevice
    Box(Modifier.padding(horizontal = 8.dp, vertical = 4.dp)) {
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(DriftColors.miniPlayer)
                .clickable { UiState.showPlayer = true }.padding(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val t = d?.track
            if (t != null) Artwork(t.artwork(120), t.id, 40.dp) else Icon(Icons.Filled.Devices, contentDescription = null, tint = DriftColors.accent, modifier = Modifier.size(40.dp))
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(t?.title ?: "Nothing playing", color = DriftColors.text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text("Playing on ${d?.name ?: "your other device"}", color = DriftColors.accent, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            IconButton(onClick = { Remote.send("toggle") }) {
                Icon(if (d?.playing == true) Icons.Filled.Pause else Icons.Filled.PlayArrow, contentDescription = if (d?.playing == true) "Pause" else "Play", tint = DriftColors.text)
            }
        }
    }
    LaunchedEffect(Remote.target) {
        while (Remote.target != null) {
            Remote.refresh()
            delay(3000)
        }
    }
}

/** The full player for another device: its song and position, the controls, its volume. */
@Composable
fun RemotePlayerScreen() {
    val d = Remote.targetDevice
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var scrub by remember { mutableStateOf<Float?>(null) }
    var vol by remember { mutableStateOf<Float?>(null) }
    LaunchedEffect(Unit) {
        while (true) {
            now = System.currentTimeMillis()
            delay(250)
        }
    }
    LaunchedEffect(Unit) {
        while (true) {
            Remote.refresh()
            delay(1500)
        }
    }
    Box(
        Modifier.fillMaxSize().background(DriftColors.bg)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {},
    ) {
        Column(
            Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().padding(horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Row(Modifier.fillMaxWidth().height(56.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = { UiState.showPlayer = false }) {
                    Icon(Icons.Filled.KeyboardArrowDown, contentDescription = "Close player", tint = DriftColors.text, modifier = Modifier.size(30.dp))
                }
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("PLAYING ON", color = DriftColors.text2, fontSize = 11.sp, letterSpacing = 1.sp)
                    Text(d?.name ?: "your other device", color = DriftColors.accent, fontSize = 13.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Spacer(Modifier.size(48.dp))
            }
            val t = d?.track
            BoxWithConstraints(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                val side = minOf(maxWidth, maxHeight)
                if (t != null) Artwork(t.artwork(800), t.id, side, RoundedCornerShape(8.dp))
                else Icon(Icons.Filled.Devices, contentDescription = null, tint = DriftColors.muted, modifier = Modifier.size(96.dp))
            }
            Spacer(Modifier.height(24.dp))
            Column(Modifier.fillMaxWidth()) {
                Text(t?.title ?: if (d == null || !d.online) "Not reachable right now" else "Nothing playing", color = DriftColors.text, fontSize = 22.sp, fontWeight = FontWeight.ExtraBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(t?.artist ?: "", color = DriftColors.text2, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            val duration = d?.duration ?: 0.0
            val pos = d?.positionNow(now) ?: 0.0
            Slider(
                value = scrub ?: if (duration > 0) (pos / duration).toFloat().coerceIn(0f, 1f) else 0f,
                onValueChange = { scrub = it },
                onValueChangeFinished = {
                    scrub?.let { s -> Remote.send("seek") { it.copy(position = s * duration) } }
                    scrub = null
                },
                enabled = duration > 0,
                colors = SliderDefaults.colors(thumbColor = DriftColors.text, activeTrackColor = DriftColors.text, inactiveTrackColor = DriftColors.surface2),
                modifier = Modifier.fillMaxWidth(),
            )
            Row(Modifier.fillMaxWidth()) {
                Text(formatTime(scrub?.let { it * duration } ?: pos), color = DriftColors.text2, fontSize = 12.sp)
                Spacer(Modifier.weight(1f))
                Text(formatTime(duration), color = DriftColors.text2, fontSize = 12.sp)
            }
            Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = { Remote.send("shuffle") { it.copy(on = !(d?.shuffle ?: false)) } }) {
                    Icon(Icons.Filled.Shuffle, contentDescription = "Shuffle", tint = if (d?.shuffle == true) DriftColors.accent else DriftColors.text)
                }
                IconButton(onClick = { Remote.send("previous") }, modifier = Modifier.size(56.dp)) {
                    Icon(Icons.Filled.SkipPrevious, contentDescription = "Previous", tint = DriftColors.text, modifier = Modifier.size(36.dp))
                }
                IconButton(onClick = { Remote.send("toggle") }, modifier = Modifier.size(68.dp).clip(CircleShape).background(DriftColors.text)) {
                    Icon(if (d?.playing == true) Icons.Filled.Pause else Icons.Filled.PlayArrow, contentDescription = if (d?.playing == true) "Pause" else "Play", tint = DriftColors.bg, modifier = Modifier.size(36.dp))
                }
                IconButton(onClick = { Remote.send("next") }, modifier = Modifier.size(56.dp)) {
                    Icon(Icons.Filled.SkipNext, contentDescription = "Next", tint = DriftColors.text, modifier = Modifier.size(36.dp))
                }
                IconButton(onClick = {
                    val nextMode = when (d?.repeat) { "off" -> "all"; "all" -> "one"; else -> "off" }
                    Remote.send("repeat") { it.copy(mode = nextMode) }
                }) {
                    Icon(if (d?.repeat == "one") Icons.Filled.RepeatOne else Icons.Filled.Repeat, contentDescription = "Repeat", tint = if (d?.repeat != null && d.repeat != "off") DriftColors.accent else DriftColors.text)
                }
            }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.AutoMirrored.Filled.VolumeUp, contentDescription = "Volume", tint = DriftColors.text2)
                Slider(
                    value = vol ?: (d?.volume ?: 1.0).toFloat(),
                    onValueChange = { vol = it },
                    onValueChangeFinished = {
                        vol?.let { v -> Remote.send("volume") { it.copy(value = v.toDouble()) } }
                        vol = null
                    },
                    colors = SliderDefaults.colors(thumbColor = DriftColors.text, activeTrackColor = DriftColors.text2, inactiveTrackColor = DriftColors.surface2),
                    modifier = Modifier.weight(1f).padding(start = 8.dp),
                )
            }
            Row(Modifier.fillMaxWidth().padding(vertical = 12.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(
                    "Play on this phone", color = DriftColors.accent, fontSize = 14.sp, fontWeight = FontWeight.Bold,
                    modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { Remote.playHere() }.padding(8.dp),
                )
                Text(
                    "Devices", color = DriftColors.text, fontSize = 14.sp, fontWeight = FontWeight.Bold,
                    modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { UiState.showDevices = true }.padding(8.dp),
                )
            }
        }
    }
}
