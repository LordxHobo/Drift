# Nightjar

A personal Spotify-style music player for iPhone. Music comes from YouTube Music, played on-device with no server.

- Search YouTube Music (album audio by default, or music videos too)
- Playlists, Liked songs, Recently played
- Downloads for offline playback (whole playlists in one tap)
- Background playback, lock screen and Control Center controls
- CarPlay and Bluetooth playback with steering-wheel controls; AirPlay picker in the player
- Live synced lyrics (LRCLIB), with Genius as the unsynced fallback
- No ads: audio is streamed directly; non-music parts of music videos are skipped (SponsorBlock)
- Best stream the iPhone can play natively (AAC); "Data saver" option for mobile data

## Build

GitHub Actions builds an unsigned IPA on every push to `main` (`.github/workflows/build.yml`).
Download the **nightjar-ios** artifact from the run and install `nightjar-unsigned.ipa` with Sideloadly or AltStore.

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`.

## CarPlay

Audio always plays through CarPlay with Now Playing info and controls. Nightjar's own CarPlay screens
(Home / Playlists / Downloads) need Apple's `com.apple.developer.carplay-audio` entitlement, which a free
or sideloading Apple ID can't sign. If you ever get that entitlement on a paid developer account, add it
to an entitlements file and the CarPlay screens in `Nightjar/CarPlay` start working.

## Layout

```
Nightjar/
  App/        app entry
  Core/       models, library storage, player, downloads, settings, theme
  Services/   YouTube Music search, stream extraction (YouTubeKit), lyrics, SponsorBlock
  Views/      SwiftUI screens
  CarPlay/    CarPlay scene
```
