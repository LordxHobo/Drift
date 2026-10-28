// "Replace with another version": pick a different YouTube Music song or YouTube video for a song in
// a playlist (or Liked songs). It keeps its place; the pick is played exactly as chosen.
import { useEffect, useState } from 'react'
import type { JSX } from 'react'
import type { Track } from '@shared/types'
import { Icon } from '../icons'
import { drift, Store, toast, useStore } from '../state'
import { playList, toggle, usePlayer } from '../player'
import { Spinner, TrackArt } from '../ui'
import { formatTime } from '../util'

export type SongPlace = { playlistId: string } | { liked: true }

export const replaceStore = new Store<{ track: Track; place: SongPlace; index: number } | null>(null)

export function openReplace(track: Track, place: SongPlace, index: number): void {
  replaceStore.set({ track, place, index })
}

const mainArtist = (a: string): string => a.split(/, | & | x | feat\. | ft\. /i)[0].trim()

type Source = 'music' | 'youtube'

export function ReplaceDialog(): JSX.Element | null {
  const req = useStore(replaceStore)
  const [query, setQuery] = useState('')
  const [source, setSource] = useState<Source>('music')
  const [results, setResults] = useState<{ key: string; list?: Track[]; error?: boolean }>({ key: '' })
  const player = usePlayer()

  useEffect(() => {
    if (!req) return
    setQuery(`${mainArtist(req.track.artist)} ${req.track.title}`.trim())
    setSource(req.track.upload ? 'youtube' : 'music')
  }, [req])

  const key = `${source}|${query.trim()}`
  useEffect(() => {
    const q = query.trim()
    if (!req || q.length < 2) return
    let live = true
    const timer = window.setTimeout(() => {
      const task = source === 'music' ? drift.versions(q) : drift.searchYouTube(q)
      task.then((list) => live && setResults({ key, list })).catch(() => live && setResults({ key, error: true }))
    }, 400)
    return () => {
      live = false
      clearTimeout(timer)
    }
  }, [key, req])

  if (!req) return null
  const close = (): void => replaceStore.set(null)
  const old = req.track
  const list = results.key === key ? results.list : undefined
  const failed = results.key === key && results.error

  const use = (v: Track): void => {
    // A YouTube Music song comes as it is. A YouTube video keeps the song's own name (upload titles are messy).
    const t: Track =
      source === 'music'
        ? { ...v, chosen: true }
        : { ...old, id: v.id, duration: v.duration ?? null, artworkURL: v.artworkURL ?? null, upload: true, podcast: null, album: null, explicit: null, chosen: true }
    void drift.replaceTrack(req.place, req.index, old.id, t).then(() => toast(`Replaced “${old.title}”`))
    close()
  }

  return (
    <div className="dialog-layer" onMouseDown={close}>
      <div className="dialog replace" onMouseDown={(e) => e.stopPropagation()} onKeyDown={(e) => e.key === 'Escape' && close()}>
        <h3>Replace with another version</h3>
        <div className="replace-now">
          <TrackArt track={old} size={44} radius={4} />
          <div className="replace-text">
            <div className="replace-title">
              {old.title}
              {old.explicit && <span className="explicit-mark" title="Explicit">E</span>}
            </div>
            <div className="replace-sub">{[old.artist, old.duration ? formatTime(old.duration) : ''].filter(Boolean).join(' · ')}</div>
          </div>
          <span className="replace-label">Now in your {'liked' in req.place ? 'Liked songs' : 'playlist'}</span>
        </div>
        <div className="replace-search">
          <label className="search-box">
            <Icon name="search" size={16} />
            <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search" autoFocus />
          </label>
          <div className="seg">
            <button className={source === 'music' ? 'on' : ''} onClick={() => setSource('music')}>YouTube Music</button>
            <button className={source === 'youtube' ? 'on' : ''} onClick={() => setSource('youtube')}>YouTube</button>
          </div>
        </div>
        <div className="replace-list">
          {failed ? (
            <div className="empty small">Search didn’t work. Check your connection.</div>
          ) : !list ? (
            <div className="empty small"><Spinner size={20} /></div>
          ) : !list.length ? (
            <div className="empty small">Nothing found.</div>
          ) : (
            list.slice(0, 30).map((v) => {
              const current = v.id === old.id
              const previewing = player.current?.id === v.id
              return (
                <div key={v.id} className={`replace-row ${current ? 'current' : ''}`}>
                  <button
                    className="replace-play"
                    aria-label={previewing && player.playing ? 'Pause' : `Listen to ${v.title}`}
                    title="Listen first"
                    onClick={() => (previewing ? toggle() : playList([{ ...v, chosen: true }], 0, { kind: 'song', name: 'Replace song' }))}
                  >
                    {source === 'youtube' ? (
                      <img className="replace-thumb" src={`https://i.ytimg.com/vi/${v.id}/mqdefault.jpg`} alt="" />
                    ) : (
                      <TrackArt track={v} size={44} radius={4} />
                    )}
                    <span className="replace-play-icon"><Icon name={previewing && player.playing ? 'pause' : 'play'} size={16} /></span>
                  </button>
                  <div className="replace-text">
                    <div className="replace-title">
                      {v.title}
                      {v.explicit && <span className="explicit-mark" title="Explicit">E</span>}
                    </div>
                    <div className="replace-sub">{[v.artist, v.album, v.duration ? formatTime(v.duration) : ''].filter(Boolean).join(' · ')}</div>
                  </div>
                  {current ? (
                    <span className="replace-label">Current</span>
                  ) : (
                    <button className="btn primary small" onClick={() => use(v)}>Use</button>
                  )}
                </div>
              )
            })
          )}
        </div>
        <p className="replace-hint">
          Click the picture to listen first. The song keeps its place; the version you pick plays exactly as it is.
        </p>
        <div className="dialog-buttons">
          <button className="btn ghost" onClick={close}>Cancel</button>
        </div>
      </div>
    </div>
  )
}
