package com.lordxhobo.drift

import android.app.Application
import coil.ImageLoader
import coil.ImageLoaderFactory
import com.lordxhobo.drift.data.Library
import com.lordxhobo.drift.playback.Downloads
import com.lordxhobo.drift.podcasts.PodcastStore
import com.lordxhobo.drift.playback.Equalizer
import com.lordxhobo.drift.playback.Skipping
import com.lordxhobo.drift.playback.SongCache
import com.lordxhobo.drift.social.CollabSync
import com.lordxhobo.drift.social.Friends
import com.lordxhobo.drift.social.Inbox
import com.lordxhobo.drift.social.Jam
import com.lordxhobo.drift.social.Remote
import com.lordxhobo.drift.social.ThisDevice
import com.lordxhobo.drift.social.LibrarySync
import com.lordxhobo.drift.social.PlayHistory
import com.lordxhobo.drift.social.PlaylistSharing
import com.lordxhobo.drift.social.Social
import com.lordxhobo.drift.youtube.HttpDownloader
import org.schabi.newpipe.extractor.NewPipe

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class DriftApp : Application(), ImageLoaderFactory {
    override fun onCreate() {
        super.onCreate()
        NewPipe.init(HttpDownloader.shared)
        Library.load(this)
        PodcastStore.init(this)
        Notices.init(this)
        Releases.appContext = this
        Notices.schedule(this)
        SongCache.init(this)
        Downloads.init(this)
        Skipping.init(this)
        com.lordxhobo.drift.playback.EpisodeVideo.init(this)
        Equalizer.init(this)
        LibrarySync.init(this)
        PlaylistSharing.init()
        Friends.init()
        CollabSync.init(this)
        Social.init(this)
        ThisDevice.init(this)
        PlayHistory.init(this)
        Remote.init()
        Jam.init()
        Inbox.init()
        com.lordxhobo.drift.social.PodcastSync.init()
    }

    /**
     * Pictures load over Drift's own connection (IPv4 first, quick to drop a dead route), not the image
     * library's: on networks with broken IPv6 they otherwise took minutes to appear.
     */
    override fun newImageLoader(): ImageLoader =
        ImageLoader.Builder(this)
            .okHttpClient { HttpDownloader.shared.client }
            .crossfade(true)
            .build()
}
