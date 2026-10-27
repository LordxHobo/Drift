// Downloads in the window: song marks, the download button on playlists, and the progress pill.
import { useMemo } from 'react'
import type { JSX } from 'react'
import type { DownloadsState, Track } from '@shared/types'
import { Icon } from './icons'
import { drift, downloadsStore, go, toast, useStore } from './state'
import type { MenuItem } from './state'

export type DownloadStatus = 'done' | 'active' | 'queued' | undefined

export function useDownloadSets(): { done: Set<string>; pending: Set<string> } {
  const d = useStore(downloadsStore)
  return useMemo(
    () => ({ done: new Set(d.done), pending: new Set([...d.queued, ...d.active.map((a) => a.id)]) }),
    [d.done, d.queued, d.active]
  )
}

export function statusOf(id: string): DownloadStatus {
  const d = downloadsStore.get()
  if (d.done.includes(id)) return 'done'
  if (d.active.some((a) => a.id === id)) return 'active'
  if (d.queued.includes(id)) return 'queued'
  return undefined
}

/** The small mark next to a song's title. */
export function DownloadMark({ id, sets }: { id: string; sets: { done: Set<string>; pending: Set<string> } }): JSX.Element | null {
  if (sets.done.has(id)) {
    return (
      <span className="dl-mark done" title="Downloaded" aria-label="Downloaded">
        <Icon name="downloaded" size={14} />
      </span>
    )
  }
  if (sets.pending.has(id)) {
    return (
      <span className="dl-mark pending" title="Downloading" aria-label="Downloading">
        <Icon name="download" size={14} />
      </span>
    )
  }
  return null
}

export function downloadMenuItem(t: Track): MenuItem {
  const s = statusOf(t.id)
  if (s === 'done') return { label: 'Remove download', icon: 'trash', action: () => void drift.removeDownloads([t.id]) }
  if (s) return { label: 'Cancel download', icon: 'close', action: () => void drift.removeDownloads([t.id]) }
  return {
    label: 'Download',
    icon: 'download',
    action: () => {
      void drift.download([t])
      toast(`Downloading “${t.title}”`)
    }
  }
}

function timeLeft(d: DownloadsState, remainingSongs: number): string | undefined {
  if (!d.rate || remainingSongs === 0) return undefined
  const avg = d.done.length ? d.bytes / d.done.length : 5_000_000
  const activeLeft = d.active.reduce((n, a) => n + Math.max(0, (a.total || avg) - a.received), 0)
  const bytes = activeLeft + Math.max(0, remainingSongs - d.active.length) * avg
  const secs = bytes / d.rate
  if (secs < 60) return 'less than a minute left'
  const m = Math.round(secs / 60)
  return m < 60 ? `about ${m} min left` : `about ${Math.floor(m / 60)} h ${m % 60} min left`
}

/** "Downloading 12 of 40 · about 3 min left" for one playlist, or "Downloaded". */
export function useCollectionStatus(tracks: Track[], key: string): { kept: boolean; text?: string } {
  const d = useStore(downloadsStore)
  const done = new Set(d.done)
  const kept = d.keep.includes(key)
  const have = tracks.filter((t) => done.has(t.id)).length
  const pendingIds = new Set([...d.queued, ...d.active.map((a) => a.id)])
  const pending = tracks.filter((t) => pendingIds.has(t.id)).length
  if (pending > 0) {
    const left = timeLeft(d, pending)
    return { kept, text: `Downloading · ${have} of ${tracks.length}${left ? ` · ${left}` : ''}` }
  }
  if (kept && tracks.length && have === tracks.length) return { kept, text: 'Downloaded' }
  if (kept && have < tracks.length) return { kept, text: `${have} of ${tracks.length} downloaded` }
  return { kept }
}

/** The download button at the top of a playlist or Liked songs. */
export function DownloadToggle({ tracks, collection, name, music }: { tracks: Track[]; collection: string; name: string; music: boolean }): JSX.Element {
  const { kept } = useCollectionStatus(tracks, collection)
  return (
    <button
      className={`${music ? 'icon-btn tinted' : 'icon-btn big'} dl-toggle ${kept ? 'on' : ''}`}
      title={kept ? 'Remove download' : 'Download'}
      aria-label={kept ? `Remove download of ${name}` : `Download ${name}`}
      aria-pressed={kept}
      disabled={!tracks.length}
      onClick={() => {
        void drift.keepDownloaded(collection, !kept)
        toast(kept ? `Removed the download of ${name}` : `Downloading ${name}. New songs in it download too.`)
      }}
    >
      <Icon name={kept ? 'downloaded' : 'download'} size={music ? 22 : 28} />
    </button>
  )
}

export function CollectionDownloadStatus({ tracks, collection }: { tracks: Track[]; collection: string }): JSX.Element | null {
  const { text } = useCollectionStatus(tracks, collection)
  return text ? <div className="dl-status">{text}</div> : null
}

/** Small progress pill while songs download. */
export function DownloadPill({ className }: { className?: string }): JSX.Element | null {
  const d = useStore(downloadsStore)
  const left = d.queued.length + d.active.length
  if (!left) return null
  const time = timeLeft(d, left)
  return (
    <button className={`import-pill ${className ?? ''}`} onClick={() => go({ name: 'collection', kind: 'downloaded' })} title={time ?? 'Downloading'}>
      <Icon name="download" size={14} /> Downloading · {left} left
    </button>
  )
}

export function formatBytes(n: number): string {
  if (n < 1e6) return `${Math.round(n / 1e3)} KB`
  if (n < 1e9) return `${(n / 1e6).toFixed(n < 1e8 ? 1 : 0)} MB`
  return `${(n / 1e9).toFixed(2)} GB`
}
