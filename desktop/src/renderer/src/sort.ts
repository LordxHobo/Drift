// Sorting a playlist or Liked songs by title, artist, album or date added (like Spotify's column headers).
import { useState } from 'react'
import type { Track } from '@shared/types'
import { appleEpoch } from '@shared/types'
import { readLocal, writeLocal } from './state'

export type SortKey = 'title' | 'artist' | 'album' | 'added'
export type Sort = { key: SortKey; dir: 'asc' | 'desc' } | null
/** What a header click asks for: one column, or 'name' (the Title/Artist button). */
export type SortClick = SortKey | 'name'

/** The Title/Artist button's steps: Title A→Z, Title Z→A, Artist A→Z, Artist Z→A, your order. */
const nameSteps: Sort[] = [
  { key: 'title', dir: 'asc' },
  { key: 'title', dir: 'desc' },
  { key: 'artist', dir: 'asc' },
  { key: 'artist', dir: 'desc' },
  null
]

/**
 * The sort for one list (remembered per list). Clicking a header: A→Z, then Z→A, then your own
 * order again. Date added starts with the newest.
 */
export function useSort(listId: string): [Sort, (key: SortClick) => void] {
  const storageKey = `sort.${listId}`
  const [sort, setSort] = useState<Sort>(() => readLocal<Sort>(storageKey, null))
  const cycle = (key: SortClick): void => {
    let next: Sort
    if (key === 'name') {
      const at = nameSteps.findIndex((s) => s?.key === sort?.key && s?.dir === sort?.dir)
      // From another column (or your order), start at Title A→Z.
      next = sort && (sort.key === 'title' || sort.key === 'artist') && at >= 0 ? nameSteps[at + 1] : nameSteps[0]
    } else {
      const first = key === 'added' ? 'desc' : 'asc'
      next = sort?.key !== key ? { key, dir: first } : sort.dir === first ? { key, dir: first === 'asc' ? 'desc' : 'asc' } : null
    }
    setSort(next)
    writeLocal(storageKey, next)
  }
  return [sort, cycle]
}

const collator = new Intl.Collator(undefined, { sensitivity: 'base', numeric: true })

/** Leading "The " and symbols don't count when sorting by name (like Spotify). */
const sortName = (s: string | null | undefined): string => (s ?? '').replace(/^(the|a)\s+/i, '').replace(/^[^\p{L}\p{N}]+/u, '')

/**
 * Sorts a (possibly filtered) list. `indexes` are the songs' places in the full list. Songs added
 * before dates were kept count as older than any dated song, in list order (`newestFirst` for Liked
 * songs, where the newest is at the top).
 */
export function sortTracks(
  list: Track[],
  indexes: number[] | undefined,
  sort: Sort,
  newestFirst = false
): { list: Track[]; indexes?: number[] } {
  if (!sort) return { list, indexes }
  const place = (i: number): number => indexes?.[i] ?? i
  const order = list.map((_, i) => i)
  const sign = sort.dir === 'asc' ? 1 : -1
  const undated = (i: number): number => (newestFirst ? -place(i) : place(i))
  order.sort((a, b) => {
    const ta = list[a]
    const tb = list[b]
    let c = 0
    if (sort.key === 'added') {
      const da = ta.added
      const db = tb.added
      if (da != null && db != null) c = da - db
      else if (da != null) c = 1
      else if (db != null) c = -1
      else c = undated(a) - undated(b)
      return sign * c
    }
    const field = (t: Track): string => sortName(sort.key === 'title' ? t.title : sort.key === 'artist' ? t.artist : t.album)
    c = collator.compare(field(ta), field(tb))
    // Same artist or album: keep the songs together in a sensible order.
    if (c === 0 && sort.key !== 'title') c = collator.compare(sortName(ta.album), sortName(tb.album)) || collator.compare(sortName(ta.title), sortName(tb.title))
    return c !== 0 ? sign * c : place(a) - place(b)
  })
  return { list: order.map((i) => list[i]), indexes: order.map(place) }
}

/** "3 days ago" for the last few weeks, then the date ("12 Mar 2026"). */
export function addedText(added: number | null | undefined): string {
  if (added == null) return ''
  const ms = (added + appleEpoch) * 1000
  const days = (Date.now() - ms) / 86_400_000
  if (days < 1 / 24) return 'Just now'
  if (days < 1) return `${Math.max(1, Math.round(days * 24))} hours ago`.replace(/^1 hours/, '1 hour')
  if (days < 28) return `${Math.round(days)} day${Math.round(days) === 1 ? '' : 's'} ago`
  return new Date(ms).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' })
}
