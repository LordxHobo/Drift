package com.lordxhobo.drift.social

import com.lordxhobo.drift.youtube.HttpDownloader
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/** Plain HTTP for Drift's server (Firebase), on the app's shared connection (IPv4 first). */
object Net {
    private val client by lazy { HttpDownloader.shared.client.newBuilder().callTimeout(20, TimeUnit.SECONDS).build() }

    /** Sends a request and returns the status code and the body. Blocking: call it off the main thread. */
    fun send(method: String, url: String, body: String? = null, contentType: String = "application/json", token: String? = null): Pair<Int, String> {
        val b = Request.Builder().url(url)
        if (token != null) b.header("Authorization", "Bearer $token")
        b.method(method, body?.toRequestBody(contentType.toMediaType()))
        client.newCall(b.build()).execute().use { r -> return r.code to (r.body?.string() ?: "") }
    }
}
