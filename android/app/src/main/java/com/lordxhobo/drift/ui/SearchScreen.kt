package com.lordxhobo.drift.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lordxhobo.drift.playback.Playback
import com.lordxhobo.drift.youtube.YouTube
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay

/** The search tab's text and results (kept while you look at an artist or album). */
private object SearchState {
    var query by mutableStateOf("")
    var results by mutableStateOf<YouTube.SearchResults?>(null)
    var searching by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)
    var lastSearched = ""
}

@Composable
fun SearchScreen() {
    val focus = LocalFocusManager.current
    // Searches a moment after you stop typing.
    LaunchedEffect(SearchState.query) {
        val q = SearchState.query.trim()
        if (q.isEmpty()) {
            SearchState.results = null
            SearchState.error = null
            SearchState.lastSearched = ""
            return@LaunchedEffect
        }
        if (q == SearchState.lastSearched) return@LaunchedEffect
        delay(450)
        SearchState.searching = true
        SearchState.error = null
        try {
            SearchState.results = YouTube.search(q)
            SearchState.lastSearched = q
        } catch (e: CancellationException) {
            throw e   // typed more: the next search takes over
        } catch (e: Throwable) {
            // The reason, too, so a screenshot says what went wrong.
            SearchState.error = "Search failed. Check your connection and try again.\n\n" +
                (e.message ?: e::class.java.simpleName)
        } finally {
            SearchState.searching = false
        }
    }

    Column {
        Text(
            "Search", color = DriftColors.text, fontSize = 26.sp, fontWeight = FontWeight.ExtraBold,
            modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 12.dp),
        )
        TextField(
            value = SearchState.query,
            onValueChange = { SearchState.query = it },
            placeholder = { Text("What do you want to listen to?") },
            leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
            trailingIcon = {
                if (SearchState.query.isNotEmpty()) {
                    IconButton(onClick = { SearchState.query = "" }) { Icon(Icons.Filled.Close, contentDescription = "Clear") }
                }
            },
            singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { focus.clearFocus() }),
            shape = RoundedCornerShape(8.dp),
            colors = TextFieldDefaults.colors(
                focusedContainerColor = DriftColors.text,
                unfocusedContainerColor = DriftColors.text,
                focusedTextColor = DriftColors.bg,
                unfocusedTextColor = DriftColors.bg,
                focusedLeadingIconColor = DriftColors.bg,
                unfocusedLeadingIconColor = DriftColors.bg,
                focusedTrailingIconColor = DriftColors.bg,
                unfocusedTrailingIconColor = DriftColors.bg,
                focusedPlaceholderColor = DriftColors.surface2,
                unfocusedPlaceholderColor = DriftColors.surface2,
                cursorColor = DriftColors.bg,
                focusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent,
                unfocusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent,
            ),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        )

        val r = SearchState.results
        when {
            SearchState.searching && r == null -> Box(Modifier.fillMaxWidth().padding(40.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = DriftColors.accent)
            }
            SearchState.error != null -> EmptyText(SearchState.error ?: "")
            r == null -> EmptyText("Find songs, artists and albums on YouTube Music.")
            r.songs.isEmpty() && r.artists.isEmpty() && r.albums.isEmpty() -> EmptyText("Nothing found for “${SearchState.lastSearched}”.")
            else -> LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
                if (r.artists.isNotEmpty()) {
                    item { SectionTitle("Artists") }
                    item {
                        LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                            itemsIndexed(r.artists, key = { i, a -> "$i-${a.url}" }) { _, a ->
                                Column(
                                    Modifier.width(110.dp).clickable { Nav.open(Screen.ArtistPage(a)) },
                                    horizontalAlignment = Alignment.CenterHorizontally,
                                ) {
                                    Artwork(a.thumbnail, a.name, 110.dp, CircleShape)
                                    Text(a.name, color = DriftColors.text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 6.dp))
                                }
                            }
                        }
                    }
                }
                if (r.songs.isNotEmpty()) {
                    item { SectionTitle("Songs") }
                    itemsIndexed(r.songs, key = { i, t -> "$i-${t.id}" }) { i, t ->
                        TrackRow(t, onClick = { Playback.play(r.songs, i, "Search") }, onMenu = { UiState.openMenu(t) })
                    }
                }
                if (r.albums.isNotEmpty()) {
                    item { SectionTitle("Albums") }
                    itemsIndexed(r.albums, key = { i, a -> "$i-${a.url}" }) { _, a ->
                        LibraryRow(a.title, "Album · ${a.artist}", onClick = { Nav.open(Screen.AlbumPage(a)) }) {
                            Artwork(a.thumbnail, a.title, 56.dp)
                        }
                    }
                }
            }
        }
    }
}
