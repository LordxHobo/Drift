import { useEffect, useRef, useState } from 'react'
import type { JSX } from 'react'
import type { Lyrics, Track } from '@shared/types'
import { drift } from './state'
import { seek, usePosition } from './player'
import { Spinner } from './ui'

const cache = new Map<string, Lyrics>()

export function useLyrics(track: Track | undefined): { lyrics?: Lyrics; loading: boolean } {
  const [state, setState] = useState<{ id?: string; lyrics?: Lyrics; loading: boolean }>({ loading: false })
  useEffect(() => {
    if (!track) return setState({ loading: false })
    const known = cache.get(track.id)
    if (known) return setState({ id: track.id, lyrics: known, loading: false })
    let alive = true
    setState({ id: track.id, loading: true })
    drift
      .lyrics(track)
      .catch((): Lyrics => ({ kind: 'none' }))
      .then((l) => {
        cache.set(track.id, l)
        if (alive) setState({ id: track.id, lyrics: l, loading: false })
      })
    return () => {
      alive = false
    }
  }, [track?.id])
  return state.id === track?.id ? state : { loading: !!track }
}

function activeLine(lyrics: Lyrics | undefined, t: number): number {
  if (lyrics?.kind !== 'synced') return -1
  let lo = 0
  let hi = lyrics.lines.length - 1
  let found = -1
  while (lo <= hi) {
    const mid = (lo + hi) >> 1
    if (lyrics.lines[mid].time <= t + 0.25) {
      found = mid
      lo = mid + 1
    } else hi = mid - 1
  }
  return found
}

/** Lyrics that follow the song; click a line to jump there. */
export function LyricsLines({ track, size = 'large', clickable = true }: { track: Track | undefined; size?: 'small' | 'large'; clickable?: boolean }): JSX.Element {
  const { lyrics, loading } = useLyrics(track)
  const position = usePosition()
  const current = activeLine(lyrics, position)
  const box = useRef<HTMLDivElement>(null)
  const userScrolled = useRef(0)

  useEffect(() => {
    if (current < 0 || !box.current || Date.now() - userScrolled.current < 4000) return
    const el = box.current.querySelector<HTMLElement>(`[data-line="${current}"]`)
    if (!el) return
    const target = el.offsetTop - box.current.clientHeight * 0.35
    box.current.scrollTo({ top: Math.max(0, target), behavior: 'smooth' })
  }, [current])

  if (!track) return <div className={`lyrics-empty ${size}`}>Play a song to see its lyrics.</div>
  if (loading) return <div className={`lyrics-empty ${size}`}><Spinner /></div>
  if (!lyrics || lyrics.kind === 'none') return <div className={`lyrics-empty ${size}`}>No lyrics found for this song.</div>

  return (
    <div className={`lyrics ${size}`} ref={box} onWheel={() => (userScrolled.current = Date.now())}>
      {lyrics.kind === 'synced' ? (
        lyrics.lines.map((l, i) => (
          <p
            key={i}
            data-line={i}
            className={`${i === current ? 'now' : i < current ? 'past' : ''} ${l.text ? '' : 'gap'} ${clickable ? 'click' : ''}`}
            onClick={clickable ? () => seek(l.time) : undefined}
          >
            {l.text || '♪'}
          </p>
        ))
      ) : (
        <div className="plain">{lyrics.text}</div>
      )}
      <div className="lyrics-source">Lyrics from {lyrics.source}</div>
    </div>
  )
}
