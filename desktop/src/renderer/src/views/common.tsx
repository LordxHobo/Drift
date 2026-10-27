import type { JSX, ReactNode } from 'react'
import type { Track } from '@shared/types'
import { Icon } from '../icons'
import { settingsStore, useStore } from '../state'
import { playList, toggle, usePlayer } from '../player'
import type { PlayContext } from '../player'
import { BigPlay, Spinner } from '../ui'
import { CollectionDownloadStatus, DownloadToggle } from '../downloads'
import { useArtColor } from '../util'

export function useMusic(): boolean {
  return useStore(settingsStore).style === 'music'
}

/** The top of a playlist, album or Liked songs page, in either style. */
export function CollectionHeader({ cover, coverURL, seed, kind, title, subtitle, meta, tracks, context, onMore, buttons, filter, downloadKey }: {
  cover: ReactNode
  coverURL?: string
  seed: string
  kind: string
  title: string
  subtitle?: ReactNode
  meta?: string
  tracks: Track[]
  context: PlayContext
  onMore?: (e: React.MouseEvent<HTMLButtonElement>) => void
  buttons?: ReactNode
  filter?: ReactNode
  /** "liked" or a playlist ID: shows the download button. */
  downloadKey?: string
}): JSX.Element {
  const music = useMusic()
  const color = useArtColor(coverURL, seed)
  const p = usePlayer()
  const playingHere = p.context?.kind === context.kind && p.context?.id === context.id
  const play = (shuffle: boolean): void => {
    if (playingHere && !shuffle) return toggle()
    playList(tracks, shuffle ? -1 : 0, context, { shuffle })
  }

  if (music) {
    return (
      <div className="m-header">
        <div className="m-header-cover">{cover}</div>
        <div className="m-header-text">
          <h1>{title}</h1>
          {subtitle && <div className="m-header-sub">{subtitle}</div>}
          {meta && <div className="m-header-meta">{kind} · {meta}</div>}
          {downloadKey && <CollectionDownloadStatus tracks={tracks} collection={downloadKey} />}
          <div className="m-header-buttons">
            <button className="pill" onClick={() => play(false)} disabled={!tracks.length}>
              <Icon name={playingHere && p.playing ? 'pause' : 'play'} size={14} /> {playingHere && p.playing ? 'Pause' : 'Play'}
            </button>
            <button className="pill" onClick={() => play(true)} disabled={!tracks.length}>
              <Icon name="shuffle" size={14} /> Shuffle
            </button>
            {downloadKey && <DownloadToggle tracks={tracks} collection={downloadKey} name={title} music />}
            {buttons}
            {onMore && (
              <button className="icon-btn tinted" aria-label="More" title="More" onClick={onMore}>
                <Icon name="more" size={20} />
              </button>
            )}
            {filter && <span className="m-header-filter">{filter}</span>}
          </div>
        </div>
      </div>
    )
  }

  return (
    <>
      <div className="d-header" style={{ ['--header-color' as string]: color }}>
        <div className="d-header-cover">{cover}</div>
        <div className="d-header-text">
          <div className="d-kind">{kind}</div>
          <h1 className={title.length > 24 ? 'long' : ''}>{title}</h1>
          <div className="d-meta">
            {subtitle && <b>{subtitle}</b>}
            {subtitle && meta ? ' · ' : ''}
            {meta}
          </div>
        </div>
      </div>
      <div className="d-actions" style={{ ['--header-color' as string]: color }}>
        <BigPlay onClick={() => play(false)} playing={playingHere && p.playing} />
        <button className="icon-btn big" aria-label="Shuffle" title="Shuffle" onClick={() => play(true)} disabled={!tracks.length}>
          <Icon name="shuffle" size={26} />
        </button>
        {downloadKey && <DownloadToggle tracks={tracks} collection={downloadKey} name={title} music={false} />}
        {buttons}
        {onMore && (
          <button className="icon-btn big" aria-label="More" title="More" onClick={onMore}>
            <Icon name="more" size={24} />
          </button>
        )}
        {downloadKey && <CollectionDownloadStatus tracks={tracks} collection={downloadKey} />}
        {filter && <span className="d-filter">{filter}</span>}
      </div>
    </>
  )
}

export function FilterField({ value, onChange, placeholder }: { value: string; onChange: (v: string) => void; placeholder: string }): JSX.Element {
  return (
    <label className="filter-field">
      <Icon name="search" size={14} />
      <input value={value} placeholder={placeholder} onChange={(e) => onChange(e.target.value)} onKeyDown={(e) => e.key === 'Escape' && onChange('')} />
      {value && (
        <button aria-label="Clear" onClick={() => onChange('')}>
          <Icon name="close" size={12} />
        </button>
      )}
    </label>
  )
}

export function Loading(): JSX.Element {
  return (
    <div className="loading">
      <Spinner size={26} />
    </div>
  )
}

export function Failed({ message, retry }: { message: string; retry?: () => void }): JSX.Element {
  return (
    <div className="failed">
      <p>{message}</p>
      {retry && <button className="btn" onClick={retry}>Try again</button>}
    </div>
  )
}

export function cleanError(e: unknown): string {
  const m = e instanceof Error ? e.message : String(e)
  return m.replace(/^Error invoking remote method '[^']+': (Error: )?/, '') || 'Something went wrong.'
}

/** Filters songs by title, artist or album. Returns the songs and their positions in the full list. */
export function filterTracks(tracks: Track[], q: string): { list: Track[]; indexes?: number[] } {
  const s = q.trim().toLowerCase()
  if (!s) return { list: tracks }
  const indexes: number[] = []
  const list: Track[] = []
  tracks.forEach((t, i) => {
    if (`${t.title} ${t.artist} ${t.album ?? ''}`.toLowerCase().includes(s)) {
      list.push(t)
      indexes.push(i)
    }
  })
  return { list, indexes }
}
