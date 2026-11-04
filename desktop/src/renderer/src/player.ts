// Playback: queue, shuffle, repeat, media keys, and picking up where you left off.
import type { SkipSegment, StreamInfo, Track } from '@shared/types'
import type { RemoteCommand } from '@shared/remote'
import { drift, podcastsStore, readLocal, settingsStore, setSettings, Store, toast, useStore, writeLocal } from './state'
import { artwork, formatTime } from './util'
import { connectAudio, peakLevel } from './audioGraph'

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
// Drift's own links allow the sound to go through the equalizer (see audioGraph.ts).
audio.crossOrigin = 'anonymous'
/** The sound (the episode video follows it). */
export const audioElement = audio
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

/** For Listen Together: how many times you've jumped in a song, and when a song last ended by itself. */
export const jamHooks = { seeks: 0, naturalEndAt: 0 }

/** The exact position of the sound right now. */
export function currentTime(): number {
  return audio.src ? audio.currentTime : positionStore.get()
}

/**
 * Listen Together: play what the session plays (the song, what comes after it, where, and whether).
 * Only changes what differs, so the music keeps going smoothly.
 */
export function jamPlay(track: Track, upcoming: Track[], position: number, playing: boolean): void {
  const s = playerStore.get()
  if (s.current?.id !== track.id) {
    unshuffled = undefined
    radioFor = undefined
    patch({ queue: [track, ...upcoming], index: 0, shuffle: false, context: { kind: 'queue', name: 'Listening together' } })
    void load(track, playing, position).then(() => {
      if (!playing) audio.pause()
    })
    return
  }
  const ids = s.queue.slice(s.index + 1).map((t) => t.id).join(',')
  if (ids !== upcoming.map((t) => t.id).join(',')) patch({ queue: [...s.queue.slice(0, s.index + 1), ...upcoming] })
  // Paused, or just paused/started: the exact spot. While playing on: only bigger gaps (no stutter).
  const tolerance = !playing || playing === audio.paused ? 0.3 : 1.5
  if (playing && audio.paused) void audio.play().catch(() => undefined)
  if (!playing && !audio.paused) audio.pause()
  if (Math.abs(currentTime() - position) > tolerance) {
    positionStore.set(position)
    if (audio.src) audio.currentTime = position
  }
}

// MARK: Control other device

/** While you control another device (remote.ts), what you do here goes there instead. True when sent. */
export const remoteHook: { send?: (c: Omit<RemoteCommand, 'id' | 'from'>) => boolean } = {}

/** Another device handed its music to this computer: play this song (and what comes after it) from here. */
export function transferIn(track: Track, upcoming: Track[], position: number, playing: boolean, source: string): void {
  unshuffled = undefined
  radioFor = undefined
  patch({ queue: [track, ...upcoming], index: 0, shuffle: false, context: { kind: 'queue', name: source || 'Another device' } })
  void load(track, playing, position)
}

// MARK: Starting

export function playList(tracks: Track[], start: number, context?: PlayContext, opts: { shuffle?: boolean } = {}): void {
  if (!tracks.length) return
  if (remoteHook.send) {
    const list = opts.shuffle ? shuffled(tracks) : tracks
    const at = opts.shuffle ? 0 : Math.max(0, Math.min(start, tracks.length - 1))
    if (remoteHook.send({ type: 'play', tracks: list.slice(0, 200), start: Math.min(at, 199), source: context?.name })) return
  }
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
  if (tracks.length === 1 && remoteHook.send?.({ type: 'playNext', track: tracks[0] })) return void toast(`“${tracks[0].title}” plays next`)
  const s = playerStore.get()
  if (s.index < 0) return playList(tracks, 0, { kind: 'queue', name: 'Queue' })
  const queue = [...s.queue]
  queue.splice(s.index + 1, 0, ...tracks)
  patch({ queue })
  toast(tracks.length === 1 ? `“${tracks[0].title}” plays next` : `${tracks.length} songs play next`)
}

export function addToQueue(tracks: Track[]): void {
  if (tracks.length === 1 && remoteHook.send?.({ type: 'addToQueue', track: tracks[0] })) return void toast(`Added “${tracks[0].title}” to the queue`)
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

/** Where to start an episode: a few seconds before where it was left. */
function resumePosition(t: Track): number {
  const p = podcastsStore.get().progress[t.id]
  if (!p || p.finished || p.position < 30) return 0
  return Math.max(p.position - 3, 0)
}

// MARK: Skipping (SponsorBlock)

let segments: SkipSegment[] = []
const skipped = new Set<number>()

function segmentLabel(s: SkipSegment, duration: number): string {
  switch (s.category) {
    case 'sponsor':
      return 'sponsor'
    case 'selfpromo':
      return 'self-promotion'
    case 'interaction':
      return 'subscribe reminder'
    default:
      return s.start < 1 ? 'non-music intro' : duration && s.end > duration - 2 ? 'non-music outro' : 'non-music part'
  }
}

function loadSegments(t: Track, playId: string, token: number): void {
  const st = settingsStore.get()
  segments = []
  skipped.clear()
  if (t.podcast ? !st.skipSponsors : !st.skipNonMusic) return
  void drift.skipSegments(playId, !!t.podcast).then((list) => {
    if (token === loadToken) segments = list
  })
}

function checkSkip(time: number): void {
  if (!segments.length) return
  const seg = segments.find((s) => time >= s.start && time < s.end - 0.5 && !skipped.has(s.start))
  if (!seg) return
  skipped.add(seg.start)
  const d = playerStore.get().duration
  // A non-music outro at the very end: just go to the next song.
  if (d && seg.end >= d - 1) {
    toast(`Skipped ${segmentLabel(seg, d)}`)
    return next(true)
  }
  audio.currentTime = seg.end
  toast(`Skipped ${segmentLabel(seg, d)} · ${formatSeconds(seg.end - seg.start)}`)
}

const formatSeconds = (s: number): string => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`

export const speeds = [0.75, 1, 1.25, 1.5, 1.75, 2]

/** Episode speed (songs always play at normal speed). */
export function setSpeed(speed: number): void {
  setSettings({ podcastSpeed: speed })
  if (playerStore.get().current?.podcast) audio.playbackRate = speed
}

// MARK: Loading

async function load(t: Track, autoplay: boolean, at = 0): Promise<void> {
  const token = ++loadToken
  newListen()
  silence.since = 0
  silence.heard = false
  saveEpisodeProgress()
  if (t.podcast && at === 0) at = resumePosition(t)
  audio.pause()
  positionStore.set(at)
  patch({ current: t, loading: true, error: undefined, duration: t.duration ?? 0, info: undefined, playing: autoplay })
  updateMetadata(t)
  try {
    const info = await drift.prepare(t)
    if (token !== loadToken) return
    audio.src = `drift://stream/${info.playId}`
    audio.playbackRate = t.podcast ? settingsStore.get().podcastSpeed || 1 : 1
    if (at > 0) audio.currentTime = at
    loadSegments(t, info.playId, token)
    patch({ info, duration: info.duration || t.duration || 0 })
    if (autoplay) {
      await audio.play()
      void drift.played(t)
      // Get the next few songs ready (which version to play, and the next one's audio).
      const s = playerStore.get()
      const upcoming = s.queue.slice(s.index + 1, s.index + 4).filter((x) => !x.podcast)
      if (upcoming.length) void drift.prefetch(upcoming).catch(() => undefined)
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
  if (remoteHook.send?.({ type: 'toggle' })) return
  const s = playerStore.get()
  if (!s.current) return
  if (audio.paused) {
    if (!audio.src || s.error) void load(s.current, true, positionStore.get())
    else void audio.play().catch(() => undefined)
  } else {
    audio.pause()
  }
}

/** Pause / play here (not sent to another device). */
export function pauseHere(): void {
  audio.pause()
}

export function resumeHere(): void {
  const s = playerStore.get()
  if (!s.current || !audio.paused) return
  if (!audio.src || s.error) void load(s.current, true, positionStore.get())
  else void audio.play().catch(() => undefined)
}

export function setRepeat(repeat: Repeat): void {
  patch({ repeat })
}

export function next(fromEnd = false): void {
  if (!fromEnd && remoteHook.send?.({ type: 'next' })) return
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
  if (remoteHook.send?.({ type: 'previous' })) return
  const s = playerStore.get()
  if (!s.current) return
  if (audio.currentTime > 3 || s.index <= 0) {
    jamHooks.seeks++
    audio.currentTime = 0
    positionStore.set(0)
    return
  }
  patch({ index: s.index - 1 })
  void load(s.queue[s.index - 1], true)
}

export function seek(t: number): void {
  jamHooks.seeks++
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
  connectAudio(audio)
  failures = 0
  patch({ playing: true, loading: false, error: undefined })
})
audio.addEventListener('pause', () => {
  patch({ playing: false })
  const t = playerStore.get().current
  if (t && !t.podcast && listen.id === t.id && listen.secs >= 30 && listen.secs > listen.reported) {
    listen.reported = listen.secs
    void drift.listened(t, listen.key, listen.secs).catch(() => undefined)
  }
  saveEpisodeProgress()
})
audio.addEventListener('waiting', () => patch({ loading: true }))
audio.addEventListener('canplay', () => patch({ loading: false }))
audio.addEventListener('ended', () => {
  jamHooks.naturalEndAt = Date.now()
  const t = playerStore.get().current
  if (t?.podcast) void drift.markPlayed(t, true)
  next(true)
})
audio.addEventListener('loadedmetadata', () => {
  if (Number.isFinite(audio.duration) && audio.duration > 0 && !playerStore.get().info?.duration) {
    patch({ duration: audio.duration })
  }
})
let lastProgressSave = 0

/** Remembers where an episode is (every few seconds, on pause and when switching). */
function saveEpisodeProgress(force = true): void {
  const s = playerStore.get()
  const t = s.current
  if (!t?.podcast || !audio.src) return
  const d = s.duration || audio.duration
  if (!Number.isFinite(d) || d <= 0 || audio.currentTime < 1) return
  if (!force && Date.now() - lastProgressSave < 5000) return
  lastProgressSave = Date.now()
  void drift.episodeProgress(t, audio.currentTime, d)
}

// Listening stats: how long the current song has really been listened to (paused, buffering and
// jumps don't count). Reported every 10 s once it's been 30 s; one listen per time a song starts.
const listen = { key: '', id: '', secs: 0, last: 0, reported: 0 }

function trackListening(): void {
  const t = playerStore.get().current
  if (!t || t.podcast || audio.paused) {
    listen.last = 0
    return
  }
  if (listen.id !== t.id) {
    listen.key = `${Date.now()}-${t.id}`
    listen.id = t.id
    listen.secs = 0
    listen.reported = 0
  }
  const now = performance.now()
  if (listen.last && now - listen.last < 2000) listen.secs += (now - listen.last) / 1000
  listen.last = now
  if (listen.secs >= 30 && listen.secs - listen.reported >= 10) {
    listen.reported = listen.secs
    void drift.listened(t, listen.key, listen.secs).catch(() => undefined)
  }
}

/** A new song (or the same one again) is starting: it's a new listen. */
function newListen(): void {
  const t = playerStore.get().current
  if (t && !t.podcast && listen.secs >= 30 && listen.secs > listen.reported) void drift.listened(t, listen.key, listen.secs).catch(() => undefined)
  listen.id = ''
  listen.last = 0
}

// Songs that end in minutes of dead air (or a hidden track after it): 15 s of dead air after the
// first 40% of a song, with more left, ends it. Strict on purpose, so a quiet break, a fade or a soft
// outro is never taken for the end. Only once the song has been heard (so a sound Drift
// can't measure never counts as silence).
const silence = { since: 0, heard: false }

function checkSilence(): void {
  const s = playerStore.get()
  const t = s.current
  const d = s.duration || audio.duration
  const now = audio.currentTime
  // Measured after the volume is applied, so turned back to the song's own level.
  const volume = audio.muted ? 0 : audio.volume
  const raw = peakLevel()
  const peak = raw === null || volume < 0.02 ? null : raw / volume
  if (peak === null || !t || t.podcast || audio.paused || s.loading) {
    silence.since = 0
    return
  }
  if (peak > 0.01) silence.heard = true
  if (!silence.heard || !Number.isFinite(d) || d <= 60 || now < d * 0.4 || d - now <= 8 || peak >= 0.001) {
    silence.since = 0
    return
  }
  if (!silence.since) silence.since = performance.now()
  else if (performance.now() - silence.since >= 15000) {
    silence.since = 0
    toast(`Skipped ${formatTime(d - now)} of silence`)
    next(true)
  }
}

audio.addEventListener('timeupdate', () => {
  trackListening()
  checkSilence()
  positionStore.set(audio.currentTime)
  updatePositionState()
  checkSkip(audio.currentTime)
  saveEpisodeProgress(false)
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
