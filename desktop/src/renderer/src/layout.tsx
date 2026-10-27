import { useEffect, useRef, useState } from 'react'
import type { JSX } from 'react'
import type { Playlist } from '@shared/types'
import { Icon, Logo } from './icons'
import {
  accountStore, back, downloadsStore, forward, fullPlayerStore, go, libraryStore, navStore, openMenu, openMenuAt, panelStore,
  readLocal, togglePanel, useRoute, useStore, writeLocal
} from './state'
import type { MenuItem, Route } from './state'
import { jumpTo, playList, removeFromQueue, usePlayer } from './player'
import { Progress, Transport, Volume } from './controls'
import { LyricsLines } from './lyrics'
import { Art, Avatar, IconButton, UpdateButton, LikedCover, PlaylistCover, TrackArt, goToArtist, isLiked, newPlaylist, playlistMenu, toggleLike, trackMenu } from './ui'
import { ImportPill, openImport } from './views/import'
import { DownloadPill } from './downloads'
import { formatTime, plural, useArtColor, artwork, resized } from './util'

const createItems = (): MenuItem[] => [
  { label: 'New playlist…', icon: 'plus', action: () => newPlaylist([]) },
  { label: 'Import from Spotify…', icon: 'list', action: openImport }
]

const same = (a: Route, b: Route): boolean => JSON.stringify(a) === JSON.stringify(b)

// MARK: Drift style

type LibFilter = 'all' | 'playlists' | 'albums' | 'artists'

export function DriftSidebar(): JSX.Element {
  const route = useRoute()
  const lib = useStore(libraryStore)
  const [filter, setFilter] = useState<LibFilter>(() => readLocal('libFilter', 'all'))
  const [find, setFind] = useState('')
  const [finding, setFinding] = useState(false)
  useEffect(() => writeLocal('libFilter', filter), [filter])

  const q = find.trim().toLowerCase()
  const match = (s: string): boolean => !q || s.toLowerCase().includes(q)
  const playlists = lib.playlists.filter((p) => (filter === 'all' || (filter === 'albums' ? p.isAlbum : filter === 'playlists' && !p.isAlbum)) && match(p.name))
  const artists = filter === 'all' || filter === 'artists' ? lib.artists.filter((a) => match(a.artist.name)) : []
  const showLiked = (filter === 'all' || filter === 'playlists') && match('Liked songs')
  const downloads = useStore(downloadsStore)
  const showDownloaded = downloads.done.length > 0 && (filter === 'all' || filter === 'playlists') && match('Downloaded')

  return (
    <aside className="sidebar">
      <nav className="panel nav-panel">
        <div className="brand">
          <Logo size={20} />
          <span>Drift</span>
        </div>
        <button className={`nav-item ${route.name === 'home' ? 'on' : ''}`} onClick={() => go({ name: 'home' })}>
          <Icon name={route.name === 'home' ? 'home' : 'homeLine'} size={22} />
          Home
        </button>
        <button className={`nav-item ${route.name === 'search' ? 'on' : ''}`} onClick={() => go({ name: 'search' })}>
          <Icon name="search" size={22} />
          Search
        </button>
      </nav>
      <div className="panel lib-panel">
        <div className="lib-head">
          <span className="lib-title">
            <Icon name="library" size={20} />
            Your Library
          </span>
          <IconButton icon="plus" label="New playlist or import" size={18} onClick={(e) => openMenuAt(e.currentTarget, createItems())} />
        </div>
        <div className="chips">
          {(['playlists', 'albums', 'artists'] as const).map((f) => (
            <button key={f} className={`chip ${filter === f ? 'on' : ''}`} onClick={() => setFilter(filter === f ? 'all' : f)}>
              {f[0].toUpperCase() + f.slice(1)}
            </button>
          ))}
          <span className="chips-spacer" />
          {finding ? (
            <input
              className="lib-find"
              autoFocus
              placeholder="Search in Your Library"
              value={find}
              onChange={(e) => setFind(e.target.value)}
              onBlur={() => !find && setFinding(false)}
              onKeyDown={(e) => e.key === 'Escape' && (setFind(''), setFinding(false))}
            />
          ) : (
            <IconButton icon="search" label="Search in Your Library" size={16} onClick={() => setFinding(true)} />
          )}
        </div>
        <div className="lib-list">
          {showLiked && (
            <LibRow
              on={route.name === 'liked'}
              onClick={() => go({ name: 'liked' })}
              art={<LikedCover size={44} radius={4} />}
              title="Liked songs"
              sub={`Playlist · ${plural(lib.liked.length, 'song')}`}
            />
          )}
          {playlists.map((p) => (
            <LibRow
              key={p.id}
              on={same(route, { name: 'playlist', id: p.id })}
              onClick={() => go({ name: 'playlist', id: p.id })}
              onContextMenu={(e) => openMenu(e, playlistMenu(p))}
              art={<PlaylistCover p={p} size={44} radius={4} />}
              title={p.name}
              sub={p.isAlbum ? `Album · ${p.albumArtist ?? ''}` : `Playlist · ${plural(p.tracks.length, 'song')}`}
            />
          ))}
          {artists.map((a) => (
            <LibRow
              key={a.artist.id}
              on={route.name === 'artist' && route.id === a.artist.id}
              onClick={() => go({ name: 'artist', id: a.artist.id, hint: a.artist })}
              art={<Art src={resized(a.artist.thumbnail, 120)} seed={a.artist.id} size={44} round />}
              title={a.artist.name}
              sub="Artist"
            />
          ))}
          {showDownloaded && (
            <LibRow
              on={route.name === 'collection' && route.kind === 'downloaded'}
              onClick={() => go({ name: 'collection', kind: 'downloaded' })}
              art={<span className="art dl-cover" style={{ width: 44, height: 44, borderRadius: 4 }}><Icon name="download" size={22} /></span>}
              title="Downloaded"
              sub={`On this computer · ${plural(downloads.done.length, 'song')}`}
            />
          )}
          {!showLiked && !playlists.length && !artists.length && !showDownloaded && <div className="empty small">Nothing here yet.</div>}
        </div>
        <button className={`lib-settings ${route.name === 'settings' ? 'on' : ''}`} onClick={() => go({ name: 'settings' })}>
          <Icon name="gear" size={18} />
          Settings
        </button>
      </div>
    </aside>
  )
}

function LibRow({ on, onClick, onContextMenu, art, title, sub }: {
  on: boolean; onClick: () => void; onContextMenu?: (e: React.MouseEvent) => void; art: JSX.Element; title: string; sub: string
}): JSX.Element {
  return (
    <button className={`lib-row ${on ? 'on' : ''}`} onClick={onClick} onContextMenu={onContextMenu}>
      {art}
      <span className="lib-text">
        <span className="lib-name">{title}</span>
        <span className="lib-sub">{sub}</span>
      </span>
    </button>
  )
}

/** Back/forward, the search field (on the search page), new releases and your profile. */
export function TopBar({ children }: { children?: JSX.Element | null }): JSX.Element {
  const nav = useStore(navStore)
  return (
    <div className="topbar">
      <div className="topbar-nav">
        <IconButton icon="back" label="Back" className="round" onClick={back} disabled={nav.index === 0} />
        <IconButton icon="forward" label="Forward" className="round" onClick={forward} disabled={nav.index >= nav.stack.length - 1} />
      </div>
      <div className="topbar-middle">{children}</div>
      <div className="topbar-right">
        <ImportPill />
        <DownloadPill />
        <UpdateButton />
        <ReleasesBell />
        <ProfileButton />
      </div>
    </div>
  )
}

function ReleasesBell(): JSX.Element {
  const lib = useStore(libraryStore)
  const releases = lib.artists.flatMap((a) => a.newReleases).sort((a, b) => b.foundAt - a.foundAt)
  const [seen, setSeen] = useState(() => readLocal('releasesSeen', 0))
  const unseen = releases.filter((r) => r.foundAt > seen).length
  return (
    <button
      className="icon-btn round bell"
      title="New releases"
      aria-label={unseen ? `${unseen} new releases` : 'New releases'}
      onClick={(e) => {
        const newest = releases[0]?.foundAt ?? seen
        setSeen(newest)
        writeLocal('releasesSeen', newest)
        openMenuAt(e.currentTarget, releases.length
          ? releases.slice(0, 12).map((r) => ({
              label: `${r.album.title} · ${r.artistName}`,
              icon: 'sparkle',
              action: () => go({ name: 'album', id: r.album.id, hint: r.album })
            }))
          : [{ label: 'New releases from artists you follow show up here.', disabled: true }])
      }}
    >
      <Icon name="bell" size={18} />
      {unseen > 0 && <span className="dot" />}
    </button>
  )
}

function ProfileButton(): JSX.Element {
  const account = useStore(accountStore)
  return (
    <button
      className="profile-btn"
      title={account.username ?? 'Profile'}
      aria-label="Profile and settings"
      onClick={(e) =>
        openMenuAt(e.currentTarget, [
          ...(account.linked
            ? [{ label: account.username ? `Signed in as ${account.username}` : 'Linked with your phone', icon: 'phone', disabled: true }]
            : [{ label: 'Link your phone…', icon: 'phone', action: () => go({ name: 'settings' }) }]),
          { label: 'Import from Spotify…', icon: 'plus', action: openImport },
          { label: 'Settings', icon: 'gear', action: () => go({ name: 'settings' }) }
        ])
      }
    >
      <Avatar size={32} />
    </button>
  )
}

export function DriftPlayerBar(): JSX.Element {
  const p = usePlayer()
  const panel = useStore(panelStore)
  const route = useRoute()
  useStore(libraryStore)
  const t = p.current
  return (
    <footer className="playerbar">
      <div className="pb-left">
        {t && (
          <>
            <button className="pb-art" onClick={() => go({ name: 'song', track: t })} title="Song details">
              <TrackArt track={t} size={56} radius={6} />
            </button>
            <div className="pb-text">
              <button className="pb-title link" onClick={() => go({ name: 'song', track: t })} onContextMenu={(e) => openMenu(e, trackMenu(t))}>
                {t.title}
              </button>
              <button className="pb-artist link" onClick={() => void goToArtist(t.artist)}>{t.artist}</button>
            </div>
            <button className={`like-btn ${isLiked(t.id) ? 'on' : ''}`} aria-label="Like" title={isLiked(t.id) ? 'Remove from Liked songs' : 'Save to Liked songs'} onClick={() => toggleLike(t)}>
              <Icon name={isLiked(t.id) ? 'heartFill' : 'heart'} size={18} />
            </button>
          </>
        )}
      </div>
      <div className="pb-center">
        <Transport />
        <Progress />
        {p.error && <div className="pb-error" title={p.error}>{p.error}</div>}
      </div>
      <div className="pb-right">
        <IconButton icon="lyrics" label="Lyrics" active={panel === 'lyrics'} size={18} onClick={() => togglePanel('lyrics')} />
        <IconButton icon="queue" label="Queue" active={panel === 'queue'} size={18} onClick={() => togglePanel('queue')} />
        <Volume />
        <IconButton icon="expand" label="Full-screen lyrics" active={route.name === 'lyrics'} size={16} onClick={() => (route.name === 'lyrics' ? back() : go({ name: 'lyrics' }))} />
      </div>
    </footer>
  )
}

export function SidePanel(): JSX.Element | null {
  const panel = useStore(panelStore)
  const route = useRoute()
  if (panel === 'none' || route.name === 'lyrics') return null
  return (
    <aside className="panel side-panel">
      <div className="side-head">
        <div className="side-tabs">
          <button className={panel === 'lyrics' ? 'on' : ''} onClick={() => panelStore.set('lyrics')}>Lyrics</button>
          <button className={panel === 'queue' ? 'on' : ''} onClick={() => panelStore.set('queue')}>Up next</button>
        </div>
        <IconButton icon="close" label="Close" size={16} onClick={() => panelStore.set('none')} />
      </div>
      {panel === 'lyrics' ? <LyricsPanel /> : <QueuePanel />}
    </aside>
  )
}

function LyricsPanel(): JSX.Element {
  const p = usePlayer()
  const t = p.current
  const color = useArtColor(t ? artwork(t, 120) : undefined, t?.id ?? 'none')
  return (
    <div className="lyrics-panel">
      {t && (
        <div className="lp-now">
          <TrackArt track={t} size={56} radius={6} />
          <div>
            <div className="lp-title">{t.title}</div>
            <div className="lp-artist">{t.artist}</div>
          </div>
        </div>
      )}
      <div className="lp-box" style={{ background: color }}>
        <div className="lp-label">LYRICS</div>
        <LyricsLines track={t} size="small" />
      </div>
    </div>
  )
}

function QueuePanel(): JSX.Element {
  const p = usePlayer()
  const upcoming = p.queue.slice(p.index + 1, p.index + 101)
  return (
    <div className="queue-panel">
      {p.current ? (
        <>
          <div className="q-label">Now playing</div>
          <QueueRow i={p.index} />
          <div className="q-label">
            Next {p.context ? <>from <span className="q-context">{p.context.name}</span></> : ''}
          </div>
          {upcoming.length ? upcoming.map((_, j) => <QueueRow key={`${p.index + 1 + j}-${p.queue[p.index + 1 + j].id}`} i={p.index + 1 + j} />) : (
            <div className="empty small">Similar songs play when the list ends.</div>
          )}
        </>
      ) : (
        <div className="empty small">Nothing is playing.</div>
      )}
    </div>
  )
}

function QueueRow({ i }: { i: number }): JSX.Element {
  const p = usePlayer()
  const t = p.queue[i]
  const current = i === p.index
  return (
    <div className={`q-row ${current ? 'current' : ''}`} onDoubleClick={() => jumpTo(i)} onContextMenu={(e) => openMenu(e, [
      ...trackMenu(t),
      ...(current ? [] : [{ label: '', separator: true }, { label: 'Remove from queue', icon: 'trash', action: () => removeFromQueue(i) }])
    ])}>
      <button className="q-art" onClick={() => jumpTo(i)} aria-label={`Play ${t.title}`}>
        <TrackArt track={t} size={40} radius={4} />
        <span className="q-play"><Icon name="play" size={14} /></span>
      </button>
      <div className="q-text">
        <div className="q-title">{t.title}</div>
        <div className="q-artist">{t.artist}</div>
      </div>
      {!current && <IconButton icon="close" label="Remove from queue" size={14} className="q-remove" onClick={() => removeFromQueue(i)} />}
    </div>
  )
}

/** Drift style: lyrics filling the main area, in the artwork's color. */
export function LyricsView(): JSX.Element {
  const p = usePlayer()
  const t = p.current
  const color = useArtColor(t ? artwork(t, 120) : undefined, t?.id ?? 'none')
  return (
    <div className="lyrics-view" style={{ background: color }}>
      <div className="lv-head">
        <IconButton icon="minimize" label="Close lyrics" className="round" onClick={back} />
        {t && (
          <div className="lv-now">
            <TrackArt track={t} size={44} radius={4} />
            <div>
              <div className="lv-title">{t.title}</div>
              <div className="lv-artist">{t.artist}</div>
            </div>
          </div>
        )}
      </div>
      <LyricsLines track={t} size="large" />
    </div>
  )
}

// MARK: Apple Music style

export function MusicSidebar(): JSX.Element {
  const route = useRoute()
  const lib = useStore(libraryStore)
  const account = useStore(accountStore)
  const [q, setQ] = useState(route.name === 'search' ? route.q ?? '' : '')
  const input = useRef<HTMLInputElement>(null)
  useEffect(() => {
    if (route.name !== 'search') setQ('')
  }, [route.name])
  useEffect(() => {
    const focus = (): void => input.current?.focus()
    window.addEventListener('drift:focus-search', focus)
    return () => window.removeEventListener('drift:focus-search', focus)
  }, [])

  const item = (r: Route, icon: string, label: string): JSX.Element => (
    <button className={`m-item ${same(route, r) ? 'on' : ''}`} onClick={() => go(r)}>
      <Icon name={icon} size={18} className="m-icon" />
      <span>{label}</span>
    </button>
  )
  const lists = lib.playlists.filter((p) => !p.isAlbum)
  return (
    <aside className="m-sidebar">
      <div className="m-search">
        <Icon name="search" size={15} />
        <input
          ref={input}
          placeholder="Search"
          value={q}
          onChange={(e) => {
            setQ(e.target.value)
            go({ name: 'search', q: e.target.value })
          }}
          onFocus={() => route.name !== 'search' && go({ name: 'search', q })}
        />
      </div>
      <div className="m-scroll">
        {item({ name: 'home' }, 'homeLine', 'Home')}
        <div className="m-section">Library</div>
        {item({ name: 'collection', kind: 'recent' }, 'clock', 'Recently Played')}
        {item({ name: 'collection', kind: 'artists' }, 'mic', 'Artists')}
        {item({ name: 'collection', kind: 'albums' }, 'album', 'Albums')}
        {item({ name: 'collection', kind: 'songs' }, 'note', 'Songs')}
        {item({ name: 'liked' }, 'heart', 'Liked Songs')}
        {item({ name: 'collection', kind: 'downloaded' }, 'download', 'Downloaded')}
        <div className="m-section">
          Playlists
          <IconButton icon="plus" label="New playlist or import" size={14} onClick={(e) => openMenuAt(e.currentTarget, createItems())} />
        </div>
        {item({ name: 'collection', kind: 'playlists' }, 'grid', 'All Playlists')}
        {lists.map((p: Playlist) => (
          <button
            key={p.id}
            className={`m-item ${same(route, { name: 'playlist', id: p.id }) ? 'on' : ''}`}
            onClick={() => go({ name: 'playlist', id: p.id })}
            onContextMenu={(e) => openMenu(e, playlistMenu(p))}
          >
            <Icon name="list" size={18} className="m-icon" />
            <span>{p.name}</span>
          </button>
        ))}
      </div>
      <ImportPill className="m-import" />
      <DownloadPill className="m-import" />
      <UpdateButton className="m-update" />
      <button className="m-profile" onClick={() => go({ name: 'settings' })}>
        <Avatar size={28} />
        <span>{account.username ?? 'Settings'}</span>
        <Icon name="gear" size={16} />
      </button>
    </aside>
  )
}

export function MusicTopPlayer(): JSX.Element {
  const p = usePlayer()
  const panel = useStore(panelStore)
  const nav = useStore(navStore)
  const t = p.current
  return (
    <header className="m-top">
      <div className="m-top-nav">
        <IconButton icon="back" label="Back" size={16} onClick={back} disabled={nav.index === 0} />
        <IconButton icon="forward" label="Forward" size={16} onClick={forward} disabled={nav.index >= nav.stack.length - 1} />
      </div>
      <Transport />
      <div className="m-lcd" onContextMenu={(e) => t && openMenu(e, trackMenu(t))}>
        {t ? (
          <>
            <button className="m-lcd-art" onClick={() => fullPlayerStore.set(true)} title="Open player">
              <TrackArt track={t} size={44} radius={0} />
            </button>
            <div className="m-lcd-text">
              <div className="m-lcd-title">{t.title}</div>
              <div className="m-lcd-sub">
                <button className="link" onClick={() => void goToArtist(t.artist)}>{t.artist}</button>
                {t.album ? ` — ${t.album}` : ''}
              </div>
              <Progress className="m-lcd-progress" />
            </div>
            <button className={`like-btn ${isLiked(t.id) ? 'on' : ''}`} aria-label="Like" onClick={() => toggleLike(t)}>
              <Icon name={isLiked(t.id) ? 'heartFill' : 'heart'} size={16} />
            </button>
          </>
        ) : (
          <div className="m-lcd-idle"><Logo size={22} /></div>
        )}
      </div>
      <div className="m-top-right">
        <Volume />
        <IconButton icon="lyrics" label="Lyrics" active={panel === 'lyrics'} size={18} onClick={() => togglePanel('lyrics')} />
        <IconButton icon="queue" label="Up next" active={panel === 'queue'} size={18} onClick={() => togglePanel('queue')} />
      </div>
    </header>
  )
}

/** Apple Music style: blurred artwork, big controls, lyrics on the right. */
export function FullPlayer(): JSX.Element | null {
  const open = useStore(fullPlayerStore)
  const p = usePlayer()
  const t = p.current
  useEffect(() => {
    if (!open) return
    const key = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') fullPlayerStore.set(false)
    }
    window.addEventListener('keydown', key)
    return () => window.removeEventListener('keydown', key)
  }, [open])
  if (!open || !t) return null
  const art = artwork(t, 800)
  return (
    <div className="full-player">
      <div className="fp-bg" style={{ backgroundImage: art ? `url("${art}")` : undefined }} />
      <div className="fp-shade" />
      <div className="fp-drag" />
      <IconButton icon="minimize" label="Close player" className="fp-close" onClick={() => fullPlayerStore.set(false)} />
      <div className="fp-body">
        <div className="fp-left">
          <TrackArt track={t} px={800} className="fp-art" radius={12} />
          <div className="fp-meta">
            <div>
              <div className="fp-title">{t.title}</div>
              <button className="fp-artist link" onClick={() => { fullPlayerStore.set(false); void goToArtist(t.artist) }}>{t.artist}</button>
            </div>
            <button className="icon-btn fp-more" aria-label="More" onClick={(e) => openMenu(e, trackMenu(t))}>
              <Icon name="more" size={18} />
            </button>
          </div>
          <Progress />
          <Transport size="large" />
          <Volume />
        </div>
        <div className="fp-right">
          <LyricsLines track={t} size="large" />
        </div>
      </div>
    </div>
  )
}

export function MusicSidePanel(): JSX.Element | null {
  const panel = useStore(panelStore)
  if (panel === 'none') return null
  return (
    <aside className="m-panel">
      <div className="side-head">
        <div className="seg">
          <button className={panel === 'lyrics' ? 'on' : ''} onClick={() => panelStore.set('lyrics')}>Lyrics</button>
          <button className={panel === 'queue' ? 'on' : ''} onClick={() => panelStore.set('queue')}>Up Next</button>
        </div>
        <IconButton icon="close" label="Close" size={16} onClick={() => panelStore.set('none')} />
      </div>
      {panel === 'lyrics' ? <MusicLyricsPanel /> : <QueuePanel />}
    </aside>
  )
}

function MusicLyricsPanel(): JSX.Element {
  const p = usePlayer()
  return (
    <div className="m-lyrics">
      <LyricsLines track={p.current} size="small" />
    </div>
  )
}

export function playAll(tracks: Parameters<typeof playList>[0], context: Parameters<typeof playList>[2], shuffle = false): void {
  playList(tracks, shuffle ? -1 : 0, context, { shuffle })
}

export { formatTime }
