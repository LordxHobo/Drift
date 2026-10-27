// Synced lyrics from LRCLIB (the same source the phone uses first).
import { app, net } from 'electron'
import type { LyricLine, Lyrics, Track } from '@shared/types'
import { mainArtist } from './ytmusic'

const cache = new Map<string, Lyrics>()

interface Entry {
  syncedLyrics?: string | null
  plainLyrics?: string | null
  duration?: number | null
}

async function fetchJSON<T>(url: URL): Promise<T | undefined> {
  try {
    const res = await net.fetch(url.toString(), {
      headers: { 'User-Agent': `Drift Desktop/${app.getVersion()} (personal music player)` }
    })
    if (res.status !== 200) return undefined
    return (await res.json()) as T
  } catch {
    return undefined
  }
}

export function cleanTitle(t: string, artist: string): string {
  let s = t.replace(/\s*[([][^)\]]*(official|video|audio|lyric|visuali[sz]er|\bhd\b|4k|\bmv\b|remaster)[^)\]]*[)\]]/gi, '')
  const main = mainArtist(artist).toLowerCase()
  const dash = s.indexOf(' - ')
  if (main && s.toLowerCase().startsWith(main) && dash >= 0) s = s.slice(dash + 3)
  s = s.replace(/\s+-\s+.*(remaster|version|edit|mix).*$/i, '')
  return s.trim()
}

export function parseLRC(lrc: string): LyricLine[] {
  const lines: LyricLine[] = []
  for (const raw of lrc.split(/\r?\n/)) {
    const tags = [...raw.matchAll(/\[(\d+):(\d+(?:\.\d+)?)\]/g)]
    if (!tags.length) continue
    const last = tags[tags.length - 1]
    const text = raw.slice((last.index ?? 0) + last[0].length).trim()
    for (const t of tags) lines.push({ time: Number(t[1]) * 60 + Number(t[2]), text })
  }
  return lines.sort((a, b) => a.time - b.time)
}

export async function lyrics(track: Track): Promise<Lyrics> {
  const cached = cache.get(track.id)
  if (cached) return cached
  const title = cleanTitle(track.title, track.artist)
  const artist = mainArtist(track.artist)
  const duration = track.duration ?? undefined

  let result: Lyrics = { kind: 'none' }
  const get = new URL('https://lrclib.net/api/get')
  get.searchParams.set('track_name', title)
  get.searchParams.set('artist_name', artist)
  if (track.album) get.searchParams.set('album_name', track.album)
  if (duration) get.searchParams.set('duration', String(Math.round(duration)))
  const exact = await fetchJSON<Entry>(get)
  let entry: Entry | undefined = exact?.syncedLyrics || exact?.plainLyrics ? exact : undefined

  if (!entry) {
    const search = new URL('https://lrclib.net/api/search')
    search.searchParams.set('track_name', title)
    search.searchParams.set('artist_name', artist)
    const list = (await fetchJSON<Entry[]>(search)) ?? []
    const close = (e: Entry): boolean => !duration || !e.duration || Math.abs(e.duration - duration) <= 5
    entry = list.find((e) => e.syncedLyrics && close(e)) ?? list.find((e) => e.plainLyrics && close(e))
  }
  if (entry?.syncedLyrics) {
    const lines = parseLRC(entry.syncedLyrics)
    if (lines.length) result = { kind: 'synced', lines, source: 'LRCLIB' }
  }
  if (result.kind === 'none' && entry?.plainLyrics) result = { kind: 'plain', text: entry.plainLyrics, source: 'LRCLIB' }
  if (result.kind !== 'none') cache.set(track.id, result)
  return result
}
