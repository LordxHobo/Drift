package com.lordxhobo.drift.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.RepeatOne
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lordxhobo.drift.data.formatTime
import com.lordxhobo.drift.playback.Playback

/** The full player: artwork, the song, the position, the controls and the queue. */
@Composable
fun NowPlayingScreen() {
    val t = Playback.current
    if (t == null) {
        LaunchedEffect(Unit) { UiState.showPlayer = false }
        return
    }
    var scrub by remember { mutableStateOf<Float?>(null) }
    val tint = DriftColors.tile(t.id)
    Box(
        Modifier
            .fillMaxSize()
            .background(Brush.verticalGradient(listOf(tint.copy(alpha = 0.55f).compositeOverBg(), DriftColors.bg)))
            // Taps on empty space stay here (not on the page underneath).
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
                    Text("PLAYING FROM", color = DriftColors.text2, fontSize = 11.sp, letterSpacing = 1.sp)
                    Text(Playback.playingFrom, color = DriftColors.text, fontSize = 13.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                IconButton(onClick = { UiState.openMenu(t) }) {
                    Icon(Icons.Filled.MoreVert, contentDescription = "More options", tint = DriftColors.text)
                }
            }

            BoxWithConstraints(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                val side = minOf(maxWidth, maxHeight)
                Artwork(t.artwork(800), t.id, side, RoundedCornerShape(8.dp))
            }

            Spacer(Modifier.height(24.dp))
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(t.title, color = DriftColors.text, fontSize = 22.sp, fontWeight = FontWeight.ExtraBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(t.artist, color = DriftColors.text2, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                LikeButton(t, size = 26.dp)
            }

            val duration = Playback.duration.coerceAtLeast(1)
            val progress = scrub ?: (Playback.position.toFloat() / duration).coerceIn(0f, 1f)
            Slider(
                value = progress,
                onValueChange = { scrub = it },
                onValueChangeFinished = {
                    scrub?.let { Playback.seek((it * duration).toLong()) }
                    scrub = null
                },
                colors = SliderDefaults.colors(
                    thumbColor = DriftColors.text,
                    activeTrackColor = DriftColors.text,
                    inactiveTrackColor = DriftColors.text.copy(alpha = 0.25f),
                ),
                modifier = Modifier.fillMaxWidth(),
            )
            Row(Modifier.fillMaxWidth()) {
                Text(formatTime(progress * duration / 1000.0), color = DriftColors.text2, fontSize = 11.sp)
                Spacer(Modifier.weight(1f))
                Text(if (Playback.duration > 0) formatTime(Playback.duration / 1000.0) else "--:--", color = DriftColors.text2, fontSize = 11.sp)
            }

            Row(
                Modifier.fillMaxWidth().padding(vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                IconButton(onClick = { Playback.toggleShuffle() }) {
                    Icon(Icons.Filled.Shuffle, contentDescription = if (Playback.shuffle) "Shuffle on" else "Shuffle off", tint = if (Playback.shuffle) DriftColors.accent else DriftColors.text2)
                }
                IconButton(onClick = { Playback.previous() }, modifier = Modifier.size(56.dp)) {
                    Icon(Icons.Filled.SkipPrevious, contentDescription = "Previous", tint = DriftColors.text, modifier = Modifier.size(38.dp))
                }
                Box(
                    Modifier.size(72.dp).clip(CircleShape).background(DriftColors.text).clickable { Playback.toggle() },
                    contentAlignment = Alignment.Center,
                ) {
                    if (Playback.isBuffering && !Playback.isPlaying) {
                        CircularProgressIndicator(Modifier.size(28.dp), color = DriftColors.bg, strokeWidth = 3.dp)
                    } else {
                        Icon(
                            if (Playback.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                            contentDescription = if (Playback.isPlaying) "Pause" else "Play",
                            tint = DriftColors.bg, modifier = Modifier.size(36.dp),
                        )
                    }
                }
                IconButton(onClick = { Playback.next() }, modifier = Modifier.size(56.dp)) {
                    Icon(Icons.Filled.SkipNext, contentDescription = "Next", tint = DriftColors.text, modifier = Modifier.size(38.dp))
                }
                IconButton(onClick = { Playback.cycleRepeat() }) {
                    Icon(
                        if (Playback.repeat == Playback.Repeat.ONE) Icons.Filled.RepeatOne else Icons.Filled.Repeat,
                        contentDescription = "Repeat",
                        tint = if (Playback.repeat == Playback.Repeat.OFF) DriftColors.text2 else DriftColors.accent,
                    )
                }
            }

            Playback.error?.let {
                Text(it, color = DriftColors.error, fontSize = 13.sp, modifier = Modifier.padding(bottom = 8.dp))
            }

            // Bottom row (the queue; Lyrics and Devices come in later builds).
            Row(Modifier.fillMaxWidth().padding(bottom = 12.dp), horizontalArrangement = Arrangement.End) {
                Column(
                    Modifier.clip(RoundedCornerShape(8.dp)).clickable { UiState.showQueue = true }.padding(horizontal = 12.dp, vertical = 6.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Icon(Icons.AutoMirrored.Filled.QueueMusic, contentDescription = null, tint = DriftColors.text)
                    Text("Queue", color = DriftColors.text, fontSize = 10.sp, fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}

/** A colour mixed into the page's dark background (for the player's gradient). */
private fun Color.compositeOverBg(): Color = Color(
    red = red * alpha + DriftColors.bg.red * (1 - alpha),
    green = green * alpha + DriftColors.bg.green * (1 - alpha),
    blue = blue * alpha + DriftColors.bg.blue * (1 - alpha),
)
