package com.lordxhobo.drift.data

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import java.io.File

/** Playlists, liked songs and recently played, saved as JSON on this phone. */
object Library {
    @Serializable
    private data class Stored(
        val playlists: List<Playlist> = emptyList(),
        val liked: List<Track> = emptyList(),
        val recent: List<Track> = emptyList(),
        val folders: List<PlaylistFolder> = emptyList(),
        /** Followed artists, as the other apps store them ({artist, followedAt, known, newReleases}). */
        val artists: List<JsonObject> = emptyList(),
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
    var folders by mutableStateOf(listOf<PlaylistFolder>())
        private set
    /** Followed artists, kept whole so details only the other apps use (new releases) survive syncing. */
    var artists by mutableStateOf(listOf<JsonObject>())
        private set

    private lateinit var file: File

    /** Called after every change made on this phone (library sync listens). */
    var onLocalChange: (() -> Unit)? = null

    /** Called after every change, from here or another device (downloads listen). */
    val onAnyChange = mutableListOf<() -> Unit>()

    fun load(context: Context) {
        file = File(context.filesDir, "library.json")
        val s = runCatching { json.decodeFromString<Stored>(file.readText()) }.getOrNull() ?: return
        playlists = s.playlists
        liked = s.liked
        recent = s.recent
        folders = s.folders
        artists = s.artists
    }

    private fun save(local: Boolean = true) {
        if (local) onLocalChange?.invoke()
        onAnyChange.forEach { it() }
        val s = Stored(playlists, liked, recent, folders, artists)
        val text = json.encodeToString(s)
        val tmp = File(file.parentFile, "library.json.tmp")
        runCatching {
            tmp.writeText(text)
            tmp.renameTo(file)
        }
    }

    // Liked songs

    /** Liked songs, where a song's place is given as a list ("Replace with another version"). */
    const val LIKED = "liked"

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

    /**
     * What Edit playlist saves: name, cover (`style` auto, color or photo; `photo64` a new square JPEG in
     * Base64, or null to keep the one it has), and whether it shows on your profile. Same as the iPhone.
     */
    fun updatePlaylist(id: String, name: String, style: String, colorIndex: Int, symbol: String, photo64: String?, isPublic: Boolean) {
        update(id) { p ->
            val cover = photo64 ?: p.cover64
            // A photo cover with no photo is the automatic one; a photo no longer used goes.
            val s = if (style == "photo" && cover == null) "auto" else style
            p.copy(
                name = name.trim().ifEmpty { p.name },
                coverStyle = s,
                colorIndex = colorIndex,
                coverSymbol = symbol,
                cover64 = if (s == "photo") cover else null,
                isPublic = isPublic,
            )
        }
    }

    /** Edit songs: the playlist's songs in their new order, without the ones taken out. */
    fun setTracks(id: String, tracks: List<Track>) = update(id) { it.copy(tracks = tracks) }

    fun deletePlaylist(id: String) {
        playlists = playlists.filterNot { it.id == id }
        save()
    }

    fun add(t: Track, to: String) {
        update(to) { p -> if (p.tracks.any { it.id == t.id }) p else p.copy(tracks = p.tracks + t.copy(added = nowApple())) }
    }

    /** Several songs at once (imports keep their own added dates); songs already there are skipped. */
    fun addAll(tracks: List<Track>, to: String) {
        update(to) { p ->
            val have = p.tracks.map { it.id }.toMutableSet()
            p.copy(tracks = p.tracks + tracks.filter { have.add(it.id) }.map { if (it.added == null) it.copy(added = nowApple()) else it })
        }
    }

    fun remove(index: Int, from: String) {
        update(from) { p -> p.copy(tracks = p.tracks.filterIndexed { i, _ -> i != index }) }
    }

    /**
     * Swaps a song for another version in the same spot (`from` is a playlist, or "liked"); if the new one
     * is already in the list, the old one just goes. Keeps when it was added.
     */
    fun replace(from: String, index: Int, oldId: String, t: Track) {
        fun swap(list: List<Track>): List<Track> {
            val i = if (list.getOrNull(index)?.id == oldId) index else list.indexOfFirst { it.id == oldId }
            if (i < 0) return list
            if (list.withIndex().any { (j, x) -> j != i && x.id == t.id }) return list.filterIndexed { j, _ -> j != i }
            return list.toMutableList().also { it[i] = t.copy(added = list[i].added, addedBy = list[i].addedBy) }
        }
        if (from == LIKED) {
            liked = swap(liked)
            save()
        } else update(from) { p -> p.copy(tracks = swap(p.tracks)) }
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

    // Folders

    fun createFolder(name: String, playlistIds: List<String> = emptyList()): PlaylistFolder {
        val f = PlaylistFolder(name = name.trim().ifEmpty { "New folder" })
        folders = folders + f
        playlists = playlists.map { if (it.id in playlistIds) it.copy(folder = f.id) else it }
        save()
        return f
    }

    fun renameFolder(id: String, name: String) {
        if (name.isBlank()) return
        folders = folders.map { if (it.id == id) it.copy(name = name.trim()) else it }
        save()
    }

    /** The folder goes; its playlists stay, outside any folder. */
    fun deleteFolder(id: String) {
        folders = folders.filterNot { it.id == id }
        playlists = playlists.map { if (it.folder == id) it.copy(folder = null) else it }
        save()
    }

    fun moveToFolder(playlistId: String, folderId: String?) = update(playlistId) { it.copy(folder = folderId) }

    // Followed artists

    fun artistRef(o: JsonObject): ArtistRef? {
        val a = o["artist"] as? JsonObject ?: return null
        val id = (a["id"] as? JsonPrimitive)?.contentOrNull ?: return null
        val name = (a["name"] as? JsonPrimitive)?.contentOrNull ?: return null
        return ArtistRef(id, name, (a["thumbnail"] as? JsonPrimitive)?.contentOrNull)
    }

    val followed: List<ArtistRef> get() = artists.mapNotNull { artistRef(it) }

    fun isFollowing(id: String): Boolean = artists.any { artistRef(it)?.url == id }

    /** `albums`: the artist's releases now, so only later ones count as new on the other apps. */
    fun follow(a: ArtistRef, albums: List<String>) {
        if (isFollowing(a.url)) return
        val entry = buildJsonObject {
            put("artist", buildJsonObject {
                put("id", a.url)
                put("name", a.name)
                put("thumbnail", a.thumbnail?.let { JsonPrimitive(it) } ?: JsonNull)
            })
            put("followedAt", nowApple())
            put("known", JsonArray(albums.map { JsonPrimitive(it) }))
            put("newReleases", JsonArray(emptyList()))
        }
        artists = listOf(entry) + artists
        save()
    }

    fun unfollow(id: String) {
        artists = artists.filterNot { artistRef(it)?.url == id }
        save()
    }

    // From library sync (changes from other devices: these don't sync back)

    fun replaceFolders(list: List<PlaylistFolder>) {
        folders = list
        save(local = false)
    }

    /** Followed artists from other devices. Keeps what this phone already knew about each (seen and new releases). */
    fun replaceArtists(list: List<JsonObject>) {
        artists = list.map { remote ->
            val id = artistRef(remote)?.url
            val mine = artists.firstOrNull { artistRef(it)?.url == id } ?: return@map remote
            val known = ((remote["known"] as? JsonArray).orEmpty() + (mine["known"] as? JsonArray).orEmpty()).distinct()
            val theirs = (remote["newReleases"] as? JsonArray).orEmpty()
            fun releaseId(e: kotlinx.serialization.json.JsonElement) =
                (((e as? JsonObject)?.get("album") as? JsonObject)?.get("id") as? JsonPrimitive)?.contentOrNull
            val ids = theirs.mapNotNull { releaseId(it) }.toSet()
            val news = theirs + (mine["newReleases"] as? JsonArray).orEmpty().filter { releaseId(it) !in ids }
            JsonObject(remote + mapOf("known" to JsonArray(known), "newReleases" to JsonArray(news)))
        }
        save(local = false)
    }

    /** Followed artists after looking for new releases (sent to your other devices). */
    fun updateArtists(list: List<JsonObject>) {
        artists = list
        save()
    }

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

    /** A shared playlist from its own document (added, or its songs, name and members updated). */
    fun setCollabPlaylist(p: Playlist) {
        playlists = if (playlists.any { it.id == p.id }) playlists.map { if (it.id == p.id) p else it } else playlists + p
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
