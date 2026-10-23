# Drift

A personal Spotify-style music player for iPhone. Music comes from YouTube Music, played on-device with no server.

- Search YouTube Music (album audio by default, or music videos too)
- Playlists (rename, custom cover photo or color + icon), Liked songs with one-tap hearts, Recently played
- Import public Spotify playlists and albums from a link (first 100 songs, matched on YouTube Music)
- Podcasts from YouTube: search shows and channels, paste any YouTube link, follow channels for new episodes,
  resume where you stopped, 0.75–2× speed, 15/30 s skip, sponsor segments skipped (SponsorBlock),
  chapters (list, marks on the progress bar, next/previous chapter from the steering wheel)
- Downloads for offline playback (whole playlists in one tap)
- Background playback, lock screen and Control Center controls
- CarPlay and Bluetooth playback with steering-wheel controls; AirPlay picker in the player
- Live synced lyrics (LRCLIB), with Genius as the unsynced fallback
- Current lyric line as a Live Activity: lock screen, Dynamic Island and the CarPlay screen (iOS 26)
- No ads: audio is streamed directly; non-music parts of music videos are skipped (SponsorBlock)
- Best stream the iPhone can play natively (AAC); "Data saver" option for mobile data

## Build

GitHub Actions builds an unsigned IPA on every push to `main` (`.github/workflows/build.yml`).
Download the **drift-ios** artifact from the run and install `drift-unsigned.ipa` with Sideloadly or AltStore.

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`.

## CarPlay

Audio always plays through CarPlay with Now Playing info and controls. Drift's own CarPlay screens
(Home / Playlists / Downloads) need Apple's `com.apple.developer.carplay-audio` entitlement, which a free
or sideloading Apple ID can't sign. If you ever get that entitlement on a paid developer account, add it
to an entitlements file and the CarPlay screens in `Drift/CarPlay` start working.

## Layout

```
Drift/
  App/        app entry
  Core/       models, library storage, player, downloads, settings, theme
  Services/   YouTube Music search, stream extraction (YouTubeKit), lyrics, SponsorBlock
  Views/      SwiftUI screens
  CarPlay/    CarPlay scene
DriftLyrics/  widget extension with the lyrics Live Activity
Shared/       code used by both the app and the extension
```

The Live Activity can only be started while Drift is open on screen (an iOS rule). After that it keeps
updating in the background, across songs, including on CarPlay.
