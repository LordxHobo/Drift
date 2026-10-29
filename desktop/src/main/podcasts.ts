// Followed channels, their latest episodes and where each episode was left off (on this computer).
import { app, net } from 'electron'
import type { EpisodeProgress, PodcastChannel, PodcastsState, SkipSegment, Track } from '@shared/types'
import { emit, writeJSON } from './store'
import { channelEpisodes as youtubeEpisodes } from './youtube'
import { feedEpisodes, searchShows as directory, showFromLink } from './feeds'
import { join } from 'node:path'
import { readFileSync } from 'node:fs'

interface Saved {
  subscriptions: PodcastChannel[]
  progress: Record<string, EpisodeProgress>
  feeds: Record<string, Track[]>
  feedsUpdated?: number
}

const file = 'podcasts.json'
let saved: Saved | undefined
let refreshing = false
let saveTimer: NodeJS.Timeout | undefined

function data(): Saved {
  if (!saved) {
    try {
      saved = { subscriptions: [], progress: {}, feeds: {}, ...JSON.parse(readFileSync(join(app.getPath('userData'), file), 'utf8')) }
    } catch {
      saved = { subscriptions: [], progress: {}, feeds: {} }
    }
  }
  return saved!
}

function changed(soon = false): void {
  clearTimeout(saveTimer)
  saveTimer = setTimeout(() => writeJSON(file, data()), soon ? 300 : 5000)
  emit('podcasts', getPodcasts())
}

export function flushPodcasts(): void {
  if (saved) writeJSON(file, saved)
}

export function getPodcasts(): PodcastsState {
  const d = data()
  return { subscriptions: d.subscriptions, progress: d.progress, feeds: d.feeds, refreshing }
}

export function followChannel(c: PodcastChannel, follow: boolean): void {
  const d = data()
  d.subscriptions = d.subscriptions.filter((s) => s.id !== c.id)
  if (follow) {
    d.subscriptions.push({ id: c.id, name: c.name, avatarURL: c.avatarURL ?? null, subtitle: c.subtitle ?? null, feedURL: c.feedURL ?? null })
    void loadChannel(c)
  }
  changed(true)
}

/** A show's episodes: from its feed, or the YouTube channel's uploads. */
const channelEpisodes = (c: PodcastChannel): Promise<Track[]> => (c.feedURL ? feedEpisodes(c) : youtubeEpisodes(c))

/** Shows from Apple's podcast directory, or the show behind a pasted feed link (its episodes kept ready). */
export async function searchShows(q: string): Promise<PodcastChannel[]> {
  const text = q.trim()
  if (/^https?:\/\//i.test(text)) {
    if (/youtu\.?be/i.test(text)) return []
    const found = await showFromLink(text).catch(() => undefined)
    if (!found) throw new Error("Couldn’t find a podcast at that link. Paste the show’s feed link, its Apple Podcasts page or its SoundCloud profile.")
    linkShows.set(found.channel.id, found.episodes)
    return [found.channel]
  }
  return directory(text)
}

/** Episodes of shows opened from a pasted link (so their page shows them straight away). */
const linkShows = new Map<string, Track[]>()

async function loadChannel(c: PodcastChannel): Promise<void> {
  const eps = await channelEpisodes(c).catch(() => [])
  if (eps.length) {
    data().feeds[c.id] = eps
    changed(true)
  }
}

export async function episodes(c: PodcastChannel): Promise<Track[]> {
  const ready = linkShows.get(c.id)
  linkShows.delete(c.id)
  const eps = ready ?? (await channelEpisodes(c))
  if (eps.length && data().subscriptions.some((s) => s.id === c.id)) {
    data().feeds[c.id] = eps
    changed(true)
  }
  return eps
}

export async function refresh(force: boolean): Promise<void> {
  const d = data()
  if (refreshing || !d.subscriptions.length) return
  if (!force && d.feedsUpdated && Date.now() - d.feedsUpdated < 30 * 60_000) return
  refreshing = true
  changed()
  try {
    const results = await Promise.all(d.subscriptions.map((c) => channelEpisodes(c).then((e) => [c.id, e] as const).catch(() => [c.id, [] as Track[]] as const)))
    for (const [id, eps] of results) if (eps.length) d.feeds[id] = eps
    d.feedsUpdated = Date.now()
  } finally {
    refreshing = false
    changed(true)
  }
}

export function updateProgress(t: Track, position: number, duration: number): void {
  if (!Number.isFinite(position) || !Number.isFinite(duration) || duration <= 0) return
  data().progress[t.id] = { track: t, position, duration, updated: Date.now(), finished: duration - position < 30 }
  // Keep the list from growing forever.
  const entries = Object.entries(data().progress)
  if (entries.length > 500) {
    entries.sort((a, b) => a[1].updated - b[1].updated)
    for (const [id] of entries.slice(0, entries.length - 500)) delete data().progress[id]
  }
  changed()
}

export function markPlayed(t: Track, played: boolean): void {
  const d = data()
  if (played) {
    const dur = d.progress[t.id]?.duration ?? t.duration ?? 0
    d.progress[t.id] = { track: t, position: dur, duration: dur, updated: Date.now(), finished: true }
  } else {
    delete d.progress[t.id]
  }
  changed(true)
}

export function startPodcasts(): void {
  setTimeout(() => void refresh(false), 15_000)
  setInterval(() => void refresh(false), 30 * 60_000)
}

// MARK: SponsorBlock

const musicCategories = ['music_offtopic']
const podcastCategories = ['sponsor', 'selfpromo', 'interaction']

export async function skipSegments(id: string, podcast: boolean): Promise<SkipSegment[]> {
  const url = new URL('https://sponsor.ajay.app/api/skipSegments')
  url.searchParams.set('videoID', id)
  for (const c of podcast ? podcastCategories : musicCategories) url.searchParams.append('category', c)
  try {
    const res = await net.fetch(url.toString())
    if (res.status !== 200) return []
    const list = (await res.json()) as { segment: [number, number]; category?: string }[]
    return list
      .filter((s) => s.segment?.length === 2 && s.segment[1] - s.segment[0] >= 1)
      .map((s) => ({ start: s.segment[0], end: s.segment[1], category: s.category ?? '' }))
      .sort((a, b) => a.start - b.start)
  } catch {
    return []
  }
}
