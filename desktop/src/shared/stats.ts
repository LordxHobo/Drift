// Listening stats: the shared play format (same as the phone's) and the numbers for a period.

/** One song you listened to (30 seconds or more, like Spotify counts it). */
export interface PlayRecord {
  id: string
  title: string
  artist: string
  art?: string | null
  /** When it started (seconds since 1970). */
  at: number
  /** How long you listened. */
  secs: number
}

/** Songs count once you've listened this long. */
export const minimumListen = 30

/** "2026-10" (UTC), the month a play's synced document is for. */
export function playMonth(at: number): string {
  const d = new Date(at * 1000)
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`
}

/** The synced format: songs once, then [id, start, seconds] for each play. */
export function encodePlays(list: PlayRecord[]): string {
  const tracks: Record<string, [string, string, string]> = {}
  for (const p of list) tracks[p.id] ??= [p.title, p.artist, p.art ?? '']
  return JSON.stringify({ tracks, plays: list.map((p) => [p.id, Math.round(p.at), Math.round(p.secs)]) })
}

export function decodePlays(s: string | undefined): PlayRecord[] {
  try {
    const o = JSON.parse(s ?? '')
    const tracks: Record<string, string[]> = o?.tracks ?? {}
    const rows: unknown[] = Array.isArray(o?.plays) ? o.plays : []
    const out: PlayRecord[] = []
    for (const r of rows) {
      if (!Array.isArray(r) || r.length < 3 || typeof r[0] !== 'string') continue
      const info = tracks[r[0]]
      if (!Array.isArray(info) || info.length < 2) continue
      out.push({ id: r[0], title: String(info[0]), artist: String(info[1]), art: info[2] || null, at: Number(r[1]) || 0, secs: Number(r[2]) || 0 })
    }
    return out
  } catch {
    return []
  }
}

export type StatsSpan = 'month' | 'halfYear' | 'year' | 'all'
export const statsSpans: { id: StatsSpan; label: string }[] = [
  { id: 'month', label: '4 weeks' },
  { id: 'halfYear', label: '6 months' },
  { id: 'year', label: 'This year' },
  { id: 'all', label: 'All time' }
]

export interface StatsBucket {
  start: number
  minutes: number
}

export interface StatsSummary {
  plays: PlayRecord[]
  minutes: number
  artistCount: number
  unit: 'day' | 'week' | 'month'
  buckets: StatsBucket[]
  topArtists: { name: string; minutes: number; plays: number; art?: string | null }[]
  topSongs: { play: PlayRecord; plays: number; secs: number }[]
}

/** "Artist feat. Someone" and "A, B & C" count for the first artist. */
export function mainArtist(s: string): string {
  const lower = s.toLowerCase()
  let cut = s.length
  for (const sep of [' feat. ', ' ft. ', ' featuring ', ', ', ' & ', ' x ', ' · ']) {
    const i = lower.indexOf(sep)
    if (i >= 0 && i < cut) cut = i
  }
  return s.slice(0, cut).trim() || s
}

const startOfDay = (d: Date): Date => new Date(d.getFullYear(), d.getMonth(), d.getDate())

function bucketStart(d: Date, unit: StatsSummary['unit']): Date {
  if (unit === 'day') return startOfDay(d)
  if (unit === 'month') return new Date(d.getFullYear(), d.getMonth(), 1)
  const s = startOfDay(d)
  const back = (s.getDay() + 6) % 7 // weeks start on Monday
  return new Date(s.getFullYear(), s.getMonth(), s.getDate() - back)
}

function nextBucket(d: Date, unit: StatsSummary['unit']): Date {
  if (unit === 'day') return new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1)
  if (unit === 'week') return new Date(d.getFullYear(), d.getMonth(), d.getDate() + 7)
  return new Date(d.getFullYear(), d.getMonth() + 1, 1)
}

export function summarize(all: PlayRecord[], span: StatsSpan, now = new Date()): StatsSummary {
  let from: Date
  if (span === 'month') from = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 27)
  else if (span === 'halfYear') from = new Date(now.getFullYear(), now.getMonth() - 6, now.getDate())
  else if (span === 'year') from = new Date(now.getFullYear(), 0, 1)
  else from = new Date(0)
  const seen = new Set<string>()
  const plays = all
    .filter((p) => p.at * 1000 >= from.getTime())
    .filter((p) => {
      // The same play can't count twice (one per song and start time).
      const k = `${p.id}|${Math.round(p.at)}`
      if (seen.has(k)) return false
      seen.add(k)
      return true
    })
  const unit: StatsSummary['unit'] = span === 'month' ? 'day' : span === 'halfYear' ? 'week' : 'month'
  const first = span === 'all' ? new Date(Math.min(...plays.map((p) => p.at * 1000), now.getTime())) : from
  const buckets: StatsBucket[] = []
  for (let d = bucketStart(first, unit); d <= now && buckets.length < 400; d = nextBucket(d, unit)) {
    buckets.push({ start: d.getTime(), minutes: 0 })
  }
  for (const p of plays) {
    const t = p.at * 1000
    for (let i = buckets.length - 1; i >= 0; i--) {
      if (buckets[i].start <= t) {
        buckets[i].minutes += p.secs / 60
        break
      }
    }
  }
  const artists = new Map<string, { name: string; secs: number; plays: number; art?: string | null }>()
  const songs = new Map<string, { play: PlayRecord; plays: number; secs: number }>()
  for (const p of plays) {
    const name = mainArtist(p.artist)
    const a = artists.get(name) ?? { name, secs: 0, plays: 0, art: null }
    a.secs += p.secs
    a.plays += 1
    a.art ??= p.art
    artists.set(name, a)
    const s = songs.get(p.id) ?? { play: p, plays: 0, secs: 0 }
    s.plays += 1
    s.secs += p.secs
    songs.set(p.id, s)
  }
  return {
    plays,
    minutes: Math.round(plays.reduce((n, p) => n + p.secs, 0) / 60),
    artistCount: artists.size,
    unit,
    buckets,
    topArtists: [...artists.values()]
      .sort((a, b) => b.secs - a.secs || a.name.localeCompare(b.name))
      .slice(0, 10)
      .map((a) => ({ name: a.name, minutes: Math.round(a.secs / 60), plays: a.plays, art: a.art })),
    topSongs: [...songs.values()].sort((a, b) => b.plays - a.plays || b.secs - a.secs).slice(0, 10)
  }
}
