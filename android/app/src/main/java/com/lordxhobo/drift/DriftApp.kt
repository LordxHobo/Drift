package com.lordxhobo.drift

import android.app.Application
import com.lordxhobo.drift.data.Library
import com.lordxhobo.drift.social.Social
import com.lordxhobo.drift.youtube.HttpDownloader
import org.schabi.newpipe.extractor.NewPipe

class DriftApp : Application() {
    override fun onCreate() {
        super.onCreate()
        NewPipe.init(HttpDownloader.shared)
        Library.load(this)
        Social.init(this)
    }
}
