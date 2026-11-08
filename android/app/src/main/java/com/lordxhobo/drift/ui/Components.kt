package com.lordxhobo.drift.ui

import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.LocalCafe
import androidx.compose.material.icons.filled.SportsEsports
import androidx.compose.material.icons.filled.BeachAccess
import androidx.compose.material.icons.filled.Flight
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Celebration
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Piano
import androidx.compose.material.icons.filled.Speaker
import androidx.compose.material.icons.filled.Headphones
import androidx.compose.material.icons.filled.Eco
import androidx.compose.material.icons.filled.Thunderstorm
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material.icons.filled.NightsStay
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.Star
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.foundation.Image
import android.util.Base64
import android.graphics.BitmapFactory
import androidx.compose.material.icons.filled.ArrowCircleDown
import androidx.compose.material.icons.outlined.ArrowCircleDown
import com.lordxhobo.drift.playback.Downloads
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.lordxhobo.drift.data.Library
import com.lordxhobo.drift.data.Playlist
import com.lordxhobo.drift.data.Track
import com.lordxhobo.drift.playback.Playback

/** A picture from the web, with a colour tile while it loads (or if it can't). */
@Composable
fun Artwork(url: String?, seed: String, size: Dp, shape: Shape = RoundedCornerShape(4.dp)) {
    Box(
        Modifier
            .size(size)
            .clip(shape)
            .background(DriftColors.tile(seed)),
        contentAlignment = Alignment.Center,
    ) {
        if (url != null) {
            AsyncImage(model = url, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        } else {
            Icon(Icons.Filled.MusicNote, contentDescription = null, tint = DriftColors.text.copy(alpha = 0.8f), modifier = Modifier.size(size / 2.5f))
        }
    }
}

/**
 * The symbols a colour cover can show: the iPhone's names (what's saved and synced) and the icon drawn
 * here. The iPhone's guitars have no Android icon: a speaker stands in.
 */
val coverSymbols: List<Pair<String, ImageVector>> = listOf(
    "music.note.list" to Icons.AutoMirrored.Filled.QueueMusic,
    "music.note" to Icons.Filled.MusicNote,
    "heart.fill" to Icons.Filled.Favorite,
    "star.fill" to Icons.Filled.Star,
    "flame.fill" to Icons.Filled.LocalFireDepartment,
    "bolt.fill" to Icons.Filled.Bolt,
    "car.fill" to Icons.Filled.DirectionsCar,
    "moon.stars.fill" to Icons.Filled.NightsStay,
    "sun.max.fill" to Icons.Filled.WbSunny,
    "cloud.rain.fill" to Icons.Filled.Thunderstorm,
    "leaf.fill" to Icons.Filled.Eco,
    "headphones" to Icons.Filled.Headphones,
    "guitars.fill" to Icons.Filled.Speaker,
    "pianokeys" to Icons.Filled.Piano,
    "music.mic" to Icons.Filled.Mic,
    "figure.run" to Icons.AutoMirrored.Filled.DirectionsRun,
    "dumbbell.fill" to Icons.Filled.FitnessCenter,
    "party.popper.fill" to Icons.Filled.Celebration,
    "sparkles" to Icons.Filled.AutoAwesome,
    "airplane" to Icons.Filled.Flight,
    "beach.umbrella.fill" to Icons.Filled.BeachAccess,
    "gamecontroller.fill" to Icons.Filled.SportsEsports,
    "book.fill" to Icons.AutoMirrored.Filled.MenuBook,
    "cup.and.saucer.fill" to Icons.Filled.LocalCafe,
)

fun coverSymbol(name: String?): ImageVector = coverSymbols.firstOrNull { it.first == name }?.second ?: Icons.AutoMirrored.Filled.QueueMusic

private val photoCache = mutableMapOf<String, ImageBitmap?>()

/** A photo cover (Base64 JPEG), decoded once. */
fun coverPhoto(base64: String): ImageBitmap? {
    val key = "${base64.length}:${base64.hashCode()}"
    return photoCache.getOrPut(key) {
        runCatching {
            val bytes = Base64.decode(base64, Base64.DEFAULT)
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
        }.getOrNull()
    }
}

/** A colour tile with a symbol (a colour cover, or a playlist without songs yet). */
@Composable
fun CoverTile(colorIndex: Int, symbol: String?, size: Dp, corner: Dp = 4.dp) {
    Box(
        Modifier.size(size).clip(RoundedCornerShape(corner)).background(DriftColors.tiles[colorIndex.mod(DriftColors.tiles.size)]),
        contentAlignment = Alignment.Center,
    ) {
        Icon(coverSymbol(symbol), contentDescription = null, tint = DriftColors.text, modifier = Modifier.size(size / 2.5f))
    }
}

/** The automatic cover: the first four songs' artwork (or the first one's; nothing without songs). */
@Composable
fun SongsCover(tracks: List<Track>, seed: String, size: Dp, corner: Dp = 4.dp) {
    val arts = tracks.map { it.artwork(226) }.distinct().take(4)
    when {
        arts.size >= 4 -> Column(Modifier.size(size).clip(RoundedCornerShape(corner))) {
            for (row in 0..1) Row {
                for (col in 0..1) Artwork(arts[row * 2 + col], seed, size / 2, RoundedCornerShape(0.dp))
            }
        }
        arts.isNotEmpty() -> Artwork(arts.first(), seed, size, RoundedCornerShape(corner))
    }
}

/** A playlist's cover, as it was set (on any device): a photo, a colour with a symbol, or its songs' artwork. */
@Composable
fun PlaylistCover(p: Playlist, size: Dp) {
    val photo = p.cover64?.takeIf { p.coverStyle == "photo" }?.let { coverPhoto(it) }
    when {
        photo != null -> Image(photo, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.size(size).clip(RoundedCornerShape(4.dp)))
        p.coverStyle == "color" -> CoverTile(p.colorIndex, p.coverSymbol, size)
        p.tracks.isEmpty() -> CoverTile(p.colorIndex, p.coverSymbol, size)
        else -> SongsCover(p.tracks, p.id, size)
    }
}

/** One song in a list: artwork, title, artist, like and the song menu. Hold it for the menu too. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TrackRow(t: Track, onClick: () -> Unit, onMenu: () -> Unit, number: Int? = null, showArt: Boolean = true) {
    val isCurrent = Playback.current?.id == t.id
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 60.dp)
            .combinedClickable(onClick = onClick, onLongClick = onMenu)
            .padding(start = 16.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (number != null) {
            Text("$number", color = DriftColors.muted, fontSize = 14.sp, modifier = Modifier.width(28.dp))
        }
        if (showArt) {
            Artwork(t.artwork(120), t.id, 44.dp)
            Spacer(Modifier.width(12.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(
                t.title, color = if (isCurrent) DriftColors.accent else DriftColors.text, fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                // Saved on the phone (plays offline).
                if (Downloads.isDownloaded(t.id)) {
                    Icon(Icons.Filled.ArrowCircleDown, contentDescription = "Downloaded", tint = DriftColors.accent, modifier = Modifier.size(13.dp))
                    Spacer(Modifier.width(4.dp))
                }
                Text(t.artist, color = DriftColors.muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        Text(t.durationText, color = DriftColors.muted, fontSize = 12.sp)
        LikeButton(t)
        IconButton(onClick = onMenu) {
            Icon(Icons.Filled.MoreVert, contentDescription = "More options for ${t.title}", tint = DriftColors.muted)
        }
    }
}

@Composable
fun LikeButton(t: Track, size: Dp = 20.dp) {
    val liked = Library.isLiked(t.id)
    IconButton(onClick = { Library.toggleLike(t) }) {
        Icon(
            if (liked) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder,
            contentDescription = if (liked) "Remove from Liked songs" else "Like",
            tint = if (liked) DriftColors.accent else DriftColors.muted,
            modifier = Modifier.size(size),
        )
    }
}

/** A list row for a playlist, an album or an artist. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun LibraryRow(title: String, subtitle: String, onClick: () -> Unit, onLongClick: (() -> Unit)? = null, art: @Composable () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .padding(horizontal = 16.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        art()
        Column(Modifier.weight(1f)) {
            Text(title, color = DriftColors.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(subtitle, color = DriftColors.muted, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
fun SectionTitle(text: String, modifier: Modifier = Modifier) {
    Text(
        text, color = DriftColors.text, fontSize = 20.sp, fontWeight = FontWeight.ExtraBold,
        modifier = modifier.padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 8.dp),
    )
}

/** The round green play button (and the outlined shuffle one) on playlist, album and artist pages. */
@Composable
fun PlayButtons(onPlay: () -> Unit, onShuffle: () -> Unit, downloadId: String? = null) {
    Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        // Keep this playlist downloaded (songs added later download too).
        if (downloadId != null) {
            val on = Downloads.isKept(downloadId)
            IconButton(onClick = { Downloads.keep(downloadId, !on) }, modifier = Modifier.size(48.dp)) {
                Icon(
                    if (on) Icons.Filled.ArrowCircleDown else Icons.Outlined.ArrowCircleDown,
                    contentDescription = if (on) "Remove download" else "Download",
                    tint = if (on) DriftColors.accent else DriftColors.muted,
                    modifier = Modifier.size(30.dp),
                )
            }
            Spacer(Modifier.weight(1f))
        }
        IconButton(
            onClick = onShuffle,
            modifier = Modifier.size(48.dp).clip(CircleShape).background(DriftColors.surface2),
        ) {
            Icon(Icons.Filled.Shuffle, contentDescription = "Shuffle", tint = DriftColors.text)
        }
        IconButton(
            onClick = onPlay,
            modifier = Modifier.size(56.dp).clip(CircleShape).background(DriftColors.accent),
        ) {
            Icon(Icons.Filled.PlayArrow, contentDescription = "Play", tint = DriftColors.onAccent, modifier = Modifier.size(30.dp))
        }
    }
}

@Composable
fun EmptyText(text: String) {
    Text(text, color = DriftColors.muted, fontSize = 14.sp, modifier = Modifier.padding(24.dp))
}
