import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import type { CSSProperties, JSX, ReactNode } from 'react'
import type { Playlist, Track } from '@shared/types'
import { Icon } from './icons'
import { DownloadMark, downloadMenuItem, useDownloadSets } from './downloads'
import { editPlaylist } from './views/editPlaylist'
import { openReplace } from './views/replace'
import { openCollab } from './views/collab'
import { openInvite } from './views/invite'
import type { SongPlace } from './views/replace'
import { addedText } from './sort'
import type { Sort, SortClick, SortKey } from './sort'
import {
  accountStore, dialogStore, drift, go, libraryStore, menuStore, openMenu, settingsStore, toast, toastStore, updateStore, useStore
} from './state'
import type { MenuItem } from './state'
import { addToQueue, playList, playNext, usePlayer } from './player'
import type { PlayContext } from './player'
import { artwork, formatTime, isPhoto, resized, seedTile, tile, ytLink } from './util'

// MARK: Pictures

export function Art({ src, seed, size, round, radius, className, style }: {
  src?: string | null; seed: string; size?: number; round?: boolean; radius?: number; className?: string; style?: CSSProperties
}): JSX.Element {
  const [failed, setFailed] = useState(false)
  useEffect(() => setFailed(false), [src])
  const s: CSSProperties = {
    width: size,
    height: size,
    borderRadius: round ? '50%' : radius,
    background: seedTile(seed),
    ...style
  }
  return (
    <div className={`art ${className ?? ''}`} style={s}>
      {src && !failed ? <img src={src} alt="" loading="lazy" draggable={false} onError={() => setFailed(true)} /> : <Icon name="note" size={size ? Math.max(14, size * 0.36) : 28} />}
    </div>
  )
}

export function TrackArt({ track, size, px, radius, className }: { track: Track; size?: number; px?: number; radius?: number; className?: string }): JSX.Element {
  return <Art src={artwork(track, px ?? Math.max(120, (size ?? 60) * 2))} seed={track.id} size={size} radius={radius} className={className} />
}

export function PlaylistCover({ p, size, radius, className }: { p: Playlist; size?: number; radius?: number; className?: string }): JSX.Element {
  const style: CSSProperties = { width: size, height: size, borderRadius: radius }
  if (isPhoto(p)) {
    return (
      <div className={`art ${className ?? ''}`} style={style}>
        <img src={`data:image/jpeg;base64,${p.cover}`} alt="" draggable={false} />
      </div>
    )
  }
  if (p.coverStyle === 'color' || !p.tracks.length) {
    return (
      <div className={`art cover-color ${className ?? ''}`} style={{ ...style, background: `linear-gradient(160deg, ${tile(p.colorIndex)}, ${tile(p.colorIndex + 4)})` }}>
        <Icon name="note" size={size ? Math.max(16, size * 0.4) : 40} />
      </div>
    )
  }
  const firsts: Track[] = []
  for (const t of p.tracks) {
    if (!firsts.some((x) => (x.artworkURL ?? x.id) === (t.artworkURL ?? t.id))) firsts.push(t)
    if (firsts.length === 4) break
  }
  if (firsts.length < 4 || (size ?? 200) < 48) return <TrackArt track={p.tracks[0]} size={size} radius={radius} className={className} px={size && size > 150 ? 400 : 200} />
  return (
    <div className={`art cover-grid ${className ?? ''}`} style={style}>
      {firsts.map((t) => (
        <img key={t.id} src={artwork(t, 200)} alt="" loading="lazy" draggable={false} />
      ))}
    </div>
  )
}

export function LikedCover({ size, radius }: { size?: number; radius?: number }): JSX.Element {
  return (
    <div className="art liked-cover" style={{ width: size, height: size, borderRadius: radius }}>
      <Icon name="heartFill" size={size ? Math.max(14, size * 0.4) : 40} />
    </div>
  )
}

export function Avatar({ size = 32 }: { size?: number }): JSX.Element {
  const account = useStore(accountStore)
  const letter = (account.username ?? 'Y').slice(0, 1).toUpperCase()
  return account.avatar ? (
    <img className="avatar" src={account.avatar} alt="" style={{ width: size, height: size }} />
  ) : (
    <span className="avatar avatar-letter" style={{ width: size, height: size, fontSize: size * 0.42 }}>{letter}</span>
  )
}

// MARK: Buttons

export function IconButton({ icon, label, onClick, active, size = 20, className, disabled }: {
  icon: string; label: string; onClick?: (e: React.MouseEvent<HTMLButtonElement>) => void; active?: boolean; size?: number; className?: string; disabled?: boolean
}): JSX.Element {
  return (
    <button className={`icon-btn ${active ? 'active' : ''} ${className ?? ''}`} title={label} aria-label={label} onClick={onClick} disabled={disabled}>
      <Icon name={icon} size={size} />
    </button>
  )
}

export function BigPlay({ onClick, playing, label }: { onClick: () => void; playing?: boolean; label?: string }): JSX.Element {
  return (
    <button className="big-play" onClick={onClick} aria-label={label ?? (playing ? 'Pause' : 'Play')} title={label ?? (playing ? 'Pause' : 'Play')}>
      <Icon name={playing ? 'pause' : 'play'} size={24} />
    </button>
  )
}

export function Spinner({ size = 18 }: { size?: number }): JSX.Element {
  return <span className="spinner" style={{ width: size, height: size }} aria-label="Loading" />
}

// MARK: Song menu

export function isLiked(id: string): boolean {
  return libraryStore.get().liked.some((t) => t.id === id)
}

export function toggleLike(t: Track): void {
  const liked = isLiked(t.id)
  void drift.setLiked(t, !liked)
  toast(liked ? 'Removed from Liked songs' : 'Added to Liked songs')
}

export function newPlaylist(tracks: Track[], open = true): void {
  dialogStore.set({
    kind: 'prompt',
    title: 'New playlist',
    value: '',
    placeholder: `My playlist #${libraryStore.get().playlists.length + 1}`,
    confirm: 'Create',
    onDone: async (name) => {
      const id = await drift.createPlaylist(name, tracks)
      if (tracks.length) toast(`Added to ${name.trim() || 'your new playlist'}`)
      if (open && !tracks.length) go({ name: 'playlist', id })
    }
  })
}

export function addToPlaylistItems(tracks: Track[]): MenuItem[] {
  const lists = libraryStore.get().playlists.filter((p) => !p.isAlbum)
  return [
    { label: 'New playlist…', icon: 'plus', action: () => newPlaylist(tracks, false) },
    ...(lists.length ? [{ label: '', separator: true }] : []),
    ...lists.map((p) => ({
      label: p.name,
      action: () => {
        const existing = new Set(p.tracks.map((t) => t.id))
        const fresh = tracks.filter((t) => !existing.has(t.id))
        if (!fresh.length) return toast(`Already in ${p.name}`)
        void drift.addToPlaylist(p.id, fresh)
        toast(`Added to ${p.name}`)
      }
    }))
  ]
}

export async function goToArtist(name: string): Promise<void> {
  const a = await drift.findArtist(name).catch(() => null)
  if (a) go({ name: 'artist', id: a.id, hint: a })
  else go({ name: 'search', q: name })
}

export async function goToAlbum(t: Track): Promise<void> {
  if (!t.album) return
  const a = await drift.findAlbum(t.album, t.artist).catch(() => null)
  if (a) go({ name: 'album', id: a.id, hint: a })
  else go({ name: 'search', q: `${t.album} ${t.artist}` })
}

export function trackMenu(t: Track, opts: { playlistId?: string; index?: number; place?: SongPlace; extra?: MenuItem[] } = {}): MenuItem[] {
  const liked = isLiked(t.id)
  const items: MenuItem[] = [
    { label: 'Play next', icon: 'queue', action: () => playNext([t]) },
    { label: 'Add to queue', icon: 'list', action: () => addToQueue([t]) },
    { label: 'Start radio', icon: 'radio', action: () => void startRadio(t) },
    { label: '', separator: true },
    { label: liked ? 'Remove from Liked songs' : 'Save to Liked songs', icon: liked ? 'heartFill' : 'heart', action: () => toggleLike(t) },
    { label: 'Add to playlist', icon: 'plus', submenu: addToPlaylistItems([t]) },
    ...(accountStore.get().linked ? [{ label: 'Invite to listen together…', icon: 'together', action: () => openInvite(t) }] : []),
    downloadMenuItem(t),
    ...(opts.playlistId && opts.index !== undefined
      ? [{ label: 'Remove from this playlist', icon: 'trash', action: () => void drift.removeFromPlaylist(opts.playlistId!, [opts.index!]) }]
      : []),
    ...(opts.place && opts.index !== undefined && !t.podcast
      ? [{ label: 'Replace with another version…', icon: 'swap', action: () => openReplace(t, opts.place!, opts.index!) }]
      : []),
    { label: '', separator: true },
    { label: 'Go to artist', icon: 'mic', action: () => void goToArtist(t.artist), disabled: !t.artist },
    { label: 'Go to album', icon: 'album', action: () => void goToAlbum(t), disabled: !t.album },
    { label: 'Song details', icon: 'info', action: () => go({ name: 'song', track: t }) },
    { label: 'Copy link', icon: 'link', action: () => void navigator.clipboard.writeText(ytLink(t)).then(() => toast('Link copied')) },
    ...(opts.extra ?? [])
  ]
  return items
}

export async function startRadio(t: Track): Promise<void> {
  toast(`Starting radio from “${t.title}”…`)
  const more = await drift.radio(t.id).catch(() => [])
  playList([t, ...more], 0, { kind: 'radio', name: `${t.title} radio` }, { shuffle: false })
}

// MARK: Song lists

export interface TrackListProps {
  tracks: Track[]
  context: PlayContext
  /** Position in the full list for each shown song (when filtered). */
  indexes?: number[]
  playlistId?: string
  showAlbum?: boolean
  showArt?: boolean
  numbered?: boolean
  compact?: boolean
  emptyText?: string
  /** A "Date added" column (playlists and Liked songs). */
  showAdded?: boolean
  /** Collaborative playlists: profile ID → name, shown with the date (who added each song). */
  addedByNames?: Record<string, string>
  /** Clickable column headers (playlists and Liked songs). */
  sort?: Sort
  onSort?: (key: SortClick) => void
}

/** One button for Title and Artist: Title A→Z, Title Z→A, Artist A→Z, Artist Z→A, then your order. */
function NameSortButton({ sort, onSort }: { sort?: Sort; onSort: (key: SortClick) => void }): JSX.Element {
  const on = sort?.key === 'title' || sort?.key === 'artist'
  const label = sort?.key === 'artist' ? 'Artist' : 'Title'
  const next = !on ? 'Title A to Z' : sort.key === 'title' ? (sort.dir === 'asc' ? 'Title Z to A' : 'Artist A to Z') : sort.dir === 'asc' ? 'Artist Z to A' : 'your order'
  return (
    <button className={`sort-head ${on ? 'on' : ''}`} onClick={() => onSort('name')} title={`Click to sort: ${next}`}>
      {label}
      {on && <span className="sort-dir">{sort.dir === 'asc' ? 'A–Z' : 'Z–A'}</span>}
      {on && <Icon name={sort.dir === 'asc' ? 'chevronUp' : 'chevronDown'} size={12} />}
    </button>
  )
}

/** A column header that sorts the list when clicked. */
function SortHeader({ k, label, sort, onSort, className }: { k: SortKey; label: ReactNode; sort?: Sort; onSort?: (key: SortClick) => void; className?: string }): JSX.Element {
  if (!onSort) return <span className={className}>{label}</span>
  const on = sort?.key === k
  const hint =
    k === 'added'
      ? !on ? 'Sort: newest first' : sort.dir === 'desc' ? 'Sort: oldest first' : 'Back to your order'
      : !on ? 'Sort: A to Z' : sort.dir === 'asc' ? 'Sort: Z to A' : 'Back to your order'
  return (
    <button className={`sort-head ${on ? 'on' : ''} ${className ?? ''}`} onClick={() => onSort(k)} title={hint}>
      {label}
      {on && <Icon name={sort.dir === 'asc' ? 'chevronUp' : 'chevronDown'} size={12} />}
    </button>
  )
}

export function TrackList(props: TrackListProps): JSX.Element {
  const { tracks, context, indexes, playlistId, showAlbum = true, showArt = true, numbered = true } = props
  const player = usePlayer()
  const style = useStore(settingsStore).style
  const liked = useStore(libraryStore).liked
  const dl = useDownloadSets()
  // Drag to reorder (in your playlists, when the list isn't filtered).
  const reorder = !!playlistId && !indexes
  const [drag, setDrag] = useState<{ from: number; over: number } | null>(null)
  const likedIds = new Set(liked.map((t) => t.id))
  const full = (i: number): number => indexes?.[i] ?? i
  // The short list (search results) always shows the artist under the title.
  const music = style === 'music' && !props.compact

  if (!tracks.length && props.emptyText) return <div className="empty">{props.emptyText}</div>

  const play = (i: number): void => {
    if (context.kind === 'search') return playList([tracks[i]], 0, { kind: 'song', name: tracks[i].title })
    playList(tracks, i, context)
  }

  return (
    <div className={`tracks ${music ? 'tracks-music' : 'tracks-drift'} ${showAlbum ? '' : 'no-album'} ${props.showAdded ? 'with-added' : ''} ${props.compact ? 'compact' : ''}`} role="list">
      <div className="track-head" aria-hidden={props.onSort ? undefined : 'true'}>
        <span className="c-num">{numbered && !music ? '#' : ''}</span>
        {music ? (
          <SortHeader k="title" label="Song" sort={props.sort} onSort={props.onSort} className="c-title" />
        ) : (
          <span className="c-title head-pair">
            {props.onSort ? <NameSortButton sort={props.sort} onSort={props.onSort} /> : <span>Title</span>}
            {props.onSort && <span className="head-dot">·</span>}
            {props.onSort && <SortHeader k="album" label="Album" sort={props.sort} onSort={props.onSort} />}
          </span>
        )}
        {music && <SortHeader k="artist" label="Artist" sort={props.sort} onSort={props.onSort} className="c-artist" />}
        {showAlbum && <SortHeader k="album" label="Album" sort={props.sort} onSort={props.onSort} className="c-album" />}
        {props.showAdded && <SortHeader k="added" label="Date added" sort={props.sort} onSort={props.onSort} className="c-added" />}
        <span className="c-like" />
        <span className="c-time">{music ? 'Time' : <Icon name="clock" size={16} />}</span>
        <span className="c-more" />
      </div>
      {tracks.map((t, i) => {
        const current = player.current?.id === t.id
        const menu = (e: React.MouseEvent): void =>
          openMenu(e, trackMenu(t, {
            playlistId,
            index: playlistId || context.kind === 'liked' ? full(i) : undefined,
            place: playlistId ? { playlistId } : context.kind === 'liked' ? { liked: true } : undefined
          }))
        return (
          <div
            key={`${t.id}-${i}`}
            className={`track-row ${current ? 'current' : ''}`}
            role="listitem"
            tabIndex={0}
            onDoubleClick={() => play(i)}
            onKeyDown={(e) => e.key === 'Enter' && play(i)}
            onContextMenu={menu}
            draggable={reorder}
            onDragStart={reorder ? (e) => {
              e.dataTransfer.effectAllowed = 'move'
              setDrag({ from: i, over: i })
            } : undefined}
            onDragOver={reorder && drag ? (e) => {
              e.preventDefault()
              const r = e.currentTarget.getBoundingClientRect()
              const over = e.clientY > r.top + r.height / 2 ? i + 1 : i
              if (over !== drag.over) setDrag({ ...drag, over })
            } : undefined}
            onDrop={reorder && drag ? (e) => {
              e.preventDefault()
              const to = drag.over > drag.from ? drag.over - 1 : drag.over
              if (to !== drag.from) void drift.movePlaylistTrack(playlistId!, drag.from, to)
              setDrag(null)
            } : undefined}
            onDragEnd={() => setDrag(null)}
            data-drop={drag && drag.over === i && drag.over !== drag.from && drag.over !== drag.from + 1 ? 'before' : drag && i === tracks.length - 1 && drag.over === tracks.length && drag.from !== i ? 'after' : undefined}
          >
            <span className="c-num">
              <span className="num-text">
                {current && player.playing ? <EqualizerIcon /> : numbered ? (props.sort ? i + 1 : full(i) + 1) : ''}
              </span>
              <button className="row-play" aria-label={`Play ${t.title}`} onClick={() => play(i)}>
                <Icon name="play" size={14} />
              </button>
            </span>
            <span className="c-title">
              {showArt && (
                <span className="row-art" onClick={props.compact ? () => play(i) : undefined}>
                  <TrackArt track={t} size={music ? 32 : 40} radius={4} />
                </span>
              )}
              <span className="title-text">
                <span className="t-title">
                  {t.title}
                  {t.explicit && <span className="explicit-mark" title="Explicit" aria-label="Explicit">E</span>}
                  {t.upload && <span className="badge">UPLOAD</span>}
                  <DownloadMark id={t.id} sets={dl} />
                </span>
                {!music && (
                  <button className="t-artist link" onClick={() => void goToArtist(t.artist)}>{t.artist}</button>
                )}
              </span>
            </span>
            {music && (
              <span className="c-artist">
                <button className="link" onClick={() => void goToArtist(t.artist)}>{t.artist}</button>
              </span>
            )}
            {showAlbum && (
              <span className="c-album">
                {t.album ? <button className="link" onClick={() => void goToAlbum(t)}>{t.album}</button> : ''}
              </span>
            )}
            {props.showAdded && (
              <span className="c-added">
                {t.addedBy && props.addedByNames?.[t.addedBy] ? <b className="added-by">{props.addedByNames[t.addedBy]}</b> : null}
                {addedText(t.added)}
              </span>
            )}
            <span className="c-like">
              <button
                className={`like-btn ${likedIds.has(t.id) ? 'on' : ''}`}
                aria-label={likedIds.has(t.id) ? 'Remove from Liked songs' : 'Save to Liked songs'}
                onClick={() => toggleLike(t)}
              >
                <Icon name={likedIds.has(t.id) ? 'heartFill' : 'heart'} size={16} />
              </button>
            </span>
            <span className="c-time">{t.duration ? formatTime(t.duration) : ''}</span>
            <span className="c-more">
              <button className="more-btn" aria-label="More" onClick={menu}>
                <Icon name="more" size={16} />
              </button>
            </span>
          </div>
        )
      })}
    </div>
  )
}

export function EqualizerIcon(): JSX.Element {
  return (
    <span className="eq" aria-label="Playing">
      <i />
      <i />
      <i />
    </span>
  )
}

// MARK: Cards and rows of cards

export function Card({ title, subtitle, image, round, onOpen, onPlay, onContextMenu }: {
  title: string; subtitle?: string; image: ReactNode; round?: boolean; onOpen: () => void; onPlay?: () => void; onContextMenu?: (e: React.MouseEvent) => void
}): JSX.Element {
  return (
    <div className={`card ${round ? 'round' : ''}`} onClick={onOpen} onContextMenu={onContextMenu} role="button" tabIndex={0} onKeyDown={(e) => e.key === 'Enter' && onOpen()}>
      <div className="card-art">
        {image}
        {onPlay && (
          <button
            className="card-play"
            aria-label={`Play ${title}`}
            onClick={(e) => {
              e.stopPropagation()
              onPlay()
            }}
          >
            <Icon name="play" size={20} />
          </button>
        )}
      </div>
      <div className="card-title">{title}</div>
      {subtitle && <div className="card-sub">{subtitle}</div>}
    </div>
  )
}

export function Shelf({ title, children, action }: { title: string; children: ReactNode; action?: ReactNode }): JSX.Element {
  return (
    <section className="shelf">
      <div className="shelf-head">
        <h2>{title}</h2>
        {action}
      </div>
      <div className="shelf-row">{children}</div>
    </section>
  )
}

// MARK: Pop-ups

export function ContextMenu(): JSX.Element | null {
  const menu = useStore(menuStore)
  const ref = useRef<HTMLDivElement>(null)
  const [pos, setPos] = useState<{ x: number; y: number }>({ x: 0, y: 0 })
  const [open, setOpen] = useState<number | null>(null)
  const [flip, setFlip] = useState({ x: false, y: false })

  useLayoutEffect(() => {
    if (!menu || !ref.current) return
    const r = ref.current.getBoundingClientRect()
    setPos({
      x: Math.max(8, Math.min(menu.x, window.innerWidth - r.width - 8)),
      y: Math.max(8, Math.min(menu.y, window.innerHeight - r.height - 8))
    })
    setOpen(null)
  }, [menu])

  useEffect(() => {
    if (!menu) return
    const close = (): void => menuStore.set(null)
    const key = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') close()
    }
    window.addEventListener('blur', close)
    window.addEventListener('resize', close)
    window.addEventListener('keydown', key)
    return () => {
      window.removeEventListener('blur', close)
      window.removeEventListener('resize', close)
      window.removeEventListener('keydown', key)
    }
  }, [menu])

  if (!menu) return null
  const run = (item: MenuItem): void => {
    if (item.disabled || item.submenu) return
    menuStore.set(null)
    item.action?.()
  }
  return (
    <div className="menu-layer" onMouseDown={() => menuStore.set(null)} onContextMenu={(e) => { e.preventDefault(); menuStore.set(null) }}>
      <div className="menu" ref={ref} style={{ left: pos.x, top: pos.y }} onMouseDown={(e) => e.stopPropagation()} role="menu">
        {menu.items.map((item, i) =>
          item.separator ? (
            <div key={i} className="menu-sep" />
          ) : (
            <div
              key={i}
              className={`menu-item ${item.danger ? 'danger' : ''} ${item.disabled ? 'disabled' : ''}`}
              role="menuitem"
              onMouseEnter={(e) => {
                setOpen(item.submenu ? i : null)
                if (item.submenu) {
                  const r = e.currentTarget.getBoundingClientRect()
                  setFlip({ x: r.right + 260 > window.innerWidth, y: r.top > window.innerHeight * 0.55 })
                }
              }}
              onClick={() => (item.submenu ? setOpen(i) : run(item))}
            >
              <span className="menu-icon">{item.checked ? <Icon name="check" size={16} /> : item.icon ? <Icon name={item.icon} size={16} /> : null}</span>
              <span className="menu-label">{item.label}</span>
              {item.submenu && <Icon name="forward" size={14} />}
              {item.submenu && open === i && (
                <div className={`menu submenu ${flip.x ? 'flip-x' : ''} ${flip.y ? 'flip-y' : ''}`}>
                  {item.submenu.map((sub, j) =>
                    sub.separator ? (
                      <div key={j} className="menu-sep" />
                    ) : (
                      <div key={j} className="menu-item" role="menuitem" onClick={(e) => { e.stopPropagation(); run(sub) }}>
                        <span className="menu-icon">{sub.icon ? <Icon name={sub.icon} size={16} /> : null}</span>
                        <span className="menu-label">{sub.label}</span>
                      </div>
                    )
                  )}
                </div>
              )}
            </div>
          )
        )}
      </div>
    </div>
  )
}

export function DialogHost(): JSX.Element | null {
  const dialog = useStore(dialogStore)
  const [value, setValue] = useState('')
  const input = useRef<HTMLInputElement>(null)
  useEffect(() => {
    if (dialog?.kind === 'prompt') {
      setValue(dialog.value)
      setTimeout(() => input.current?.select(), 0)
    }
  }, [dialog])
  if (!dialog) return null
  const close = (): void => dialogStore.set(null)
  const done = (): void => {
    close()
    if (dialog.kind === 'prompt') dialog.onDone(value)
    else dialog.onDone()
  }
  return (
    <div className="dialog-layer" onMouseDown={close}>
      <form
        className="dialog"
        onMouseDown={(e) => e.stopPropagation()}
        onSubmit={(e) => {
          e.preventDefault()
          done()
        }}
        onKeyDown={(e) => e.key === 'Escape' && close()}
      >
        <h3>{dialog.title}</h3>
        {dialog.kind === 'prompt' ? (
          <input ref={input} className="field" value={value} placeholder={dialog.placeholder} onChange={(e) => setValue(e.target.value)} autoFocus />
        ) : (
          <p>{dialog.message}</p>
        )}
        <div className="dialog-buttons">
          <button type="button" className="btn ghost" onClick={close}>Cancel</button>
          <button type="submit" className={`btn ${dialog.kind === 'confirm' && dialog.danger ? 'danger' : 'primary'}`} autoFocus={dialog.kind === 'confirm'}>
            {dialog.confirm}
          </button>
        </div>
      </form>
    </div>
  )
}

export function Toast(): JSX.Element | null {
  const t = useStore(toastStore)
  if (!t) return null
  return (
    <div className="toast" key={t.id} role="status">
      {t.text}
    </div>
  )
}

export function playlistMenu(p: Playlist): MenuItem[] {
  return [
    { label: 'Play', icon: 'play', action: () => playList(p.tracks, 0, { kind: 'playlist', id: p.id, name: p.name }, { shuffle: false }) },
    { label: 'Shuffle', icon: 'shuffle', action: () => playList(p.tracks, -1, { kind: 'playlist', id: p.id, name: p.name }, { shuffle: true }) },
    { label: 'Add to queue', icon: 'list', action: () => addToQueue(p.tracks) },
    { label: '', separator: true },
    { label: 'Edit details…', icon: 'edit', action: () => editPlaylist(p.id) },
    ...(p.isAlbum
      ? []
      : [{ label: p.collab ? 'Collaborators…' : 'Make collaborative…', icon: 'person', action: () => openCollab(p.id) }]),
    ...(p.collab && p.collab.owner !== accountStore.get().uid
      ? [{
          label: 'Leave playlist',
          icon: 'trash',
          danger: true,
          action: () =>
            dialogStore.set({
              kind: 'confirm',
              title: `Leave ${p.name}?`,
              message: 'It goes from your library. The others keep it.',
              confirm: 'Leave',
              danger: true,
              onDone: () => {
                void drift.collabLeave(p.id)
                go({ name: 'home' })
              }
            })
        }]
      : [{
      label: p.isAlbum ? 'Remove from library' : 'Delete playlist',
      icon: 'trash',
      danger: true,
      action: () =>
        dialogStore.set({
          kind: 'confirm',
          title: p.isAlbum ? `Remove ${p.name}?` : `Delete ${p.name}?`,
          message: 'It’s also removed from your other devices.',
          confirm: p.isAlbum ? 'Remove' : 'Delete',
          danger: true,
          onDone: () => {
            // Shared: stop sharing first (it goes from everyone else's library too).
            void (p.collab ? drift.collabStop(p.id) : Promise.resolve()).finally(() => void drift.deletePlaylist(p.id))
            go({ name: 'home' })
          }
        })
    }])
  ]
}

export { resized }

/** Shown when a new version is ready (or, on a Mac, out to download). */
export function UpdateButton({ className }: { className?: string }): JSX.Element | null {
  const u = useStore(updateStore)
  if (u.phase === 'ready') {
    return (
      <button className={`update-btn ${className ?? ''}`} onClick={() => void drift.installUpdate()} title={`Drift ${u.version} is ready`}>
        <Icon name="sync" size={14} /> Restart to update
      </button>
    )
  }
  if (u.phase === 'available' && u.url) {
    return (
      <button className={`update-btn ${className ?? ''}`} onClick={() => void drift.openExternal(u.url!)} title={`Drift ${u.version} is out`}>
        <Icon name="external" size={14} /> Drift {u.version} is out
      </button>
    )
  }
  return null
}
