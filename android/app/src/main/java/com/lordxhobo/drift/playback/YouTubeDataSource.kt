package com.lordxhobo.drift.playback

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.HttpDataSource
import com.lordxhobo.drift.youtube.HttpDownloader
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.schabi.newpipe.extractor.services.youtube.YoutubeParsingHelper
import java.io.IOException
import java.io.InputStream

/**
 * Reads YouTube audio the way YouTube's own players do (as NewPipe does): the byte range as a `range`
 * parameter instead of a header, a request number (`rn`), a small POST body, and the user agent of the
 * client the link was made for. Plain requests for other files.
 */
@UnstableApi
class YouTubeDataSource(private val client: OkHttpClient) : BaseDataSource(true) {

    class Factory(private val client: OkHttpClient) : DataSource.Factory {
        override fun createDataSource(): DataSource = YouTubeDataSource(client)
    }

    private var response: Response? = null
    private var stream: InputStream? = null
    private var uri: Uri? = null
    private var opened = false
    private var bytesToRead = C.LENGTH_UNSET.toLong()
    private var bytesRead = 0L
    private var requestNumber = 0

    override fun open(dataSpec: DataSpec): Long {
        uri = dataSpec.uri
        bytesRead = 0
        bytesToRead = C.LENGTH_UNSET.toLong()
        transferInitializing(dataSpec)

        var url = dataSpec.uri.toString()
        val position = dataSpec.position
        val length = dataSpec.length
        val unbounded = length == C.LENGTH_UNSET.toLong()
        val builder = Request.Builder()
        if (url.contains("/videoplayback")) {
            if (position != 0L || !unbounded) {
                url += "&range=$position-" + (if (unbounded) "" else (position + length - 1).toString())
            }
            requestNumber += 1
            url += "&rn=$requestNumber"
            builder.post(POST_BODY.toRequestBody())
            if (YoutubeParsingHelper.isWebStreamingUrl(url)) {
                builder.header("Origin", "https://www.youtube.com")
                builder.header("Referer", "https://www.youtube.com")
            }
        } else {
            builder.get()
            if (position != 0L || !unbounded) {
                builder.header("Range", "bytes=$position-" + (if (unbounded) "" else (position + length - 1).toString()))
            }
        }
        val agent = if (YoutubeParsingHelper.isVisionOsStreamingUrl(url)) {
            YoutubeParsingHelper.getVisionOsUserAgent(null)
        } else {
            HttpDownloader.USER_AGENT
        }
        builder.url(url).header("User-Agent", agent).header("Accept-Encoding", "identity")

        val r = try {
            client.newCall(builder.build()).execute()
        } catch (e: IOException) {
            throw HttpDataSource.HttpDataSourceException(
                e, dataSpec, androidx.media3.common.PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
                HttpDataSource.HttpDataSourceException.TYPE_OPEN
            )
        }
        if (!r.isSuccessful) {
            val code = r.code
            val message = r.message
            val headers = r.headers.toMultimap()
            r.close()
            throw HttpDataSource.InvalidResponseCodeException(code, message, null, headers, dataSpec, ByteArray(0))
        }
        response = r
        val body = r.body ?: throw IOException("Empty response")
        stream = body.byteStream()
        val contentLength = body.contentLength()
        bytesToRead = when {
            !unbounded -> length
            contentLength >= 0 -> contentLength
            else -> C.LENGTH_UNSET.toLong()
        }
        opened = true
        transferStarted(dataSpec)
        return bytesToRead
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        var toRead = length
        if (bytesToRead != C.LENGTH_UNSET.toLong()) {
            val remaining = bytesToRead - bytesRead
            if (remaining <= 0) return C.RESULT_END_OF_INPUT
            toRead = minOf(toRead.toLong(), remaining).toInt()
        }
        val read = stream?.read(buffer, offset, toRead) ?: return C.RESULT_END_OF_INPUT
        if (read == -1) return C.RESULT_END_OF_INPUT
        bytesRead += read
        bytesTransferred(read)
        return read
    }

    override fun getUri(): Uri? = uri

    override fun close() {
        try {
            stream?.close()
        } catch (_: IOException) {
        }
        response?.close()
        stream = null
        response = null
        if (opened) {
            opened = false
            transferEnded()
        }
    }

    companion object {
        private val POST_BODY = byteArrayOf(0x78, 0)
    }
}
