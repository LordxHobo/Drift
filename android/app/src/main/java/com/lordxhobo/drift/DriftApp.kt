package com.lordxhobo.drift

import android.app.Application
import com.lordxhobo.drift.data.Library
import com.lordxhobo.drift.playback.Downloads
import com.lordxhobo.drift.playback.SongCache
import com.lordxhobo.drift.social.LibrarySync
import com.lordxhobo.drift.social.Social
import com.lordxhobo.drift.youtube.HttpDownloader
import org.schabi.newpipe.extractor.NewPipe

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class DriftApp : Application() {
    override fun onCreate() {
        super.onCreate()
        NewPipe.init(HttpDownloader.shared)
        Library.load(this)
        SongCache.init(this)
        Downloads.init(this)
        LibrarySync.init(this)
        Social.init(this)
    }
}
