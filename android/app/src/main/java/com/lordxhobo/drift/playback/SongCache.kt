package com.lordxhobo.drift.playback

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.FileDataSource
import androidx.media3.datasource.TransferListener
import androidx.media3.datasource.cache.Cache
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheEvictor
import androidx.media3.datasource.cache.CacheSpan
import androidx.media3.datasource.cache.SimpleCache
import java.io.File
import java.util.TreeSet

/**
 * Recently played songs kept on the phone, so they start at once, use no data the second time, and
 * play offline. Oldest-played go first when the cache is full. Songs are stored by video ID, so a
 * fresh link for the same song still finds them.
 */
@androidx.annotation.OptIn(UnstableApi::class)
object SongCache {
    /** Choices in Settings, in MB (0 = off). */
    val SIZES = listOf(0, 250, 500, 1000, 2000)
    private const val DEFAULT_MB = 500

    lateinit var cache: SimpleCache
        private set
    private lateinit var prefs: SharedPreferences
    private val evictor = Evictor()

    var sizeMB by mutableStateOf(DEFAULT_MB)
        private set

    fun init(context: Context) {
        prefs = context.getSharedPreferences("drift.settings", Context.MODE_PRIVATE)
        sizeMB = prefs.getInt("songCacheMB", DEFAULT_MB).takeIf { it in SIZES } ?: DEFAULT_MB
        cache = SimpleCache(File(context.cacheDir, "songs"), evictor, StandaloneDatabaseProvider(context))
    }

    val usedBytes: Long get() = runCatching { cache.cacheSpace }.getOrDefault(0L)

    fun setSize(mb: Int) {
        sizeMB = mb
        prefs.edit().putInt("songCacheMB", mb).apply()
        Thread { evictor.trim(cache) }.start()
    }

    fun clear() {
        Thread { for (key in cache.keys.toList()) runCatching { cache.removeResource(key) } }.start()
    }

    /** Forgets one song (when its saved part turned out to be broken). */
    fun forget(id: String) {
        runCatching { cache.removeResource(key(id)) }
    }

    fun key(id: String) = "${PlaybackService.SCHEME}://song/$id"

    /** Least-recently-used, with a limit that can change while Drift runs. */
    private class Evictor : CacheEvictor {
        private val spans = TreeSet<CacheSpan>(compareBy<CacheSpan>({ it.lastTouchTimestamp }, { it.key }, { it.position }))
        private var size = 0L
        private val limit get() = SongCache.sizeMB * 1024L * 1024L

        override fun requiresCacheSpanTouches() = true
        override fun onCacheInitialized() {}

        override fun onStartFile(cache: Cache, key: String, position: Long, length: Long) {
            if (length != -1L) evict(cache, length)
        }

        override fun onSpanAdded(cache: Cache, span: CacheSpan) {
            synchronized(spans) {
                spans.add(span)
                size += span.length
            }
            evict(cache, 0)
        }

        override fun onSpanRemoved(cache: Cache, span: CacheSpan) {
            synchronized(spans) {
                spans.remove(span)
                size -= span.length
            }
        }

        override fun onSpanTouched(cache: Cache, oldSpan: CacheSpan, newSpan: CacheSpan) {
            onSpanRemoved(cache, oldSpan)
            onSpanAdded(cache, newSpan)
        }

        fun trim(cache: Cache) = evict(cache, 0)

        private fun evict(cache: Cache, needed: Long) {
            while (true) {
                val oldest = synchronized(spans) {
                    if (size + needed <= limit || spans.isEmpty()) null else spans.first()
                } ?: return
                runCatching { cache.removeSpan(oldest) }.onFailure {
                    synchronized(spans) {
                        spans.remove(oldest)
                        size -= oldest.length
                    }
                }
            }
        }
    }
}

/**
 * Where a song plays from: its download when there is one, else the song cache (or straight from
 * YouTube when the cache is off).
 */
@androidx.annotation.OptIn(UnstableApi::class)
class SongDataSource(
    private val cached: DataSource,
    private val direct: DataSource,
) : DataSource {
    private val local = FileDataSource()
    private var current: DataSource? = null

    class Factory(private val cached: DataSource.Factory, private val direct: DataSource.Factory) : DataSource.Factory {
        override fun createDataSource(): DataSource = SongDataSource(cached.createDataSource(), direct.createDataSource())
    }

    override fun addTransferListener(transferListener: TransferListener) {
        local.addTransferListener(transferListener)
        cached.addTransferListener(transferListener)
        direct.addTransferListener(transferListener)
    }

    override fun open(dataSpec: DataSpec): Long {
        val uri = dataSpec.uri
        if (uri.scheme == PlaybackService.SCHEME) {
            val id = uri.lastPathSegment
            val file = id?.let { Downloads.file(it) }
            if (file != null) {
                current = local
                return local.open(dataSpec.withUri(Uri.fromFile(file)))
            }
        }
        // Episodes from a show's feed are big files played once: not kept in the song cache.
        val episode = uri.scheme == PlaybackService.SCHEME && uri.lastPathSegment?.startsWith("rss-") == true
        val source = if (SongCache.sizeMB > 0 && !episode) cached else direct
        current = source
        return source.open(dataSpec)
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
        current?.read(buffer, offset, length) ?: androidx.media3.common.C.RESULT_END_OF_INPUT

    override fun getUri(): Uri? = current?.uri

    override fun getResponseHeaders(): Map<String, List<String>> = current?.responseHeaders ?: emptyMap()

    override fun close() {
        try {
            current?.close()
        } finally {
            current = null
        }
    }

    companion object {
        /** The song cache over YouTube: stored by the song's own address (drift://song/<id>). */
        fun cacheFactory(upstream: DataSource.Factory): DataSource.Factory =
            CacheDataSource.Factory()
                .setCache(SongCache.cache)
                .setUpstreamDataSourceFactory(upstream)
                .setCacheKeyFactory { spec -> spec.key ?: spec.uri.toString() }
                .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
    }
}
