package com.lordxhobo.drift.playback

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import com.lordxhobo.drift.youtube.HttpDownloader
import okhttp3.Request
import java.io.File
import java.io.FileNotFoundException

/**
 * Pictures for Android Auto's lists. Android Auto only shows pictures it can open as files, not web links,
 * so each one is fetched once into Drift's cache and handed over from there.
 */
class CarArt : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val ctx = context ?: throw FileNotFoundException()
        val url = uri.getQueryParameter("u") ?: throw FileNotFoundException()
        val link = Uri.parse(url)
        if (link.scheme != "https") throw FileNotFoundException()
        val dir = File(ctx.cacheDir, "car-art").apply { mkdirs() }
        val file = File(dir, hash(url) + ".img")
        if (!file.exists()) {
            val request = Request.Builder().url(url).header("User-Agent", HttpDownloader.USER_AGENT).build()
            HttpDownloader.shared.client.newCall(request).execute().use { r ->
                val body = r.body
                val type = r.header("Content-Type").orEmpty()
                if (!r.isSuccessful || body == null || !type.startsWith("image/")) throw FileNotFoundException()
                val bytes = body.bytes()
                if (bytes.size > MAX_BYTES) throw FileNotFoundException()
                val tmp = File(dir, file.name + ".tmp")
                tmp.writeBytes(bytes)
                tmp.renameTo(file)
            }
            trim(dir)
        }
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    /** Keeps the cache small: the oldest pictures go past 400. */
    private fun trim(dir: File) {
        val files = dir.listFiles()?.filter { it.name.endsWith(".img") } ?: return
        if (files.size <= 400) return
        files.sortedBy { it.lastModified() }.take(files.size - 400).forEach { it.delete() }
    }

    override fun getType(uri: Uri): String = "image/*"
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, args: Array<out String>?, sort: String?): Cursor? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, args: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, args: Array<out String>?): Int = 0

    companion object {
        private const val MAX_BYTES = 4 * 1024 * 1024

        /** A picture's address that Android Auto can open. */
        fun uri(context: Context, url: String?): Uri? {
            if (url.isNullOrEmpty() || !url.startsWith("https://")) return null
            return Uri.Builder().scheme("content").authority("${context.packageName}.art").path("img").appendQueryParameter("u", url).build()
        }

        private fun hash(s: String): String {
            var h = -0x340d631b7bdddcdbL
            for (b in s.toByteArray()) {
                h = h xor (b.toLong() and 0xff)
                h *= 0x100000001b3L
            }
            return java.lang.Long.toUnsignedString(h, 16)
        }
    }
}
