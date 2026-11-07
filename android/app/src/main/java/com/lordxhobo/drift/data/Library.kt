package com.lordxhobo.drift.data

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File

/** Playlists, liked songs and recently played, saved as JSON on this phone. */
object Library {
    @Serializable
    private data class Stored(
        val playlists: List<Playlist> = emptyList(),
        val liked: List<Track> = emptyList(),
        val recent: List<Track> = emptyList(),
    )

    val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        encodeDefaults = false
    }

    var playlists by mutableStateOf(listOf<Playlist>())
        private set
    var liked by mutableStateOf(listOf<Track>())
        private set
    var recent by mutableStateOf(listOf<Track>())
        private set

    private lateinit var file: File

    /** Called after every change made on this phone (library sync listens). */
    var onLocalChange: (() -> Unit)? = null

    fun load(context: Context) {
        file = File(context.filesDir, "library.json")
        val s = runCatching { json.decodeFromString<Stored>(file.readText()) }.getOrNull() ?: return
        playlists = s.playlists
        liked = s.liked
        recent = s.recent
    }

    private fun save(local: Boolean = true) {
        if (local) onLocalChange?.invoke()
        val s = Stored(playlists, liked, recent)
        val text = json.encodeToString(s)
        val tmp = File(file.parentFile, "library.json.tmp")
        runCatching {
            tmp.writeText(text)
            tmp.renameTo(file)
        }
    }

    // Liked songs

    fun isLiked(id: String): Boolean = liked.any { it.id == id }

    fun toggleLike(t: Track) {
        liked = if (isLiked(t.id)) liked.filterNot { it.id == t.id } else listOf(t.copy(added = nowApple())) + liked
        save()
    }

    // Playlists

    fun playlist(id: String): Playlist? = playlists.firstOrNull { it.id == id }

    fun createPlaylist(name: String, tracks: List<Track> = emptyList()): Playlist {
        val trimmed = name.trim()
        val p = Playlist(
            name = trimmed.ifEmpty { "My playlist #${playlists.size + 1}" },
            tracks = tracks.map { it.copy(added = nowApple()) },
            colorIndex = playlists.size,
        )
        playlists = playlists + p
        save()
        return p
    }

    fun rename(id: String, name: String) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return
        update(id) { it.copy(name = trimmed) }
    }

    fun deletePlaylist(id: String) {
        playlists = playlists.filterNot { it.id == id }
        save()
    }

    fun add(t: Track, to: String) {
        update(to) { p -> if (p.tracks.any { it.id == t.id }) p else p.copy(tracks = p.tracks + t.copy(added = nowApple())) }
    }

    fun remove(index: Int, from: String) {
        update(from) { p -> p.copy(tracks = p.tracks.filterIndexed { i, _ -> i != index }) }
    }

    /** An album saved to the library (kept as a playlist). */
    fun saveAlbum(title: String, artist: String, tracks: List<Track>): Playlist {
        playlists.firstOrNull { it.isAlbum == true && it.name == title && it.albumArtist == artist }?.let { return it }
        val p = createPlaylist(title, tracks)
        update(p.id) { it.copy(isAlbum = true, albumArtist = artist) }
        return playlist(p.id) ?: p
    }

    private fun update(id: String, change: (Playlist) -> Playlist) {
        playlists = playlists.map { if (it.id == id) change(it) else it }
        save()
    }

    // From library sync (changes from other devices: these don't sync back)

    fun replaceLiked(list: List<Track>) {
        liked = list
        save(local = false)
    }

    /** A playlist from another device: replaces this phone's copy, or is added at its position. */
    fun applyRemotePlaylist(p: Playlist, position: Int) {
        val rest = playlists.filterNot { it.id == p.id }
        val at = position.coerceIn(0, rest.size)
        playlists = rest.take(at) + p + rest.drop(at)
        save(local = false)
    }

    fun removeRemotePlaylist(id: String) {
        if (playlists.none { it.id == id }) return
        playlists = playlists.filterNot { it.id == id }
        save(local = false)
    }

    // Recently played

    fun addRecent(t: Track) {
        recent = (listOf(t) + recent.filterNot { it.id == t.id }).take(30)
        save(local = false)
    }
}
