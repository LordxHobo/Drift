// Keeps the shows you follow and where you are in each episode the same on all your devices, in one
// document (users/{uid}/library/podcasts), the same as the phones':
// - shows: the followed shows (JSON), with showsAt, when they last changed (the newest list wins);
// - progress: episode id → where it was left (JSON), each episode's newest place winning.
import type { EpisodeProgress, PodcastChannel, Track } from '@shared/types'
import * as account from './account'
import { FV } from './firebase'
import * as podcasts from './podcasts'

/** One episode's place, as stored: the episode, position and length (s), when (ms), finished. */
interface Entry {
  t: Track
  p: number
  d: number
  u: number
  f?: boolean
}

/** At most this many episodes' places are kept on the server (the most recent). */
const keep = 300

let pending: NodeJS.Timeout | undefined
let running: Promise<void> | undefined

/** Something changed here. A follow or a jump: sent in a moment. A place while playing: at most once a minute. */
export function podcastsChanged(soon: boolean): void {
  if (!account.linked()) return
  if (!soon && pending) return
  clearTimeout(pending)
  pending = setTimeout(() => {
    pending = undefined
    void syncPodcasts()
  }, soon ? 2000 : 60_000)
}

export function syncPodcasts(): Promise<void> {
  if (!running) running = run().finally(() => (running = undefined))
  return running
}

function parse<T>(s: string | undefined): T | undefined {
  if (!s) return undefined
  try {
    return JSON.parse(s) as T
  } catch {
    return undefined
  }
}

async function run(): Promise<void> {
  const l = account.linked()
  if (!l) return
  try {
    const path = `users/${l.uid}/library/podcasts`
    const f = (await l.db.get(path))?.fields
    const remoteShows = parse<PodcastChannel[]>(FV.string(f, 'shows'))
    const remoteShowsAt = FV.int(f, 'showsAt') ?? 0
    const remote = parse<Record<string, Entry>>(FV.string(f, 'progress')) ?? {}

    const state = podcasts.syncState()
    const now = Date.now()
    const local = state.subscriptions
    let shows = local
    let showsAt = state.showsChanged
    let sendShows = false
    if (!Array.isArray(remoteShows)) {
      sendShows = local.length > 0 || showsAt > 0
      if (!showsAt) showsAt = now
    } else if (state.syncedUid !== l.uid) {
      // First sync on this computer: both (the profile's first, then any followed only here).
      const ids = new Set(remoteShows.map((c) => c.id))
      const extra = local.filter((c) => !ids.has(c.id))
      shows = [...remoteShows, ...extra]
      sendShows = extra.length > 0
      showsAt = sendShows ? now : remoteShowsAt
    } else if (remoteShowsAt > showsAt) {
      shows = remoteShows
      showsAt = remoteShowsAt
    } else if (showsAt > remoteShowsAt) {
      sendShows = true
    }
    if (shows !== local || showsAt !== state.showsChanged) podcasts.adoptShows(shows, showsAt)

    // Each episode: the newest place wins.
    const mine = state.progress
    const newer: Record<string, EpisodeProgress> = {}
    for (const [id, e] of Object.entries(remote)) {
      if (!e?.t?.id || typeof e.u !== 'number') continue
      if ((mine[id]?.updated ?? -1) < e.u) newer[id] = { track: e.t, position: e.p ?? 0, duration: e.d ?? 0, updated: e.u, finished: e.f === true }
    }
    const all: Record<string, Entry> = { ...remote }
    for (const [id, p] of Object.entries(mine)) {
      if (!all[id] || all[id].u < p.updated) all[id] = { t: p.track, p: p.position, d: p.duration, u: p.updated, f: p.finished }
    }
    podcasts.adoptProgress(newer)
    const kept = Object.fromEntries(Object.entries(all).sort((a, b) => b[1].u - a[1].u).slice(0, keep))
    const stamps = (m: Record<string, Entry>): string =>
      Object.entries(m).map(([id, e]) => `${id}:${e.u}`).sort().join(',')
    const sendProgress = stamps(kept) !== stamps(remote)
    podcasts.markSynced(l.uid)

    if (!sendShows && !sendProgress) return
    await l.db.patch(path, {
      shows: FV.s(JSON.stringify(shows)),
      showsAt: FV.i(showsAt),
      progress: FV.s(JSON.stringify(kept)),
      updatedAt: FV.i(Date.now()),
      deleted: FV.b(false)
    })
  } catch {
    // offline: next time
  }
}

/** Every 2 minutes while Drift runs, and when it's brought back to the front. */
export function startPodcastSync(): void {
  setTimeout(() => void syncPodcasts(), 10_000)
  setInterval(() => void syncPodcasts(), 120_000)
}
