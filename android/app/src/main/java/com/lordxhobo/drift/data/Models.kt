package com.lordxhobo.drift.data

import kotlinx.serialization.Serializable
import java.util.UUID

/**
 * A song, backed by a YouTube video. The same JSON as the iPhone and the computer (field names, and
 * dates as seconds since 2001-01-01), so the library can sync between them later.
 */
@Serializable
data class Track(
    val id: String,
    val title: String,
    val artist: String,
    val album: String? = null,
    /** Seconds. */
    val duration: Double? = null,
    val artworkURL: String? = null,
    val explicit: Boolean? = null,
    /** When it was added to its playlist or Liked songs (seconds since 2001-01-01). */
    val added: Double? = null,
    /** A regular YouTube upload, not a YouTube Music song (keeps other devices from swapping its version). */
    val upload: Boolean? = null,
) {
    /** Artwork at roughly the asked size (YouTube Music pictures can be asked for any size). */
    fun artwork(size: Int): String {
        val url = artworkURL ?: return "https://i.ytimg.com/vi/$id/hqdefault.jpg"
        return if (url.contains("googleusercontent.com") || url.contains("ggpht.com")) {
            url.replace(Regex("=w\\d+-h\\d+"), "=w$size-h$size")
        } else url
    }

    val durationText: String get() = duration?.let { formatTime(it) } ?: ""
}

@Serializable
data class Playlist(
    /** An upper-case UUID, like on the iPhone. */
    val id: String = UUID.randomUUID().toString().uppercase(),
    val name: String,
    val tracks: List<Track> = emptyList(),
    val colorIndex: Int = 0,
    val coverStyle: String? = null,
    val coverSymbol: String? = null,
    val isPublic: Boolean? = null,
    val isAlbum: Boolean? = null,
    val albumArtist: String? = null,
    val folder: String? = null,
    /** A photo cover from another device (JPEG, Base64), kept so syncing doesn't drop it. */
    val cover64: String? = null,
)

/** A folder of playlists (playlists point to it with `folder`). */
@Serializable
data class PlaylistFolder(val id: String = UUID.randomUUID().toString().uppercase(), val name: String)

/** An artist, an album or a playlist found on YouTube Music. */
data class ArtistRef(val url: String, val name: String, val thumbnail: String?)
data class AlbumRef(val url: String, val title: String, val artist: String, val thumbnail: String?)

/** Seconds since 2001-01-01, how the iPhone stores dates. */
fun nowApple(): Double = System.currentTimeMillis() / 1000.0 - 978_307_200.0

fun formatTime(seconds: Double): String {
    if (!seconds.isFinite() || seconds < 0) return "0:00"
    val s = seconds.toLong()
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, (s % 3600) / 60, s % 60)
    else "%d:%02d".format(s / 60, s % 60)
}

fun formatTotal(tracks: List<Track>): String {
    val total = tracks.sumOf { it.duration ?: 0.0 }.toLong()
    val h = total / 3600
    val m = (total % 3600) / 60
    return if (h > 0) "$h h $m min" else "$m min"
}
