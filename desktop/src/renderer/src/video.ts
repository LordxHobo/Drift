// The picture for podcast episodes (optional). The sound always comes from the normal player;
// this silent video just follows it, so speed, skipping, the queue and media keys all keep working.
import { settingsStore, Store, useStore } from './state'
import { audioElement, playerStore } from './player'

/** "Best" quality: the sharpest the episode has. */
export const bestQuality = 4320

export const videoEl = document.createElement('video')
videoEl.muted = true
videoEl.playsInline = true
videoEl.preload = 'auto'
videoEl.className = 'episode-video'

/** Has a picture to show (the current episode's video has loaded). */
export const videoReadyStore = new Store(false)
export const useVideoReady = (): boolean => useStore(videoReadyStore)
/** The picture gave up loading (after trying again and at a lower quality). */
export const videoFailedStore = new Store(false)
export const useVideoFailed = (): boolean => useStore(videoFailedStore)

let currentKey = ''
/** Tries for the current video: 0 = as chosen, 1 = a fresh link, 2 = 480p, then give up. */
let attempt = 0
let watchdog: number | undefined
let lastSeek = 0

function wanted(): string {
  const p = playerStore.get()
  const s = settingsStore.get()
  const id = p.info?.playId
  // Episodes: when video is on. Videos from the YouTube viewer: always.
  if (!p.current?.podcast || p.current.audioURL || !(s.podcastVideo || p.current.watch) || !id) return ''
  return `drift://stream/${id}?v=${s.videoQuality || 720}`
}

function load(src: string): void {
  videoEl.src = src
  videoEl.currentTime = audioElement.currentTime
  window.clearTimeout(watchdog)
  // Stuck (the sound plays but no picture comes): try again rather than spin forever.
  watchdog = window.setTimeout(() => {
    if (!videoReadyStore.get() && currentKey) stuck()
  }, 12_000)
}

function update(): void {
  const key = wanted()
  if (key === currentKey) return
  currentKey = key
  attempt = 0
  videoReadyStore.set(false)
  videoFailedStore.set(false)
  window.clearTimeout(watchdog)
  if (key) {
    load(key)
  } else {
    videoEl.removeAttribute('src')
    videoEl.load()
  }
}

/** Didn't load: a fresh link first, then a lower quality, then show that it didn't work. */
function stuck(): void {
  if (!currentKey) return
  attempt++
  const id = playerStore.get().info?.playId
  if (attempt === 1) return load(`${currentKey}&fresh=${Date.now()}`)
  if (attempt === 2 && id) return load(`drift://stream/${id}?v=480&fresh=${Date.now()}`)
  window.clearTimeout(watchdog)
  videoFailedStore.set(true)
}

/** "Try again" on a picture that didn't load. */
export function retryVideo(): void {
  if (!currentKey) return
  attempt = 0
  videoFailedStore.set(false)
  load(`${currentKey}&fresh=${Date.now()}`)
}

videoEl.addEventListener('loadeddata', () => {
  window.clearTimeout(watchdog)
  videoReadyStore.set(true)
  videoFailedStore.set(false)
})
videoEl.addEventListener('error', () => {
  videoReadyStore.set(false)
  if (currentKey) stuck()
})

/** Keeps the picture in step with the sound (and costs nothing while it isn't on screen). */
function sync(): void {
  if (!currentKey || !videoEl.isConnected || videoEl.readyState < 1) return
  const audio = audioElement
  if (videoEl.playbackRate !== audio.playbackRate) videoEl.playbackRate = audio.playbackRate
  const drift = videoEl.currentTime - audio.currentTime
  // Not while it's still fetching: jumping again would restart the fetch (and it would never catch up).
  // A little ahead of the sound, so it lands in step once the jump has loaded.
  if (Math.abs(drift) > 0.5 && !videoEl.seeking && Date.now() - lastSeek > 2000) {
    lastSeek = Date.now()
    videoEl.currentTime = audio.currentTime + (audio.paused ? 0 : 0.3)
  }
  if (audio.paused && !videoEl.paused) videoEl.pause()
  if (!audio.paused && videoEl.paused) void videoEl.play().catch(() => undefined)
}

export function startVideo(): void {
  playerStore.subscribe(update)
  settingsStore.subscribe(update)
  audioElement.addEventListener('seeked', () => {
    if (currentKey) videoEl.currentTime = audioElement.currentTime
  })
  window.setInterval(sync, 250)
}
