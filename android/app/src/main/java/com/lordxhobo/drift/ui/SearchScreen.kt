package com.lordxhobo.drift.ui

import androidx.compose.ui.draw.clip
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Row
import kotlinx.coroutines.withContext
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.Dispatchers
import com.lordxhobo.drift.data.Track
import com.lordxhobo.drift.podcasts.YouTubePodcasts
import com.lordxhobo.drift.podcasts.PodcastStore
import com.lordxhobo.drift.podcasts.PodcastChannel
import com.lordxhobo.drift.podcasts.Feeds
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
internal object SearchState {
    var query by mutableStateOf("")
    /** Searching podcasts (shows, channels, episodes) instead of music. */
    var podcasts by mutableStateOf(false)
    var podResults by mutableStateOf<PodResults?>(null)
    var results by mutableStateOf<YouTube.SearchResults?>(null)
    var searching by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)
    var lastSearched = ""
}

/** Podcast search results: shows (from their feed or YouTube) and episodes, or a pasted video. */
data class PodResults(val query: String, val shows: List<PodcastChannel>, val episodes: List<Track>, val video: Track? = null, val error: String? = null)

/** Podcasts: Apple's directory and YouTube side by side; a pasted feed link is that show, a YouTube link that video. */
private suspend fun searchPodcasts(q: String): PodResults = withContext(Dispatchers.IO) {
    val link = q.startsWith("http://", true) || q.startsWith("https://", true)
    if (q.contains("youtu")) {
        val video = runCatching { YouTubePodcasts.videoFromLink(q) }.getOrNull()
        if (video != null) return@withContext PodResults(q, emptyList(), emptyList(), video)
    }
    if (link && !q.contains("youtu")) {
        return@withContext try {
            val found = Feeds.showFromLink(q) ?: return@withContext PodResults(q, emptyList(), emptyList(), error = "Couldn't find a podcast at that link. Paste the show's feed link, its Apple Podcasts page or its SoundCloud profile.")
            withContext(Dispatchers.Main) { PodcastStore.showLoaded(found.channel, found.episodes) }
            PodResults(q, listOf(found.channel), emptyList())
        } catch (e: Exception) {
            PodResults(q, emptyList(), emptyList(), error = "Couldn't open that link. Check your connection and try again.")
        }
    }
    coroutineScope {
        val shows = async { runCatching { Feeds.searchShows(q) }.getOrDefault(emptyList()) }
        val tube = async { runCatching { YouTubePodcasts.search(q) }.getOrNull() }
        val s = shows.await()
        val t = tube.await()
        if (t == null && s.isEmpty()) PodResults(q, emptyList(), emptyList(), error = "Search failed. Check your connection and try again.")
        else PodResults(q, s + t?.first.orEmpty(), t?.second.orEmpty())
    }
}

@Composable
fun SearchScreen() {
    val focus = LocalFocusManager.current
    // Podcasts: searches a moment after you stop typing.
    LaunchedEffect(SearchState.query, SearchState.podcasts) {
        if (!SearchState.podcasts) return@LaunchedEffect
        val q = SearchState.query.trim()
        if (q.isEmpty()) {
            SearchState.podResults = null
            return@LaunchedEffect
        }
        if (q == SearchState.podResults?.query) return@LaunchedEffect
        delay(450)
        SearchState.searching = true
        try {
            SearchState.podResults = searchPodcasts(q)
        } finally {
            SearchState.searching = false
        }
    }
    // Music: searches a moment after you stop typing.
    LaunchedEffect(SearchState.query, SearchState.podcasts) {
        if (SearchState.podcasts) return@LaunchedEffect
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
                e::class.java.simpleName + (e.message?.let { ": $it" } ?: "") +
                (e.cause?.let { c -> "\n" + c::class.java.simpleName + (c.message?.let { ": $it" } ?: "") } ?: "")
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
            placeholder = { Text(if (SearchState.podcasts) "Shows, channels, or paste a link" else "What do you want to listen to?") },
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
        Row(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for ((label, pods) in listOf("Music" to false, "Podcasts" to true)) {
                val on = SearchState.podcasts == pods
                Text(
                    label, color = if (on) DriftColors.onAccent else DriftColors.text, fontSize = 14.sp, fontWeight = FontWeight.Bold,
                    modifier = Modifier.clip(RoundedCornerShape(17.dp)).background(if (on) DriftColors.accent else DriftColors.surface2)
                        .clickable { SearchState.podcasts = pods }.padding(horizontal = 16.dp, vertical = 8.dp),
                )
            }
        }
        if (SearchState.podcasts) {
            PodcastResults()
            return@Column
        }

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

@Composable
private fun PodcastResults() {
    val r = SearchState.podResults
    when {
        SearchState.searching && (r == null || r.query != SearchState.query.trim()) -> Box(Modifier.fillMaxWidth().padding(40.dp), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = DriftColors.accent)
        }
        r == null || SearchState.query.isBlank() -> EmptyText("Find podcasts and YouTube channels. Paste a show's RSS feed link to follow it, or a YouTube link to play any video.")
        r.error != null -> EmptyText(r.error)
        r.video == null && r.shows.isEmpty() && r.episodes.isEmpty() -> EmptyText("Nothing found for \u201C${r.query}\u201D.")
        else -> LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
            r.video?.let { v ->
                item { SectionTitle("Video") }
                item { EpisodeRow(v) }
            }
            if (r.shows.isNotEmpty()) {
                item { SectionTitle("Shows and channels") }
                items(r.shows.size, key = { "s-" + r.shows[it].id }) { ShowRow(r.shows[it]) }
            }
            if (r.episodes.isNotEmpty()) {
                item { SectionTitle("Episodes") }
                items(r.episodes.size, key = { "e-" + r.episodes[it].id }) { EpisodeRow(r.episodes[it]) }
            }
        }
    }
}
