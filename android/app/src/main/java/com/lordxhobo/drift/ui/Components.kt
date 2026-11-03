package com.lordxhobo.drift.ui

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

/** A playlist's cover: the first four songs' artwork, or a colour tile. */
@Composable
fun PlaylistCover(p: Playlist, size: Dp) {
    val arts = p.tracks.map { it.artwork(226) }.distinct().take(4)
    when {
        arts.size >= 4 -> Column(Modifier.size(size).clip(RoundedCornerShape(4.dp))) {
            for (row in 0..1) Row {
                for (col in 0..1) Artwork(arts[row * 2 + col], p.id, size / 2, RoundedCornerShape(0.dp))
            }
        }
        arts.isNotEmpty() -> Artwork(arts.first(), p.id, size)
        else -> Box(
            Modifier.size(size).clip(RoundedCornerShape(4.dp)).background(DriftColors.tiles[p.colorIndex.mod(DriftColors.tiles.size)]),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.MusicNote, contentDescription = null, tint = DriftColors.text, modifier = Modifier.size(size / 2.5f))
        }
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
            Text(t.artist, color = DriftColors.muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
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
fun PlayButtons(onPlay: () -> Unit, onShuffle: () -> Unit) {
    Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
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
