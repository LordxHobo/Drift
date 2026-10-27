// One song in full: details, where it is in your library, lyrics, and what plays next.
import { useEffect, useState } from 'react'
import type { JSX } from 'react'
import type { StreamInfo, Track } from '@shared/types'
import { Icon } from '../icons'
import { go, libraryStore, openMenu, panelStore, toast, useStore } from '../state'
import { addToQueue, playList, playNext, usePlayer } from '../player'
import { LyricsLines } from '../lyrics'
import { TrackArt, addToPlaylistItems, goToAlbum, goToArtist, isLiked, startRadio, toggleLike, trackMenu } from '../ui'
import { formatTime, ytLink } from '../util'
import { useMusic } from './common'

function quality(info: StreamInfo | undefined): string {
  if (!info) return '—'
  const codec = info.mime.includes('webm') ? 'Opus' : info.mime.includes('mp4') ? 'AAC' : info.mime
  return `${codec} · ${Math.round(info.bitrate / 1000)} kbps`
}

export function SongPage({ track }: { track: Track }): JSX.Element {
  const lib = useStore(libraryStore)
  const p = usePlayer()
  const music = useMusic()
  const isCurrent = p.current?.id === track.id
  const [info, setInfo] = useState<StreamInfo | undefined>(isCurrent ? p.info : undefined)
  useEffect(() => {
    if (isCurrent && p.info) setInfo(p.info)
  }, [isCurrent, p.info])

  const inPlaylists = lib.playlists.filter((pl) => pl.tracks.some((t) => t.id === track.id))
  const liked = isLiked(track.id)
  const upNext = isCurrent ? p.queue.slice(p.index + 1, p.index + 9) : []

  const rows: [string, JSX.Element | string][] = [
    ['Artist', <button className="link" onClick={() => void goToArtist(track.artist)}>{track.artist || '—'}</button>],
    ['Album', track.album ? <button className="link" onClick={() => void goToAlbum(track)}>{track.album}</button> : '—'],
    ['Length', track.duration ? formatTime(track.duration) : '—'],
    ['Quality', isCurrent ? quality(info) : 'Shown while it plays'],
    ['Source', track.upload ? 'YouTube upload' : info?.note ? `YouTube Music · ${info.note}` : 'YouTube Music'],
    ['In your library', liked || inPlaylists.length ? (
      <span className="detail-places">
        {liked && <button className="link" onClick={() => go({ name: 'liked' })}>Liked songs</button>}
        {inPlaylists.map((pl) => (
          <button key={pl.id} className="link" onClick={() => go({ name: 'playlist', id: pl.id })}>{pl.name}</button>
        ))}
      </span>
    ) : 'Not saved yet']
  ]

  return (
    <div className={`page song-page ${music ? 'music' : ''}`}>
      <div className="song-main">
        <div className="song-top">
          <TrackArt track={track} px={600} className="song-art" radius={music ? 10 : 8} />
          <div className="song-head">
            <div className="d-kind">Song</div>
            <h1>{track.title}</h1>
            <div className="song-artist">
              <button className="link" onClick={() => void goToArtist(track.artist)}>{track.artist}</button>
            </div>
            <div className="song-buttons">
              <button className="btn primary" onClick={() => playList([track], 0, { kind: 'song', name: track.title })}>
                <Icon name="play" size={14} /> Play
              </button>
              <button className={`btn ${liked ? 'on' : ''}`} onClick={() => toggleLike(track)}>
                <Icon name={liked ? 'heartFill' : 'heart'} size={14} /> {liked ? 'Liked' : 'Like'}
              </button>
              <button className="btn" onClick={(e) => openMenu(e, addToPlaylistItems([track]))}>
                <Icon name="plus" size={14} /> Add to playlist
              </button>
              <button className="btn" onClick={() => void startRadio(track)}>
                <Icon name="radio" size={14} /> Radio
              </button>
              <button className="icon-btn" aria-label="More" onClick={(e) => openMenu(e, [
                ...trackMenu(track),
                { label: '', separator: true },
                { label: 'Open on YouTube', icon: 'external', action: () => void window.drift.openExternal(ytLink(track)) }
              ])}>
                <Icon name="more" size={18} />
              </button>
            </div>
          </div>
        </div>

        <dl className="detail-list">
          {rows.map(([k, v]) => (
            <div key={k}>
              <dt>{k}</dt>
              <dd>{v}</dd>
            </div>
          ))}
        </dl>

        <section className="song-lyrics">
          <div className="shelf-head">
            <h2>Lyrics</h2>
            {isCurrent && <button className="link see-all" onClick={() => (music ? panelStore.set('lyrics') : go({ name: 'lyrics' }))}>Open lyrics</button>}
          </div>
          <div className="song-lyrics-box">
            <LyricsLines track={track} size="small" clickable={isCurrent} />
          </div>
        </section>
      </div>

      <aside className="song-side">
        <h2>Up next</h2>
        {!isCurrent ? (
          <div className="empty small">
            <p>Not playing right now.</p>
            <button className="btn small" onClick={() => playNext([track])}>Play next</button>{' '}
            <button className="btn small" onClick={() => (addToQueue([track]), toast('Added to the queue'))}>Add to queue</button>
          </div>
        ) : upNext.length ? (
          upNext.map((t, i) => (
            <div key={`${t.id}-${i}`} className="q-row" onContextMenu={(e) => openMenu(e, trackMenu(t))} onClick={() => go({ name: 'song', track: t })}>
              <TrackArt track={t} size={40} radius={4} />
              <div className="q-text">
                <div className="q-title">{t.title}</div>
                <div className="q-artist">{t.artist}</div>
              </div>
            </div>
          ))
        ) : (
          <div className="empty small">Similar songs play when the list ends.</div>
        )}
      </aside>
    </div>
  )
}
