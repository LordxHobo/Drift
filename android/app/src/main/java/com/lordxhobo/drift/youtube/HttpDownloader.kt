package com.lordxhobo.drift.youtube

import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.Request.Builder
import okhttp3.RequestBody.Companion.toRequestBody
import org.schabi.newpipe.extractor.downloader.Downloader
import org.schabi.newpipe.extractor.downloader.Request
import org.schabi.newpipe.extractor.downloader.Response
import org.schabi.newpipe.extractor.exceptions.ReCaptchaException
import java.net.Inet4Address
import java.net.InetAddress
import java.util.concurrent.TimeUnit

/** How NewPipeExtractor reaches YouTube: plain HTTP requests through OkHttp. */
class HttpDownloader private constructor(val client: OkHttpClient) : Downloader() {

    override fun execute(request: Request): Response {
        val body = request.dataToSend()?.toRequestBody()
        val builder = Builder()
            .url(request.url())
            .method(request.httpMethod(), body)
            .header("User-Agent", USER_AGENT)
        for ((name, values) in request.headers()) {
            builder.removeHeader(name)
            for (v in values) builder.addHeader(name, v)
        }
        client.newCall(builder.build()).execute().use { r ->
            if (r.code == 429) throw ReCaptchaException("YouTube asked for a captcha", request.url())
            val text = r.body?.string()
            return Response(r.code, r.message, r.headers.toMultimap(), text, r.request.url.toString())
        }
    }

    companion object {
        const val USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0"

        val shared: HttpDownloader by lazy {
            HttpDownloader(
                OkHttpClient.Builder()
                    .dns(Ipv4First)
                    // Short, so a dead route (often IPv6) is dropped quickly and the next one is tried.
                    .connectTimeout(6, TimeUnit.SECONDS)
                    .readTimeout(30, TimeUnit.SECONDS)
                    .build()
            )
        }
    }

    /**
     * IPv4 addresses first. Many home and mobile networks hand out IPv6 that doesn't actually work;
     * browsers try both at once, but OkHttp waits on the first one until the connection times out.
     */
    private object Ipv4First : Dns {
        override fun lookup(hostname: String): List<InetAddress> =
            Dns.SYSTEM.lookup(hostname).sortedBy { if (it is Inet4Address) 0 else 1 }
    }
}
