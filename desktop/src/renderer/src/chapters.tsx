// Podcast chapters: what the lyrics button shows while an episode plays.
import { useEffect, useRef, useState } from 'react'
import type { JSX } from 'react'
import type { Chapter, Track } from '@shared/types'
import { drift } from './state'
import { playerStore, seek, usePlayer, usePosition } from './player'
import { formatTime } from './util'
import { Spinner } from './ui'

const cache = new Map<string, Chapter[]>()
const pending = new Map<string, Promise<Chapter[]>>()

function load(id: string): Promise<Chapter[]> {
  const known = cache.get(id)
  if (known) return Promise.resolve(known)
  let task = pending.get(id)
  if (!task) {
    task = drift
      .chapters(id)
      .then((list) => {
        cache.set(id, list)
        return list
      })
      .finally(() => pending.delete(id))
    pending.set(id, task)
  }
  return task
}

/** The episode's chapters ([] when it has none). */
export function useChapters(track: Track | undefined): { chapters: Chapter[]; loading: boolean; failed: boolean } {
  const id = track?.podcast ? track.id : undefined
  const [state, setState] = useState<{ id?: string; chapters: Chapter[]; loading: boolean; failed: boolean }>(() => ({
    id,
    chapters: (id && cache.get(id)) || [],
    loading: !!id && !cache.has(id),
    failed: false
  }))
  useEffect(() => {
    if (!id) return setState({ id, chapters: [], loading: false, failed: false })
    const known = cache.get(id)
    if (known) return setState({ id, chapters: known, loading: false, failed: false })
    let live = true
    setState({ id, chapters: [], loading: true, failed: false })
    load(id)
      .then((chapters) => live && setState({ id, chapters, loading: false, failed: false }))
      .catch(() => live && setState({ id, chapters: [], loading: false, failed: true }))
    return () => {
      live = false
    }
  }, [id])
  return state.id === id ? state : { chapters: [], loading: !!id, failed: false }
}

/** Which chapter a position falls in (-1 before the first). */
export function chapterAt(chapters: Chapter[], position: number): number {
  let at = -1
  for (let i = 0; i < chapters.length; i++) if (chapters[i].start <= position + 0.25) at = i
  return at
}

/** The current episode's chapter starts, for the marks on the progress bar. */
export function useChapterMarks(): number[] {
  const p = usePlayer()
  const { chapters } = useChapters(p.current)
  return chapters.length > 1 ? chapters.slice(1).map((c) => c.start) : []
}

/** The current chapter's name (for under the episode title). */
export function CurrentChapter({ className }: { className?: string }): JSX.Element | null {
  const p = usePlayer()
  const position = usePosition()
  const { chapters } = useChapters(p.current)
  const i = chapterAt(chapters, position)
  if (i < 0) return null
  return <span className={className}>{chapters[i].title}</span>
}

/** The list of chapters; click one to jump there. */
export function ChapterList({ track, size = 'small' }: { track: Track | undefined; size?: 'small' | 'large' }): JSX.Element {
  const { chapters, loading, failed } = useChapters(track)
  const position = usePosition()
  const p = usePlayer()
  const playing = !!track && p.current?.id === track.id
  const now = playing ? chapterAt(chapters, position) : -1
  const box = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const row = box.current?.querySelector<HTMLElement>('.chapter.now')
    row?.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
  }, [now])

  if (loading) return <div className="chapters-empty"><Spinner size={20} /></div>
  if (failed) return <div className="chapters-empty">Couldn’t load the chapters.</div>
  if (!chapters.length) return <div className="chapters-empty">This episode has no chapters.</div>
  const duration = p.current?.id === track?.id ? p.duration : track?.duration ?? 0
  return (
    <div className={`chapters ${size}`} ref={box}>
      {chapters.map((c, i) => {
        const end = chapters[i + 1]?.start ?? duration
        const done = i === now && end > c.start ? Math.max(0, Math.min(1, (position - c.start) / (end - c.start))) : 0
        return (
          <button
            key={`${i}-${c.start}`}
            className={`chapter ${i === now ? 'now' : i < now ? 'past' : ''}`}
            onClick={() => {
              if (playing) seek(c.start)
            }}
            disabled={!playing}
            title={playing ? `Jump to ${formatTime(c.start)}` : undefined}
          >
            {c.thumbnail && size === 'large' ? <img className="chapter-thumb" src={c.thumbnail} alt="" /> : null}
            <span className="chapter-time">{formatTime(c.start)}</span>
            <span className="chapter-title">{c.title}</span>
            {i === now && <span className="chapter-bar" style={{ width: `${done * 100}%` }} />}
          </button>
        )
      })}
    </div>
  )
}

/** Mask for the progress bar that leaves a thin gap at each chapter. */
export function chapterMask(marks: number[], duration: number): string | undefined {
  if (!marks.length || duration <= 0) return undefined
  const stops: string[] = []
  for (const m of marks) {
    const pct = (m / duration) * 100
    if (pct <= 0 || pct >= 100) continue
    stops.push(`#000 calc(${pct}% - 1px)`, `transparent calc(${pct}% - 1px)`, `transparent calc(${pct}% + 1px)`, `#000 calc(${pct}% + 1px)`)
  }
  return stops.length ? `linear-gradient(to right, #000 0, ${stops.join(', ')}, #000 100%)` : undefined
}

// Fetch the playing episode's chapters as soon as it starts, so the panel and the bar fill right away.
playerStore.subscribe(() => {
  const p = playerStore.get()
  const t = p.queue[p.index]
  if (t?.podcast && !cache.has(t.id)) void load(t.id).catch(() => undefined)
})
