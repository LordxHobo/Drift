// Playback: queue, shuffle, repeat, media keys, and picking up where you left off.
import type { StreamInfo, Track } from '@shared/types'
import { drift, readLocal, settingsStore, setSettings, Store, toast, useStore, writeLocal } from './state'
import { artwork } from './util'

export type Repeat = 'off' | 'all' | 'one'

export interface PlayContext {
  kind: 'playlist' | 'album' | 'artist' | 'liked' | 'search' | 'radio' | 'queue' | 'song'
  id?: string
  name: string
}

export interface PlayerState {
  queue: Track[]
  index: number
  /** Songs added with "Play next" / "Add to queue" come before the rest of the list. */
  current?: Track
  playing: boolean
  loading: boolean
  error?: string
  duration: number
  shuffle: boolean
  repeat: Repeat
  volume: number
  muted: boolean
  context?: PlayContext
  info?: StreamInfo
}

const initial: PlayerState = {
  queue: [],
  index: -1,
  playing: false,
  loading: false,
  duration: 0,
  shuffle: false,
  repeat: 'off',
  volume: 0.8,
  muted: false
}

export const playerStore = new Store<PlayerState>(initial)
/** Updated many times a second; kept apart so only the progress bars redraw. */
export const positionStore = new Store(0)

export const usePlayer = (): PlayerState => useStore(playerStore)
export const usePosition = (): number => useStore(positionStore)

const audio = new Audio()
audio.preload = 'auto'
let loadToken = 0
/** Songs in a row that didn't load. */
let failures = 0
/** Order before shuffling, to go back to it. */
let unshuffled: Track[] | undefined
let radioFor: string | undefined

function patch(change: Partial<PlayerState>): void {
  playerStore.update((s) => ({ ...s, ...change }))
}

function shuffled<T>(list: T[]): T[] {
  const a = [...list]
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1))
    ;[a[i], a[j]] = [a[j], a[i]]
  }
  return a
}

// MARK: Starting

export function playList(tracks: Track[], start: number, context?: PlayContext, opts: { shuffle?: boolean } = {}): void {
  if (!tracks.length) return
  const s = playerStore.get()
  const shuffle = opts.shuffle ?? s.shuffle
  let queue = [...tracks]
  let index = Math.max(0, Math.min(start, tracks.length - 1))
  if (shuffle) {
    unshuffled = queue
    const first = opts.shuffle && start <= 0 ? Math.floor(Math.random() * queue.length) : index
    const chosen = queue[first]
    queue = [chosen, ...shuffled(queue.filter((_, i) => i !== first))]
    index = 0
  } else {
    unshuffled = undefined
  }
  radioFor = undefined
  patch({ queue, index, shuffle, context })
  void load(queue[index], true)
}

export function playTrack(t: Track, context?: PlayContext): void {
  playList([t], 0, context ?? { kind: 'song', name: t.title })
}

export function playNext(tracks: Track[]): void {
  const s = playerStore.get()
  if (s.index < 0) return playList(tracks, 0, { kind: 'queue', name: 'Queue' })
  const queue = [...s.queue]
  queue.splice(s.index + 1, 0, ...tracks)
  patch({ queue })
  toast(tracks.length === 1 ? `“${tracks[0].title}” plays next` : `${tracks.length} songs play next`)
}

export function addToQueue(tracks: Track[]): void {
  const s = playerStore.get()
  if (s.index < 0) return playList(tracks, 0, { kind: 'queue', name: 'Queue' })
  patch({ queue: [...s.queue, ...tracks] })
  toast(tracks.length === 1 ? `Added “${tracks[0].title}” to the queue` : `Added ${tracks.length} songs to the queue`)
}

export function removeFromQueue(i: number): void {
  const s = playerStore.get()
  if (i === s.index || !s.queue[i]) return
  const queue = s.queue.filter((_, j) => j !== i)
  patch({ queue, index: i < s.index ? s.index - 1 : s.index })
}

export function jumpTo(i: number): void {
  const s = playerStore.get()
  if (!s.queue[i]) return
  patch({ index: i })
  void load(s.queue[i], true)
}

async function load(t: Track, autoplay: boolean, at = 0): Promise<void> {
  const token = ++loadToken
  audio.pause()
  positionStore.set(at)
  patch({ current: t, loading: true, error: undefined, duration: t.duration ?? 0, info: undefined, playing: autoplay })
  updateMetadata(t)
  try {
    const info = await drift.prepare(t)
    if (token !== loadToken) return
    audio.src = `drift://stream/${info.playId}`
    if (at > 0) audio.currentTime = at
    patch({ info, duration: info.duration || t.duration || 0 })
    if (autoplay) {
      await audio.play()
      void drift.played(t)
    } else {
      patch({ loading: false })
    }
  } catch (e) {
    if (token !== loadToken) return
    if (e instanceof DOMException && e.name === 'AbortError') return
    const message = (e instanceof Error ? e.message : String(e)).replace(/^Error invoking remote method '[^']+': (Error: )?/, '')
    patch({ loading: false, playing: false, error: message })
    if (autoplay) toast(`Couldn’t play “${t.title}”: ${message}`)
    // Move on after a moment, like the phone does, but stop after a few failures in a row
    // (asking YouTube again and again only makes it more suspicious).
    failures++
    if (autoplay && failures >= 3) toast('Stopped after 3 songs in a row didn’t load. Try again in a minute.')
    if (autoplay && failures < 3) {
      window.setTimeout(() => {
        if (token === loadToken && playerStore.get().index < playerStore.get().queue.length - 1) next()
      }, 2500)
    }
  }
}

// MARK: Controls

export function toggle(): void {
  const s = playerStore.get()
  if (!s.current) return
  if (audio.paused) {
    if (!audio.src || s.error) void load(s.current, true, positionStore.get())
    else void audio.play().catch(() => undefined)
  } else {
    audio.pause()
  }
}

export function next(fromEnd = false): void {
  const s = playerStore.get()
  if (!s.current) return
  if (fromEnd && s.repeat === 'one') {
    audio.currentTime = 0
    void audio.play()
    return
  }
  if (s.index < s.queue.length - 1) {
    patch({ index: s.index + 1 })
    void load(s.queue[s.index + 1], true)
  } else if (s.repeat === 'all' && s.queue.length) {
    patch({ index: 0 })
    void load(s.queue[0], true)
  } else {
    void continueWithRadio(fromEnd)
  }
}

/** When the list runs out, keep going with similar songs (YouTube Music's radio). */
async function continueWithRadio(fromEnd: boolean): Promise<void> {
  const s = playerStore.get()
  if (!s.current || radioFor === s.current.id) {
    if (fromEnd) patch({ playing: false })
    return
  }
  radioFor = s.current.id
  try {
    const more = (await drift.radio(s.current.id)).filter((t) => !s.queue.some((q) => q.id === t.id)).slice(0, 25)
    if (!more.length) throw new Error('none')
    const now = playerStore.get()
    patch({ queue: [...now.queue, ...more] })
    patch({ index: now.queue.length })
    void load(more[0], true)
  } catch {
    if (fromEnd) patch({ playing: false })
  }
}

export function previous(): void {
  const s = playerStore.get()
  if (!s.current) return
  if (audio.currentTime > 3 || s.index <= 0) {
    audio.currentTime = 0
    positionStore.set(0)
    return
  }
  patch({ index: s.index - 1 })
  void load(s.queue[s.index - 1], true)
}

export function seek(t: number): void {
  const d = playerStore.get().duration
  const time = Math.max(0, Math.min(t, d || t))
  positionStore.set(time)
  if (audio.src) audio.currentTime = time
}

export function setShuffle(on: boolean): void {
  const s = playerStore.get()
  if (on === s.shuffle) return
  if (!s.current) return patch({ shuffle: on })
  const rest = s.queue.slice(s.index + 1)
  if (on) {
    unshuffled = s.queue
    patch({ shuffle: true, queue: [...s.queue.slice(0, s.index + 1), ...shuffled(rest)] })
  } else {
    const original = unshuffled ?? s.queue
    const at = original.findIndex((t) => t.id === s.current!.id)
    unshuffled = undefined
    patch({ shuffle: false, queue: at >= 0 ? original : s.queue, index: at >= 0 ? at : s.index })
  }
}

export function cycleRepeat(): void {
  const r = playerStore.get().repeat
  patch({ repeat: r === 'off' ? 'all' : r === 'all' ? 'one' : 'off' })
}

export function setVolume(v: number): void {
  const volume = Math.max(0, Math.min(1, v))
  audio.volume = volume * volume
  patch({ volume, muted: false })
  audio.muted = false
  setSettings({ volume })
}

export function toggleMute(): void {
  const muted = !playerStore.get().muted
  audio.muted = muted
  patch({ muted })
}

// MARK: Audio events

audio.addEventListener('playing', () => {
  failures = 0
  patch({ playing: true, loading: false, error: undefined })
})
audio.addEventListener('pause', () => patch({ playing: false }))
audio.addEventListener('waiting', () => patch({ loading: true }))
audio.addEventListener('canplay', () => patch({ loading: false }))
audio.addEventListener('ended', () => next(true))
audio.addEventListener('loadedmetadata', () => {
  if (Number.isFinite(audio.duration) && audio.duration > 0 && !playerStore.get().info?.duration) {
    patch({ duration: audio.duration })
  }
})
audio.addEventListener('timeupdate', () => {
  positionStore.set(audio.currentTime)
  updatePositionState()
})
audio.addEventListener('error', () => {
  const s = playerStore.get()
  if (!s.current || !audio.src) return
  const wasPlaying = s.playing
  const token = loadToken
  patch({ playing: false, loading: false, error: 'The song stopped loading' })
  // Move on, unless something else was started meanwhile.
  failures++
  if (wasPlaying && failures < 3 && s.index < s.queue.length - 1) {
    window.setTimeout(() => token === loadToken && next(), 2500)
  }
})

// MARK: Media keys and the system's now playing

function updateMetadata(t: Track): void {
  if (!('mediaSession' in navigator)) return
  const art = artwork(t, 512)
  navigator.mediaSession.metadata = new MediaMetadata({
    title: t.title,
    artist: t.artist,
    album: t.album ?? '',
    artwork: art ? [{ src: art, sizes: '512x512', type: 'image/jpeg' }] : []
  })
}

function updatePositionState(): void {
  const d = playerStore.get().duration
  if (!('mediaSession' in navigator) || !d) return
  try {
    navigator.mediaSession.setPositionState({ duration: d, position: Math.min(audio.currentTime, d), playbackRate: 1 })
  } catch {
    // ignore invalid states while loading
  }
}

if ('mediaSession' in navigator) {
  const ms = navigator.mediaSession
  ms.setActionHandler('play', () => toggle())
  ms.setActionHandler('pause', () => toggle())
  ms.setActionHandler('previoustrack', () => previous())
  ms.setActionHandler('nexttrack', () => next())
  ms.setActionHandler('seekto', (d) => d.seekTime != null && seek(d.seekTime))
  ms.setActionHandler('seekbackward', () => seek(audio.currentTime - 10))
  ms.setActionHandler('seekforward', () => seek(audio.currentTime + 10))
}

playerStore.subscribe(() => {
  if ('mediaSession' in navigator) navigator.mediaSession.playbackState = playerStore.get().playing ? 'playing' : 'paused'
})

// MARK: Picking up where you left off

interface Saved {
  queue: Track[]
  index: number
  position: number
  shuffle: boolean
  repeat: Repeat
  context?: PlayContext
}

function saveSession(): void {
  const s = playerStore.get()
  if (!s.current) return
  const start = Math.max(0, s.index - 50)
  const saved: Saved = {
    queue: s.queue.slice(start, start + 500),
    index: s.index - start,
    position: positionStore.get(),
    shuffle: s.shuffle,
    repeat: s.repeat,
    context: s.context
  }
  writeLocal('playback', saved)
}

export function restore(): void {
  const volume = settingsStore.get().volume ?? 0.8
  audio.volume = volume * volume
  patch({ volume })
  const saved = readLocal<Saved | null>('playback', null)
  if (!saved?.queue?.length || !saved.queue[saved.index]) return
  patch({ queue: saved.queue, index: saved.index, shuffle: saved.shuffle, repeat: saved.repeat, context: saved.context })
  void load(saved.queue[saved.index], false, saved.position || 0)
}

window.setInterval(saveSession, 5000)
window.addEventListener('pagehide', saveSession)
window.addEventListener('beforeunload', saveSession)
