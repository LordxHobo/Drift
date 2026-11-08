package com.lordxhobo.drift.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.ActivityInfo
import android.view.TextureView
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.FullscreenExit
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.lordxhobo.drift.data.Track
import com.lordxhobo.drift.playback.EpisodeVideo

/** The episode's video in the player: its picture and a spinner until it's ready, plus quality and full screen. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable
fun EpisodeVideoView(t: Track, width: Dp, fullScreen: Boolean = false, onFullScreen: () -> Unit) {
    val context = LocalContext.current
    val view = remember { TextureView(context) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    // Shown while on screen and Drift is in front; nothing loads otherwise.
    DisposableEffect(view, lifecycle) {
        val watcher = LifecycleEventObserver { _, e ->
            when (e) {
                Lifecycle.Event.ON_START -> EpisodeVideo.attach(view)
                Lifecycle.Event.ON_STOP -> EpisodeVideo.detach(view)
                else -> {}
            }
        }
        if (lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) EpisodeVideo.attach(view)
        lifecycle.addObserver(watcher)
        onDispose {
            lifecycle.removeObserver(watcher)
            EpisodeVideo.detach(view)
        }
    }
    val height = width * 9f / 16f
    Box(
        Modifier.size(width, height).clip(RoundedCornerShape(if (fullScreen) 0.dp else 10.dp)).background(Color.Black),
        contentAlignment = Alignment.Center,
    ) {
        AndroidView(factory = { view }, modifier = Modifier.fillMaxSize())
        if (!EpisodeVideo.ready) {
            Box(Modifier.alpha(0.55f)) { Picture(t.artwork(800), t.id, width, height, RoundedCornerShape(0.dp)) }
            if (EpisodeVideo.unavailable) {
                Text(
                    "No video for this episode", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clip(RoundedCornerShape(50)).background(Color.Black.copy(alpha = 0.6f)).padding(horizontal = 10.dp, vertical = 6.dp),
                )
            } else {
                CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(28.dp))
            }
        }
        Row(Modifier.align(Alignment.TopEnd).padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            val h = EpisodeVideo.height
            if (h != null && EpisodeVideo.heights.size > 1) {
                var open by remember { mutableStateOf(false) }
                Box {
                    Text(
                        "${h}p", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold,
                        modifier = Modifier.clip(RoundedCornerShape(50)).background(Color.Black.copy(alpha = 0.6f))
                            .clickable { open = true }.padding(horizontal = 10.dp, vertical = 6.dp),
                    )
                    DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                        for (q in EpisodeVideo.heights.reversed()) {
                            DropdownMenuItem(
                                text = { Text("${q}p" + if (q == h) "  ✓" else "") },
                                onClick = { open = false; EpisodeVideo.choose(q) },
                            )
                        }
                    }
                }
            }
            Box(
                Modifier.padding(start = 6.dp).size(32.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.6f)).clickable(onClick = onFullScreen),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    if (fullScreen) Icons.Filled.FullscreenExit else Icons.Filled.Fullscreen,
                    contentDescription = if (fullScreen) "Exit full screen" else "Full screen", tint = Color.White, modifier = Modifier.size(20.dp),
                )
            }
        }
    }
}

/** The episode video is filling the screen. */
var videoFullScreen by mutableStateOf(false)

/** Into full screen: the video, turned sideways. */
fun openVideoFullScreen(context: Context) {
    context.findActivity()?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
    videoFullScreen = true
}

fun closeVideoFullScreen(context: Context) {
    context.findActivity()?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
    videoFullScreen = false
}

/** The video filling the screen (while [videoFullScreen]). */
@Composable
fun EpisodeVideoFullScreen(t: Track) {
    val context = LocalContext.current
    val onClose = { closeVideoFullScreen(context) }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
            val w = minOf(maxWidth, maxHeight * 16f / 9f)
            EpisodeVideoView(t, w, fullScreen = true, onFullScreen = onClose)
        }
    }
}

private fun Context.findActivity(): Activity? {
    var c: Context? = this
    while (c is ContextWrapper) {
        if (c is Activity) return c
        c = c.baseContext
    }
    return null
}
