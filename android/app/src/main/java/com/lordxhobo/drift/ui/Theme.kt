package com.lordxhobo.drift.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/** Drift's colours (the Drift style on the iPhone, dark). */
object DriftColors {
    val bg = Color(0xFF0E0E10)
    val surface = Color(0xFF1A1A1F)
    val surface2 = Color(0xFF26262D)
    val line = Color(0xFF3F3F46)
    val text = Color(0xFFF4F4F5)
    val text2 = Color(0xFFD4D4D8)
    val muted = Color(0xFFA1A1AA)
    val accent = Color(0xFF1ED760)
    val onAccent = Color(0xFF0E0E10)
    val miniPlayer = Color(0xFF16241B)
    val error = Color(0xFFFF6B5B)

    /** The colour tiles behind playlists without artwork (same as the iPhone). */
    val tiles = listOf(
        Color(0xFFC2410C), Color(0xFF0F766E), Color(0xFF6D28D9), Color(0xFFBE185D),
        Color(0xFF1E3A8A), Color(0xFF854D0E), Color(0xFF14532D), Color(0xFF9F1239),
    )

    fun tile(seed: String): Color = tiles[(seed.hashCode() and 0x7fffffff) % tiles.size]
}

@Composable
fun DriftTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = DriftColors.accent,
            onPrimary = DriftColors.onAccent,
            background = DriftColors.bg,
            onBackground = DriftColors.text,
            surface = DriftColors.surface,
            onSurface = DriftColors.text,
            surfaceVariant = DriftColors.surface2,
            onSurfaceVariant = DriftColors.muted,
            secondaryContainer = DriftColors.surface2,
            outline = DriftColors.line,
            error = DriftColors.error,
        ),
        content = content,
    )
}
