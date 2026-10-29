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

let currentKey = ''

function wanted(): string {
  const p = playerStore.get()
  const s = settingsStore.get()
  const id = p.info?.playId
  if (!p.current?.podcast || p.current.audioURL || !s.podcastVideo || !id) return ''
  return `drift://stream/${id}?v=${s.videoQuality || 720}`
}

function update(): void {
  const key = wanted()
  if (key === currentKey) return
  currentKey = key
  videoReadyStore.set(false)
  if (key) {
    videoEl.src = key
    videoEl.currentTime = audioElement.currentTime
  } else {
    videoEl.removeAttribute('src')
    videoEl.load()
  }
}

videoEl.addEventListener('loadeddata', () => videoReadyStore.set(true))
videoEl.addEventListener('error', () => videoReadyStore.set(false))

/** Keeps the picture in step with the sound (and costs nothing while it isn't on screen). */
function sync(): void {
  if (!currentKey || !videoEl.isConnected || videoEl.readyState < 1) return
  const audio = audioElement
  if (videoEl.playbackRate !== audio.playbackRate) videoEl.playbackRate = audio.playbackRate
  const drift = videoEl.currentTime - audio.currentTime
  if (Math.abs(drift) > 0.35) videoEl.currentTime = audio.currentTime
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
