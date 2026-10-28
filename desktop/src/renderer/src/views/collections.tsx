// Playlists, Liked songs, saved albums, and the Apple Music style library pages.
import { useEffect, useState } from 'react'
import type { JSX } from 'react'
import type { Playlist, Track } from '@shared/types'
import { accountStore, drift, downloadsStore, go, libraryStore, openMenu, useStore } from '../state'
import { playList } from '../player'
import { Art, Card, LikedCover, PlaylistCover, TrackArt, TrackList, playlistMenu, newPlaylist } from '../ui'
import { allSongs, artwork, formatTotal, plural, resized } from '../util'
import { CollectionHeader, FilterField, filterTracks, useMusic } from './common'
import { formatBytes } from '../downloads'
import { editPlaylist } from './editPlaylist'
import { Icon } from '../icons'

/** Downloaded songs, newest first (reloaded when downloads change). */
function useDownloadedTracks(active: boolean): Track[] {
  const d = useStore(downloadsStore)
  const [tracks, setTracks] = useState<Track[]>([])
  useEffect(() => {
    if (active) void drift.downloadedTracks().then(setTracks)
  }, [active, d.done.length])
  return tracks
}

function DownloadSummary(): JSX.Element | null {
  const d = useStore(downloadsStore)
  const left = d.queued.length + d.active.length
  return (
    <div className="dl-summary">
      <span>{plural(d.done.length, 'song')} · {formatBytes(d.bytes)}</span>
      {left > 0 && <span>Downloading {plural(left, 'more song')}{d.active[0] ? ` · now: ${d.active[0].title}` : ''}</span>}
      {d.failed.length > 0 && (
        <span className="dl-failed">
          {plural(d.failed.length, 'song')} didn’t download.{' '}
          <button className="link" onClick={() => void drift.retryFailedDownloads()}>Try again</button>
        </span>
      )}
    </div>
  )
}

export function PlaylistPage({ id }: { id: string }): JSX.Element {
  const lib = useStore(libraryStore)
  const account = useStore(accountStore)
  const [filter, setFilter] = useState('')
  const music = useMusic()
  const p = lib.playlists.find((x) => x.id === id)
  if (!p) return <div className="empty">This playlist was deleted.</div>
  const { list, indexes } = filterTracks(p.tracks, filter)
  const owner = p.isAlbum ? p.albumArtist ?? '' : account.username ?? 'You'
  return (
    <div className="page">
      <CollectionHeader
        cover={
          <button className="cover-edit" onClick={() => editPlaylist(p.id)} title="Edit details">
            <PlaylistCover p={p} size={music ? 230 : 200} radius={music ? 10 : 6} />
            <span className="cover-edit-hint"><Icon name="edit" size={26} /></span>
          </button>
        }
        coverURL={p.tracks[0] ? artwork(p.tracks[0], 120) : undefined}
        seed={p.id}
        kind={p.isAlbum ? 'Album' : 'Playlist'}
        title={p.name}
        subtitle={owner}
        meta={`${plural(p.tracks.length, 'song')}, ${formatTotal(p.tracks)}`}
        tracks={p.tracks}
        context={{ kind: 'playlist', id: p.id, name: p.name }}
        downloadKey={p.id}
        onMore={(e) => openMenu(e, playlistMenu(p))}
        filter={p.tracks.length > 8 ? <FilterField value={filter} onChange={setFilter} placeholder={p.isAlbum ? 'Find in album' : 'Find in playlist'} /> : null}
      />
      <TrackList
        tracks={list}
        indexes={indexes}
        playlistId={p.id}
        context={{ kind: 'playlist', id: p.id, name: p.name }}
        showAlbum={!p.isAlbum}
        emptyText={filter ? 'No songs match.' : 'This playlist is empty. Right-click a song anywhere and choose Add to playlist.'}
      />
    </div>
  )
}

export function LikedPage(): JSX.Element {
  const lib = useStore(libraryStore)
  const account = useStore(accountStore)
  const [filter, setFilter] = useState('')
  const music = useMusic()
  const { list, indexes } = filterTracks(lib.liked, filter)
  return (
    <div className="page">
      <CollectionHeader
        cover={<LikedCover size={music ? 230 : 200} radius={music ? 10 : 6} />}
        seed="liked"
        kind="Playlist"
        title={music ? 'Liked Songs' : 'Liked songs'}
        subtitle={account.username ?? 'You'}
        meta={`${plural(lib.liked.length, 'song')}, ${formatTotal(lib.liked)}`}
        tracks={lib.liked}
        context={{ kind: 'liked', id: 'liked', name: 'Liked songs' }}
        downloadKey="liked"
        filter={lib.liked.length > 8 ? <FilterField value={filter} onChange={setFilter} placeholder="Find in Liked songs" /> : null}
      />
      <TrackList
        tracks={list}
        indexes={indexes}
        context={{ kind: 'liked', id: 'liked', name: 'Liked songs' }}
        emptyText={filter ? 'No songs match.' : 'Songs you like show up here. Click the heart next to any song.'}
      />
    </div>
  )
}

function PlaylistCard({ p }: { p: Playlist }): JSX.Element {
  const music = useMusic()
  return (
    <Card
      title={p.name}
      subtitle={p.isAlbum ? p.albumArtist ?? 'Album' : music ? undefined : plural(p.tracks.length, 'song')}
      image={<PlaylistCover p={p} radius={music ? 8 : 6} />}
      onOpen={() => go({ name: 'playlist', id: p.id })}
      onPlay={p.tracks.length ? () => playList(p.tracks, 0, { kind: 'playlist', id: p.id, name: p.name }, { shuffle: false }) : undefined}
      onContextMenu={(e) => openMenu(e, playlistMenu(p))}
    />
  )
}

export function CollectionPage({ kind }: { kind: 'artists' | 'albums' | 'songs' | 'recent' | 'playlists' | 'downloaded' }): JSX.Element {
  const lib = useStore(libraryStore)
  const [filter, setFilter] = useState('')
  const titles = { artists: 'Artists', albums: 'Albums', songs: 'Songs', recent: 'Recently Played', playlists: 'Playlists', downloaded: 'Downloaded' }
  const downloaded = useDownloadedTracks(kind === 'downloaded')
  const q = filter.trim().toLowerCase()

  let body: JSX.Element
  if (kind === 'artists') {
    const list = lib.artists.filter((a) => !q || a.artist.name.toLowerCase().includes(q))
    body = list.length ? (
      <div className="grid">
        {list.map((a) => (
          <Card
            key={a.artist.id}
            round
            title={a.artist.name}
            subtitle={a.newReleases.length ? `${plural(a.newReleases.length, 'new release')}` : undefined}
            image={<Art src={resized(a.artist.thumbnail, 400)} seed={a.artist.id} round />}
            onOpen={() => go({ name: 'artist', id: a.artist.id, hint: a.artist })}
          />
        ))}
      </div>
    ) : (
      <div className="empty">Artists you follow show up here. Open an artist and click Follow.</div>
    )
  } else if (kind === 'albums' || kind === 'playlists') {
    const list = lib.playlists.filter((p) => (kind === 'albums' ? p.isAlbum : !p.isAlbum) && (!q || p.name.toLowerCase().includes(q)))
    body = list.length ? (
      <div className="grid">{list.map((p) => <PlaylistCard key={p.id} p={p} />)}</div>
    ) : (
      <div className="empty">
        {kind === 'albums' ? 'Albums you add to your library show up here.' : 'Make a playlist with the + button.'}
        {kind === 'playlists' && (
          <div><button className="btn" onClick={() => newPlaylist([])}>New playlist</button></div>
        )}
      </div>
    )
  } else if (kind === 'downloaded') {
    const { list, indexes } = filterTracks(downloaded, filter)
    body = (
      <>
        <DownloadSummary />
        <TrackList
          tracks={list}
          indexes={indexes}
          context={{ kind: 'playlist', id: 'collection-downloaded', name: 'Downloaded' }}
          emptyText={filter ? 'No songs match.' : 'Songs you download play without internet. Click the download button on a playlist, or right-click a song and choose Download.'}
        />
      </>
    )
  } else {
    const all = kind === 'songs' ? allSongs(lib.liked, lib.playlists) : lib.recent
    const { list, indexes } = filterTracks(all, filter)
    body = (
      <TrackList
        tracks={list}
        indexes={indexes}
        context={{ kind: 'playlist', id: `collection-${kind}`, name: titles[kind] }}
        numbered={kind === 'songs'}
        emptyText={kind === 'songs' ? 'Songs in your playlists and Liked songs show up here.' : 'Songs you play on this computer show up here.'}
      />
    )
  }

  return (
    <div className="page">
      <div className="page-title-row">
        <h1 className="page-title">{titles[kind]}</h1>
        <FilterField value={filter} onChange={setFilter} placeholder={`Find in ${titles[kind]}`} />
      </div>
      {kind === 'recent' && lib.recent[0] && (
        <div className="recent-strip">
          {lib.recent.slice(0, 6).map((t) => (
            <Card key={t.id} title={t.title} subtitle={t.artist} image={<TrackArt track={t} px={400} radius={8} />} onOpen={() => go({ name: 'song', track: t })} onPlay={() => playList([t], 0, { kind: 'song', name: t.title })} />
          ))}
        </div>
      )}
      {body}
    </div>
  )
}
