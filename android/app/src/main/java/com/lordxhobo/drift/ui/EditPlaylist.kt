package com.lordxhobo.drift.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.Build
import android.util.Base64
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AddPhotoAlternate
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.RemoveCircle
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import com.lordxhobo.drift.data.Library
import com.lordxhobo.drift.data.Track
import com.lordxhobo.drift.social.CollabSync
import com.lordxhobo.drift.social.Social
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

private val colorNames = listOf("Orange", "Teal", "Purple", "Pink", "Blue", "Brown", "Green", "Red")

@Composable
private fun SectionLabel(text: String) {
    Text(text.uppercase(), color = DriftColors.muted, fontSize = 12.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.8.sp)
}

/** Edit playlist: name, cover (songs, colour and symbol, or a photo), shown on your profile, delete. */
@Composable
fun EditPlaylistScreen(id: String) {
    val p = Library.playlist(id)
    if (p == null) {
        Column { BackBar(); EmptyText("This playlist was deleted.") }
        return
    }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var name by remember(id) { mutableStateOf(p.name) }
    var style by remember(id) { mutableStateOf(p.coverStyle ?: "auto") }
    var colorIndex by remember(id) { mutableStateOf(p.colorIndex.mod(DriftColors.tiles.size)) }
    var symbol by remember(id) { mutableStateOf(p.coverSymbol ?: "music.note.list") }
    var isPublic by remember(id) { mutableStateOf(p.isPublic ?: true) }
    var newPhoto by remember(id) { mutableStateOf<String?>(null) }
    var cropping by remember { mutableStateOf<Bitmap?>(null) }
    var loadingPhoto by remember { mutableStateOf(false) }
    var photoError by remember { mutableStateOf<String?>(null) }
    var deleting by remember { mutableStateOf(false) }

    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        loadingPhoto = true
        photoError = null
        scope.launch {
            val b = withContext(Dispatchers.IO) { runCatching { loadPhoto(context, uri) }.getOrNull() }
            loadingPhoto = false
            if (b == null) photoError = "Couldn't open that photo." else cropping = b
        }
    }
    val choosePhoto = { pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }

    cropping?.let { b ->
        CropScreen(
            b,
            onCancel = { cropping = null },
            onAnother = { cropping = null; choosePhoto() },
            onUse = { jpeg ->
                newPhoto = jpeg
                style = "photo"
                cropping = null
            },
        )
        return
    }

    val save = {
        val before = Triple(p.coverStyle ?: "auto", p.colorIndex, p.coverSymbol) to p.cover64
        Library.updatePlaylist(id, name, style, colorIndex, symbol, newPhoto, isPublic)
        val after = Library.playlist(id)
        if (after?.collab != null && (Triple(after.coverStyle ?: "auto", after.colorIndex, after.coverSymbol) to after.cover64) != before) {
            CollabSync.coverChanged(id)
        }
        Nav.back()
    }

    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().height(64.dp).padding(start = 4.dp, end = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { Nav.back() }) { Icon(Icons.Filled.Close, contentDescription = "Cancel", tint = DriftColors.text) }
            Text("Edit playlist", color = DriftColors.text, fontSize = 20.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
            Button(onClick = save, colors = ButtonDefaults.buttonColors(containerColor = DriftColors.accent, contentColor = DriftColors.onAccent)) {
                Text("Save", fontWeight = FontWeight.Bold)
            }
        }
        Column(
            Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            // The cover as it will be.
            Box(Modifier.fillMaxWidth().padding(top = 4.dp), contentAlignment = Alignment.Center) {
                val photo = (newPhoto ?: p.cover64)?.let { coverPhoto(it) }
                Box(Modifier.shadow(16.dp, RoundedCornerShape(6.dp))) {
                    when {
                        style == "photo" && photo != null ->
                            Image(photo, contentDescription = "Cover photo", contentScale = ContentScale.Crop, modifier = Modifier.size(180.dp).clip(RoundedCornerShape(6.dp)))
                        style == "photo" -> Column(
                            Modifier.size(180.dp).clip(RoundedCornerShape(6.dp)).background(DriftColors.surface2).border(1.dp, DriftColors.line, RoundedCornerShape(6.dp)),
                            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
                        ) {
                            if (loadingPhoto) CircularProgressIndicator(color = DriftColors.accent)
                            else {
                                Icon(Icons.Filled.AddPhotoAlternate, contentDescription = null, tint = DriftColors.muted, modifier = Modifier.size(40.dp))
                                Text("No photo yet", color = DriftColors.muted, fontSize = 13.sp, modifier = Modifier.padding(top = 8.dp))
                            }
                        }
                        style == "color" || p.tracks.isEmpty() -> CoverTile(colorIndex, symbol, 180.dp, 6.dp)
                        else -> SongsCover(p.tracks, p.id, 180.dp, 6.dp)
                    }
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                SectionLabel("Name")
                TextField(
                    value = name, onValueChange = { name = it }, singleLine = true,
                    textStyle = androidx.compose.ui.text.TextStyle(fontSize = 17.sp, fontWeight = FontWeight.Medium),
                    colors = TextFieldDefaults.colors(
                        focusedContainerColor = DriftColors.surface, unfocusedContainerColor = DriftColors.surface,
                        focusedIndicatorColor = DriftColors.accent, unfocusedIndicatorColor = DriftColors.line,
                        focusedTextColor = DriftColors.text, unfocusedTextColor = DriftColors.text, cursorColor = DriftColors.accent,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionLabel("Cover")
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(DriftColors.surface).padding(4.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    for ((value, label, icon) in listOf(Triple("auto", "Songs", Icons.Filled.GridView), Triple("color", "Colour", Icons.Filled.Palette), Triple("photo", "Photo", Icons.Filled.Image))) {
                        val on = style == value
                        Row(
                            Modifier.weight(1f).height(42.dp).clip(RoundedCornerShape(9.dp)).background(if (on) DriftColors.accent else Color.Transparent)
                                .clickable { style = value; if (value == "photo" && newPhoto == null && p.cover64 == null) choosePhoto() },
                            horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(icon, contentDescription = null, tint = if (on) DriftColors.onAccent else DriftColors.text2, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(label, color = if (on) DriftColors.onAccent else DriftColors.text2, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                        }
                    }
                }
                when (style) {
                    "auto" -> Text("Uses the artwork of the first songs in the playlist.", color = DriftColors.muted, fontSize = 13.sp)
                    "photo" -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = choosePhoto, enabled = !loadingPhoto, modifier = Modifier.fillMaxWidth().height(46.dp)) {
                            Icon(Icons.Filled.PhotoLibrary, contentDescription = null, tint = DriftColors.text, modifier = Modifier.size(20.dp))
                            Spacer(Modifier.width(8.dp))
                            Text(if (newPhoto != null || p.cover64 != null) "Choose another photo" else "Choose a photo", color = DriftColors.text, fontWeight = FontWeight.Bold)
                        }
                        Text(photoError ?: "The photo is cropped to a square.", color = if (photoError != null) DriftColors.error else DriftColors.muted, fontSize = 13.sp)
                    }
                }
            }

            if (style == "color") {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionLabel("Colour")
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        DriftColors.tiles.forEachIndexed { i, c ->
                            Box(
                                Modifier.size(40.dp, 44.dp).clip(CircleShape).clickable { colorIndex = i },
                                contentAlignment = Alignment.Center,
                            ) {
                                Box(
                                    Modifier.size(38.dp).clip(CircleShape).semantics { contentDescription = colorNames[i] }
                                        .background(if (colorIndex == i) DriftColors.text else Color.Transparent),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Box(Modifier.size(34.dp).clip(CircleShape).background(DriftColors.bg), contentAlignment = Alignment.Center) {
                                        Box(Modifier.size(if (colorIndex == i) 28.dp else 32.dp).clip(CircleShape).background(c))
                                    }
                                }
                            }
                        }
                    }
                }
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionLabel("Symbol")
                    for (row in coverSymbols.chunked(6)) {
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            for ((key, icon) in row) {
                                val on = symbol == key
                                Box(
                                    Modifier.weight(1f).height(46.dp).clip(RoundedCornerShape(10.dp))
                                        .background(if (on) DriftColors.accent else DriftColors.surface).clickable { symbol = key },
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Icon(icon, contentDescription = key.removeSuffix(".fill").replace('.', ' '), tint = if (on) DriftColors.onAccent else DriftColors.text, modifier = Modifier.size(22.dp))
                                }
                            }
                        }
                    }
                }
            }

            if (Social.me != null && p.collab == null) {
                Row(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(DriftColors.surface).clickable { isPublic = !isPublic }
                        .padding(start = 16.dp, end = 14.dp, top = 14.dp, bottom = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("Show on my profile", color = DriftColors.text, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                        Text("Friends can see and play this playlist from your profile.", color = DriftColors.muted, fontSize = 12.sp, modifier = Modifier.padding(top = 3.dp))
                    }
                    Switch(
                        checked = isPublic, onCheckedChange = { isPublic = it },
                        colors = SwitchDefaults.colors(checkedThumbColor = DriftColors.onAccent, checkedTrackColor = DriftColors.accent),
                    )
                }
            }

            if (p.collab == null) {
                TextButton(onClick = { deleting = true }, modifier = Modifier.fillMaxWidth().height(48.dp)) {
                    Icon(Icons.Filled.Delete, contentDescription = null, tint = DriftColors.error, modifier = Modifier.size(20.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(if (p.isAlbum == true) "Remove album" else "Delete playlist", color = DriftColors.error, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                }
            }
        }
    }
    if (deleting) {
        ConfirmDialog(
            title = if (p.isAlbum == true) "Remove \"${p.name}\"?" else "Delete \"${p.name}\"?",
            message = "It goes from your library on all your devices.",
            confirm = if (p.isAlbum == true) "Remove" else "Delete",
            onConfirm = {
                Library.deletePlaylist(id)
                Nav.back() // this screen
                Nav.back() // the playlist
            },
            onDismiss = { deleting = false },
        )
    }
}

/** Opens a picked photo at a workable size (at most 2048 px on its long side, turned the right way up). */
private fun loadPhoto(context: Context, uri: Uri): Bitmap? {
    val maxSide = 2048
    if (Build.VERSION.SDK_INT >= 28) {
        return ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) { d, info, _ ->
            val long = max(info.size.width, info.size.height)
            if (long > maxSide) {
                val k = maxSide.toFloat() / long
                d.setTargetSize((info.size.width * k).roundToInt().coerceAtLeast(1), (info.size.height * k).roundToInt().coerceAtLeast(1))
            }
            d.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
    }
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
    var sample = 1
    while (max(bounds.outWidth, bounds.outHeight) / sample > maxSide) sample *= 2
    return context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample }) }
}

/** The square part of the photo to use, as a 600×600 JPEG (Base64), small enough to sync (like the iPhone's). */
private fun squareJPEG(b: Bitmap, left: Int, top: Int, side: Int): String {
    val square = Bitmap.createBitmap(b, left, top, side, side)
    val scaled = Bitmap.createScaledBitmap(square, 600, 600, true)
    var quality = 85
    var bytes: ByteArray
    do {
        val out = ByteArrayOutputStream()
        scaled.compress(Bitmap.CompressFormat.JPEG, quality, out)
        bytes = out.toByteArray()
        quality -= 10
    } while (bytes.size > 190_000 && quality >= 35)
    return Base64.encodeToString(bytes, Base64.NO_WRAP)
}

/** Crop the cover: drag to move, pinch to zoom; the square is what's used. */
@Composable
private fun CropScreen(b: Bitmap, onCancel: () -> Unit, onAnother: () -> Unit, onUse: (String) -> Unit) {
    BackHandler(onBack = onCancel)
    val image = remember(b) { b.asImageBitmap() }
    var zoom by remember(b) { mutableFloatStateOf(1f) }
    var ox by remember(b) { mutableFloatStateOf(0f) }
    var oy by remember(b) { mutableFloatStateOf(0f) }
    var viewport by remember { mutableFloatStateOf(1f) }
    val density = LocalDensity.current
    // Fills the square at zoom 1.
    val base = viewport / min(b.width, b.height)

    Column(Modifier.fillMaxSize().background(Color.Black)) {
        Row(Modifier.fillMaxWidth().height(64.dp).padding(start = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onCancel) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = DriftColors.text) }
            Text("Crop the cover", color = DriftColors.text, fontSize = 20.sp, fontWeight = FontWeight.Bold)
        }
        BoxWithConstraints(Modifier.fillMaxWidth().weight(1f).padding(horizontal = 20.dp), contentAlignment = Alignment.Center) {
            val side = min(maxWidth.value, maxHeight.value).dp
            val px = with(density) { side.toPx() }
            SideEffect { if (viewport != px) viewport = px }
            Box(
                Modifier.size(side).clip(RoundedCornerShape(4.dp)).border(2.dp, DriftColors.text, RoundedCornerShape(4.dp))
                    .pointerInput(b) {
                        detectTransformGestures { _, pan, gestureZoom, _ ->
                            zoom = (zoom * gestureZoom).coerceIn(1f, 5f)
                            val k = viewport / min(b.width, b.height) * zoom
                            val mx = max(0f, (b.width * k - viewport) / 2)
                            val my = max(0f, (b.height * k - viewport) / 2)
                            ox = (ox + pan.x).coerceIn(-mx, mx)
                            oy = (oy + pan.y).coerceIn(-my, my)
                        }
                    },
                contentAlignment = Alignment.Center,
            ) {
                with(density) {
                    Image(
                        image, contentDescription = "The photo",
                        contentScale = ContentScale.FillBounds,
                        modifier = Modifier.requiredSize((b.width * base).toDp(), (b.height * base).toDp())
                            .graphicsLayer { scaleX = zoom; scaleY = zoom; translationX = ox; translationY = oy },
                    )
                }
                // Thirds, to line things up.
                Column(Modifier.fillMaxSize()) {
                    repeat(3) { r ->
                        Row(Modifier.weight(1f).fillMaxWidth()) {
                            repeat(3) { c ->
                                Box(
                                    Modifier.weight(1f).fillMaxSize()
                                        .border(0.5.dp, if (r == 1 || c == 1) Color.White.copy(alpha = 0.3f) else Color.Transparent),
                                )
                            }
                        }
                    }
                }
            }
        }
        Column(Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 16.dp, bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("Drag to move · pinch to zoom", color = DriftColors.text2, fontSize = 14.sp, modifier = Modifier.align(Alignment.CenterHorizontally))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(onClick = onAnother, modifier = Modifier.weight(1f).height(48.dp)) { Text("Choose another", color = DriftColors.text, fontWeight = FontWeight.Bold) }
                Button(
                    onClick = {
                        val k = base * zoom
                        val sideBmp = (viewport / k).roundToInt().coerceIn(1, min(b.width, b.height))
                        val cx = b.width / 2f - ox / k
                        val cy = b.height / 2f - oy / k
                        val left = (cx - sideBmp / 2f).roundToInt().coerceIn(0, b.width - sideBmp)
                        val top = (cy - sideBmp / 2f).roundToInt().coerceIn(0, b.height - sideBmp)
                        onUse(squareJPEG(b, left, top, sideBmp))
                    },
                    modifier = Modifier.weight(1f).height(48.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = DriftColors.accent, contentColor = DriftColors.onAccent),
                ) { Text("Use photo", fontWeight = FontWeight.Bold) }
            }
        }
    }
}

/** Edit songs: drag a song's handle to move it, tap − to take it out. Changes are saved as you go. */
@Composable
fun EditSongsScreen(id: String) {
    val p = Library.playlist(id)
    if (p == null) {
        Column { BackBar(); EmptyText("This playlist was deleted.") }
        return
    }
    data class Entry(val key: Int, val t: Track)
    var entries by remember(id) { mutableStateOf(p.tracks.mapIndexed { i, t -> Entry(i, t) }) }
    var dragging by remember { mutableStateOf<Int?>(null) }
    var offset by remember { mutableFloatStateOf(0f) }
    val rowPx = with(LocalDensity.current) { 64.dp.toPx() }
    val commit = { Library.setTracks(id, entries.map { it.t }) }

    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().height(64.dp).padding(start = 20.dp, end = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Edit songs", color = DriftColors.text, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Text("${p.name} · ${entries.size} songs", color = DriftColors.muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Button(onClick = { Nav.back() }, colors = ButtonDefaults.buttonColors(containerColor = DriftColors.accent, contentColor = DriftColors.onAccent)) {
                Text("Done", fontWeight = FontWeight.Bold)
            }
        }
        Text(
            "Hold the handle on the right and drag to move a song. Tap the red button to take it out.",
            color = DriftColors.muted, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
        )
        if (entries.isEmpty()) EmptyText("No songs in this playlist.")
        LazyColumn(Modifier.fillMaxWidth().weight(1f), contentPadding = PaddingValues(bottom = 24.dp)) {
            items(entries, key = { it.key }) { e ->
                val lifted = dragging == e.key
                Row(
                    Modifier.fillMaxWidth().height(64.dp)
                        .zIndex(if (lifted) 1f else 0f)
                        .graphicsLayer { translationY = if (lifted) offset else 0f }
                        .then(if (lifted) Modifier.shadow(10.dp, RoundedCornerShape(10.dp)).background(DriftColors.surface2, RoundedCornerShape(10.dp)) else Modifier)
                        .padding(start = 4.dp, end = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconButton(onClick = {
                        entries = entries.filter { it.key != e.key }
                        commit()
                    }) { Icon(Icons.Filled.RemoveCircle, contentDescription = "Take out ${e.t.title}", tint = DriftColors.error) }
                    Artwork(e.t.artwork(120), e.t.id, 44.dp)
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(e.t.title, color = DriftColors.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(e.t.artist, color = DriftColors.muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    Box(
                        Modifier.size(48.dp).pointerInput(e.key) {
                            detectDragGestures(
                                onDragStart = { dragging = e.key; offset = 0f },
                                onDrag = { change, amount ->
                                    change.consume()
                                    offset += amount.y
                                    val list = entries
                                    val i = list.indexOfFirst { it.key == e.key }
                                    if (i >= 0 && offset > rowPx / 2 && i < list.lastIndex) {
                                        entries = list.toMutableList().apply { add(i + 1, removeAt(i)) }
                                        offset -= rowPx
                                    } else if (i > 0 && offset < -rowPx / 2) {
                                        entries = list.toMutableList().apply { add(i - 1, removeAt(i)) }
                                        offset += rowPx
                                    }
                                },
                                onDragEnd = { dragging = null; offset = 0f; commit() },
                                onDragCancel = { dragging = null; offset = 0f; commit() },
                            )
                        },
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(Icons.Filled.DragHandle, contentDescription = "Move ${e.t.title}", tint = if (lifted) DriftColors.accent else DriftColors.muted)
                    }
                }
            }
        }
    }
}
