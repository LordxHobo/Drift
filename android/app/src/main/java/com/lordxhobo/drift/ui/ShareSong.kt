package com.lordxhobo.drift.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.text.TextUtils
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import com.lordxhobo.drift.data.Track
import com.lordxhobo.drift.youtube.HttpDownloader
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.io.File

/** Where anyone can open the song: YouTube Music, or YouTube for an upload. */
fun shareLink(t: Track): String =
    if (t.upload == true) "https://www.youtube.com/watch?v=${t.id}" else "https://music.youtube.com/watch?v=${t.id}"

/** Share a song: a link, or a picture of it (cover, title and artist) for a story or a chat. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ShareSheet(t: Track) {
    val context = LocalContext.current
    var card by remember(t.id) { mutableStateOf<Bitmap?>(null) }
    var copied by remember(t.id) { mutableStateOf(false) }
    val close = { UiState.sharing = null }
    val caption = "${t.title} by ${t.artist}"
    LaunchedEffect(t.id) { card = withContext(Dispatchers.IO) { runCatching { ShareCard.render(context, t) }.getOrNull() } }

    ModalBottomSheet(onDismissRequest = close, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = DriftColors.bg) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("Share", color = DriftColors.text, fontSize = 20.sp, fontWeight = FontWeight.ExtraBold)
            Box(Modifier.fillMaxWidth().height(380.dp), contentAlignment = Alignment.Center) {
                val c = card
                if (c != null) {
                    Image(
                        c.asImageBitmap(), contentDescription = "Picture of $caption", contentScale = ContentScale.Fit,
                        modifier = Modifier.aspectRatio(9f / 16f).clip(RoundedCornerShape(14.dp)),
                    )
                } else {
                    Box(Modifier.aspectRatio(9f / 16f).clip(RoundedCornerShape(14.dp)).background(DriftColors.surface), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(color = DriftColors.accent)
                    }
                }
            }
            card?.let { c ->
                WideButton("Share picture", Icons.Filled.Image, filled = true) {
                    runCatching { sharePicture(context, t, c, caption) }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                WideButton("Share link", Icons.Filled.Share, filled = false, modifier = Modifier.weight(1f)) {
                    val send = Intent(Intent.ACTION_SEND).setType("text/plain")
                        .putExtra(Intent.EXTRA_SUBJECT, caption)
                        .putExtra(Intent.EXTRA_TEXT, "$caption\n${shareLink(t)}")
                    context.startActivity(Intent.createChooser(send, "Share “${t.title}”"))
                }
                WideButton(if (copied) "Copied" else "Copy link", if (copied) Icons.Filled.Check else Icons.Filled.Link, filled = false, modifier = Modifier.weight(1f)) {
                    (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText(caption, shareLink(t)))
                    copied = true
                }
            }
        }
    }
}

@Composable
private fun WideButton(label: String, icon: ImageVector, filled: Boolean, modifier: Modifier = Modifier.fillMaxWidth(), onClick: () -> Unit) {
    Button(
        onClick = onClick,
        modifier = modifier.height(48.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = if (filled) DriftColors.accent else DriftColors.surface,
            contentColor = if (filled) DriftColors.onAccent else DriftColors.text,
        ),
    ) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Text(label, fontWeight = FontWeight.Bold, fontSize = 15.sp)
    }
}

/** Hands the picture (with the link) to Android's share menu. */
private fun sharePicture(context: Context, t: Track, card: Bitmap, caption: String) {
    val dir = File(context.cacheDir, "shared").apply { mkdirs() }
    dir.listFiles()?.forEach { it.delete() }
    val file = File(dir, "drift-${t.id}.png")
    file.outputStream().use { card.compress(Bitmap.CompressFormat.PNG, 100, it) }
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
    val send = Intent(Intent.ACTION_SEND).setType("image/png")
        .putExtra(Intent.EXTRA_STREAM, uri)
        .putExtra(Intent.EXTRA_TEXT, "$caption\n${shareLink(t)}")
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    send.clipData = ClipData.newRawUri(caption, uri)
    context.startActivity(Intent.createChooser(send, "Share “${t.title}”").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
}

/** The picture: 1080 × 1920 (a phone story), the cover in the middle on its own colour. Same as the iPhone's. */
object ShareCard {
    private const val W = 1080
    private const val H = 1920
    private const val S = 3f // the iPhone draws it at 360 × 640, three times over

    fun render(context: Context, t: Track): Bitmap {
        val art = runCatching {
            HttpDownloader.shared.client.newCall(Request.Builder().url(t.artwork(800)).build()).execute().use { r ->
                r.body?.bytes()?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
            }
        }.getOrNull()
        val color = art?.let { colorOf(it) } ?: 0xFF3F3F46.toInt()

        val out = Bitmap.createBitmap(W, H, Bitmap.Config.ARGB_8888)
        val c = Canvas(out)
        val bg = Paint().apply {
            shader = LinearGradient(0f, 0f, 0f, H.toFloat(), intArrayOf(color, withAlpha(color, 0.75f), 0xFF0E0E10.toInt()), floatArrayOf(0f, 0.5f, 1f), Shader.TileMode.CLAMP)
        }
        c.drawRect(0f, 0f, W.toFloat(), H.toFloat(), bg)

        val width = 280 * S
        val left = (W - width) / 2
        val artH = width
        val title = layout(t.title, 26 * S, Typeface.create(Typeface.DEFAULT, Typeface.BOLD), 0xFFFFFFFF.toInt(), width, 3, -0.4f / 26)
        val artist = layout(t.artist, 18 * S, Typeface.create("sans-serif-medium", Typeface.NORMAL), 0xBFFFFFFF.toInt(), width, 2, 0f)
        val logoH = 21 * S
        val pad = 40 * S
        // Cover, title and artist in the middle of what's above the logo.
        val group = artH + 24 * S + title.height + 4 * S + artist.height
        val top = pad + ((H - 2 * pad - logoH) - group) / 2

        val rect = RectF(left, top, left + width, top + artH)
        val radius = 10 * S
        val shadow = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = 0x00000000; setShadowLayer(20 * S, 0f, 12 * S, 0x73000000) }
        c.drawRoundRect(rect, radius, radius, shadow.apply { this.color = 0xFF000000.toInt() })
        c.save()
        c.clipPath(Path().apply { addRoundRect(rect, radius, radius, Path.Direction.CW) })
        if (art != null) {
            // Fill the square (crop the longer side).
            val side = minOf(art.width, art.height)
            val src = android.graphics.Rect((art.width - side) / 2, (art.height - side) / 2, (art.width + side) / 2, (art.height + side) / 2)
            c.drawBitmap(art, src, rect, Paint(Paint.FILTER_BITMAP_FLAG))
        } else {
            c.drawRect(rect, Paint().apply { this.color = 0xFF6D28D9.toInt() })
        }
        c.restore()

        var y = top + artH + 24 * S
        c.save(); c.translate(left, y); title.draw(c); c.restore()
        y += title.height + 4 * S
        c.save(); c.translate(left, y); artist.draw(c); c.restore()

        // Drift's mark (the app icon's four bars) and name, at the bottom.
        val markW = 20 * S
        val markH = 21 * S
        val my = H - pad - logoH
        drawMark(c, left, my, markW, markH)
        val name = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { this.color = 0xFFFFFFFF.toInt(); textSize = 17 * S; typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD) }
        val fm = name.fontMetrics
        c.drawText("Drift", left + markW + 8 * S, my + markH / 2 - (fm.ascent + fm.descent) / 2, name)
        return out
    }

    private fun layout(text: String, size: Float, face: Typeface, color: Int, width: Float, lines: Int, spacing: Float): StaticLayout {
        val p = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; textSize = size; typeface = face; letterSpacing = spacing }
        return StaticLayout.Builder.obtain(text, 0, text.length, p, width.toInt())
            .setAlignment(Layout.Alignment.ALIGN_NORMAL)
            .setMaxLines(lines)
            .setEllipsize(TextUtils.TruncateAt.END)
            .build()
    }

    private fun drawMark(c: Canvas, x: Float, y: Float, w: Float, h: Float) {
        val bars = listOf(50f / 519 to 469f / 519, 120f / 519 to 399f / 519, 0f to 1f, 80f / 519 to 439f / 519)
        val k = minOf(w / 492, h / 519)
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFFFFFFFF.toInt() }
        for ((i, b) in bars.withIndex()) {
            val cx = x + (48 + i * 132) * k
            val bw = 96 * k
            val r = RectF(cx - bw / 2, y + b.first * 519 * k, cx + bw / 2, y + b.second * 519 * k)
            c.drawRoundRect(r, bw / 2, bw / 2, p)
        }
    }

    private fun withAlpha(color: Int, a: Float): Int = (color and 0x00FFFFFF) or ((a * 255).toInt() shl 24)

    /** The artwork's main colour, kept from being too dark, too pale or too bright for white text. */
    private fun colorOf(b: Bitmap): Int {
        val small = Bitmap.createScaledBitmap(b, 24, 24, true)
        var r = 0L; var g = 0L; var bl = 0L; var n = 0L
        for (x in 0 until 24) for (y in 0 until 24) {
            val p = small.getPixel(x, y)
            val pr = (p shr 16) and 0xFF; val pg = (p shr 8) and 0xFF; val pb = p and 0xFF
            // Colourful pixels count more than greys.
            val w = 1 + (maxOf(pr, pg, pb) - minOf(pr, pg, pb)) / 16
            r += pr * w; g += pg * w; bl += pb * w; n += w
        }
        val hsv = FloatArray(3)
        android.graphics.Color.RGBToHSV((r / n).toInt(), (g / n).toInt(), (bl / n).toInt(), hsv)
        hsv[1] = hsv[1].coerceIn(0.25f, 0.85f)
        hsv[2] = hsv[2].coerceIn(0.35f, 0.62f)
        return android.graphics.Color.HSVToColor(hsv)
    }
}
