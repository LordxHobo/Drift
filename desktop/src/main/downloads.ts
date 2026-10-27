// Songs saved on this computer for offline listening. They stay on this computer (not synced).
import { app, shell } from 'electron'
import { join } from 'node:path'
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync } from 'node:fs'
import type { DownloadsState, Track } from '@shared/types'
import * as store from './store'
import { downloadAudio, setLocalLookup } from './stream'

interface Entry {
  track: Track
  file: string
  mime: string
  size: number
  savedAt: number
  /** Downloaded on its own (not only because it's in a kept playlist). */
  manual?: boolean
}

interface Saved {
  entries: Record<string, Entry>
  keep: string[]
  /** Waiting to download (survives closing Drift). */
  queue: { track: Track; manual: boolean }[]
}

const folder = (): string => join(app.getPath('userData'), 'Downloads')
const indexName = 'downloads.json'

let saved: Saved | undefined
const active = new Map<string, { title: string; received: number; total: number }>()
const failed = new Map<string, { title: string; error: string }>()
const cancelled = new Set<string>()
let running = 0
const parallel = 2

// Speed over the last few seconds.
let rateSamples: { at: number; bytes: number }[] = []
let totalReceived = 0

function data(): Saved {
  if (!saved) {
    try {
      saved = { entries: {}, keep: [], queue: [], ...JSON.parse(readFileSync(join(app.getPath('userData'), indexName), 'utf8')) }
    } catch {
      saved = { entries: {}, keep: [], queue: [] }
    }
    // Forget entries whose file was deleted by hand.
    for (const [id, e] of Object.entries(saved!.entries)) {
      if (!existsSync(join(folder(), e.file))) delete saved!.entries[id]
    }
  }
  return saved!
}

let saveTimer: NodeJS.Timeout | undefined
function persist(): void {
  clearTimeout(saveTimer)
  saveTimer = setTimeout(() => store.writeJSON(indexName, data()), 500)
}

let emitTimer: NodeJS.Timeout | undefined
let lastEmit = 0
function changed(now = false): void {
  persist()
  const send = (): void => {
    lastEmit = Date.now()
    store.emit('downloads', getDownloads())
  }
  clearTimeout(emitTimer)
  if (now || Date.now() - lastEmit > 400) send()
  else emitTimer = setTimeout(send, 400)
}

export function getDownloads(): DownloadsState {
  const d = data()
  const now = Date.now()
  rateSamples = rateSamples.filter((s) => now - s.at < 8000)
  const first = rateSamples[0]
  const rate = first && now - first.at > 500 ? ((totalReceived - first.bytes) * 1000) / (now - first.at) : 0
  return {
    done: Object.keys(d.entries),
    queued: d.queue.map((q) => q.track.id).filter((id) => !active.has(id)),
    active: [...active].map(([id, a]) => ({ id, ...a })),
    keep: d.keep,
    bytes: Object.values(d.entries).reduce((n, e) => n + e.size, 0),
    folder: folder(),
    rate,
    failed: [...failed].map(([id, f]) => ({ id, ...f }))
  }
}

export function downloadedTracks(): Track[] {
  return Object.values(data().entries)
    .sort((a, b) => b.savedAt - a.savedAt)
    .map((e) => e.track)
}

function lookup(id: string): { path: string; mime: string; size: number } | undefined {
  const e = data().entries[id]
  if (!e) return undefined
  const path = join(folder(), e.file)
  return existsSync(path) ? { path, mime: e.mime, size: e.size } : undefined
}

// MARK: Queue

function enqueue(tracks: Track[], manual: boolean): void {
  const d = data()
  let added = false
  for (const t of tracks) {
    if (t.podcast) continue
    const entry = d.entries[t.id]
    if (entry) {
      if (manual && !entry.manual) entry.manual = true
      continue
    }
    const queued = d.queue.find((q) => q.track.id === t.id)
    if (queued) {
      if (manual) queued.manual = true
      continue
    }
    failed.delete(t.id)
    d.queue.push({ track: t, manual })
    added = true
  }
  changed(true)
  if (added) pump()
}

function pump(): void {
  const d = data()
  while (running < parallel) {
    const next = d.queue.find((q) => !active.has(q.track.id))
    if (!next) return
    running++
    void run(next.track, next.manual).finally(() => {
      running--
      pump()
    })
  }
}

const extension = (mime: string): string => (mime.includes('webm') ? 'webm' : mime.includes('mp4') ? 'm4a' : 'audio')

async function run(track: Track, manual: boolean): Promise<void> {
  const d = data()
  const id = track.id
  cancelled.delete(id)
  active.set(id, { title: track.title, received: 0, total: 0 })
  changed(true)
  mkdirSync(folder(), { recursive: true })
  const base = join(folder(), id)
  try {
    let last = 0
    const result = await downloadAudio(
      track,
      base,
      (received, total) => {
        totalReceived += received - last
        last = received
        rateSamples.push({ at: Date.now(), bytes: totalReceived })
        active.set(id, { title: track.title, received, total })
        changed()
      },
      () => cancelled.has(id)
    )
    const file = `${id}.${extension(result.mime)}`
    renameSync(base + '.part', join(folder(), file))
    const queued = d.queue.find((q) => q.track.id === id)
    d.entries[id] = { track, file, mime: result.mime, size: result.size, savedAt: Date.now(), manual: queued?.manual ?? manual }
  } catch (e) {
    if (!cancelled.has(id)) {
      const message = (e instanceof Error ? e.message : String(e)).replace(/^Error: /, '')
      failed.set(id, { title: track.title, error: message })
    } else if (existsSync(base + '.part')) {
      rmSync(base + '.part', { force: true })
    }
  } finally {
    active.delete(id)
    d.queue = d.queue.filter((q) => q.track.id !== id)
    changed(true)
  }
}

// MARK: Kept playlists

/** Songs that belong to a kept playlist (or Liked songs). */
function keptTracks(): Track[] {
  const d = data()
  const lib = store.getLibrary()
  const out: Track[] = []
  for (const k of d.keep) {
    if (k === 'liked') out.push(...lib.liked)
    else out.push(...(lib.playlists.find((p) => p.id === k)?.tracks ?? []))
  }
  return out
}

/** New songs in kept playlists download too; deleted kept playlists stop being kept. */
function libraryChanged(): void {
  const d = data()
  const lib = store.getLibrary()
  const keep = d.keep.filter((k) => k === 'liked' || lib.playlists.some((p) => p.id === k))
  if (keep.length !== d.keep.length) d.keep = keep
  const missing = keptTracks().filter((t) => !d.entries[t.id] && !d.queue.some((q) => q.track.id === t.id) && !failed.has(t.id))
  if (missing.length) enqueue(missing, false)
}

// MARK: Actions

export function download(tracks: Track[]): void {
  enqueue(tracks, true)
}

/** Removes downloads, except songs a kept playlist still needs. */
export function removeDownloads(ids: string[], force = false): void {
  const d = data()
  const needed = force ? new Set<string>() : new Set(keptTracks().map((t) => t.id))
  for (const id of ids) {
    if (active.has(id)) cancelled.add(id)
    d.queue = d.queue.filter((q) => q.track.id !== id)
    failed.delete(id)
    const e = d.entries[id]
    if (!e) continue
    if (needed.has(id)) {
      e.manual = false
      continue
    }
    rmSync(join(folder(), e.file), { force: true })
    delete d.entries[id]
  }
  changed(true)
}

export function keepDownloaded(collection: string, keep: boolean): void {
  const d = data()
  const tracksOf = (k: string): Track[] => {
    const lib = store.getLibrary()
    return k === 'liked' ? lib.liked : lib.playlists.find((p) => p.id === k)?.tracks ?? []
  }
  if (keep) {
    if (!d.keep.includes(collection)) d.keep.push(collection)
    enqueue(tracksOf(collection), false)
    return
  }
  d.keep = d.keep.filter((k) => k !== collection)
  // Remove the ones only this playlist needed (not downloaded on their own, not in another kept one).
  const stillNeeded = new Set(keptTracks().map((t) => t.id))
  const drop = tracksOf(collection)
    .map((t) => t.id)
    .filter((id) => !stillNeeded.has(id) && !d.entries[id]?.manual)
  removeDownloads(drop, true)
}

export function removeAllDownloads(): void {
  const d = data()
  for (const id of active.keys()) cancelled.add(id)
  d.queue = []
  d.keep = []
  failed.clear()
  for (const e of Object.values(d.entries)) rmSync(join(folder(), e.file), { force: true })
  d.entries = {}
  changed(true)
}

export function retryFailed(): void {
  const lib = store.getLibrary()
  const all = [...lib.liked, ...lib.playlists.flatMap((p) => p.tracks)]
  const tracks = [...failed.keys()].map((id) => all.find((t) => t.id === id)).filter((t): t is Track => !!t)
  failed.clear()
  enqueue(tracks, true)
}

export function openFolder(): void {
  mkdirSync(folder(), { recursive: true })
  void shell.openPath(folder())
}

export function startDownloads(): void {
  setLocalLookup(lookup)
  store.onLibraryChange(libraryChanged)
  // Carry on with whatever was waiting when Drift closed.
  setTimeout(() => {
    libraryChanged()
    pump()
  }, 3000)
}

export function flushDownloads(): void {
  if (saved) store.writeJSON(indexName, saved)
}
