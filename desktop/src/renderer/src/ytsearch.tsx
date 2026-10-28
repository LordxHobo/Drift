// Searching all of YouTube, page after page as you scroll (YouTube sends about 20 results at a time).
import { useCallback, useEffect, useRef, useState } from 'react'
import type { JSX } from 'react'
import type { Track } from '@shared/types'
import { drift } from './state'
import { Spinner } from './ui'

interface State {
  q: string
  list: Track[]
  more?: string
  loading: boolean
  error?: string
  /** Pages loaded so far. */
  pages: number
}

export function useYouTubeSearch(query: string, enabled = true): State & { loadMore: () => void } {
  const q = query.trim()
  const [s, setS] = useState<State>({ q: '', list: [], loading: false, pages: 0 })
  const busy = useRef(false)

  useEffect(() => {
    if (!enabled || q.length < 2) return
    let alive = true
    busy.current = true
    setS({ q, list: [], loading: true, pages: 0 })
    const timer = window.setTimeout(() => {
      drift
        .searchYouTube(q)
        .then((r) => alive && setS({ q, list: r.tracks, more: r.more, loading: false, pages: 1 }))
        .catch((e) => alive && setS({ q, list: [], loading: false, pages: 0, error: e instanceof Error ? e.message : String(e) }))
        .finally(() => (busy.current = false))
    }, 350)
    return () => {
      alive = false
      clearTimeout(timer)
      busy.current = false
    }
  }, [q, enabled])

  const loadMore = useCallback(() => {
    if (busy.current || !s.more || s.q !== q) return
    busy.current = true
    const token = s.more
    setS((cur) => ({ ...cur, loading: true }))
    drift
      .searchYouTube(q, token)
      .then((r) =>
        setS((cur) => {
          if (cur.q !== q) return cur
          const seen = new Set(cur.list.map((t) => t.id))
          const fresh = r.tracks.filter((t) => !seen.has(t.id))
          // A page with nothing new means YouTube has run out.
          return { ...cur, list: [...cur.list, ...fresh], more: fresh.length ? r.more : undefined, loading: false, pages: cur.pages + 1 }
        })
      )
      .catch(() => setS((cur) => ({ ...cur, loading: false, more: undefined })))
      .finally(() => (busy.current = false))
  }, [s.more, s.q, q])

  return { ...(s.q === q ? s : { q, list: [], loading: enabled && q.length >= 2, pages: 0 }), loadMore }
}

/** Put at the end of a list: loads the next page when it scrolls into view. */
export function LoadMore({ onVisible, loading, done }: { onVisible: () => void; loading: boolean; done: boolean }): JSX.Element | null {
  // (The watcher is set up again after each page, so it fires again while the end is still in view.)
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const el = ref.current
    if (!el || done) return
    const io = new IntersectionObserver((entries) => entries.some((e) => e.isIntersecting) && onVisible(), { rootMargin: '400px' })
    io.observe(el)
    return () => io.disconnect()
  }, [onVisible, done, loading])
  if (done) return null
  return <div ref={ref} className="load-more">{loading ? <Spinner size={18} /> : null}</div>
}
