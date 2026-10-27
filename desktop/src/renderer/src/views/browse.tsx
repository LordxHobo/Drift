// Home, search, artist and album pages.
import { useEffect, useRef, useState } from 'react'
import type { JSX } from 'react'
import type { AlbumPage as Album, AlbumRef, ArtistPage as Artist, ArtistRef, SearchResults, Track } from '@shared/types'
import { Icon } from '../icons'
import { drift, go, libraryStore, openMenu, readLocal, toast, useStore, writeLocal } from '../state'
import { playList, usePlayer } from '../player'
import {
  Art, BigPlay, Card, LikedCover, PlaylistCover, Shelf, TrackArt, TrackList, addToPlaylistItems, playlistMenu, trackMenu
} from '../ui'
import { greeting, plural, resized, artwork, formatTotal } from '../util'
import { openImport } from './import'
import { CollectionHeader, Failed, Loading, cleanError, useMusic } from './common'

// MARK: Home

export function HomePage(): JSX.Element {
  const lib = useStore(libraryStore)
  const music = useMusic()
  const releases = lib.artists.flatMap((a) => a.newReleases).sort((a, b) => b.foundAt - a.foundAt)
  const quick = lib.playlists.slice(0, lib.liked.length ? 5 : 6)

  const albumCard = (a: AlbumRef, artistName: string): JSX.Element => (
    <Card
      key={a.id}
      title={a.title}
      subtitle={artistName}
      image={<Art src={resized(a.thumbnail, 400)} seed={a.id} radius={music ? 8 : 6} />}
      onOpen={() => go({ name: 'album', id: a.id, hint: a })}
    />
  )
  const songCard = (t: Track): JSX.Element => (
    <Card
      key={t.id}
      title={t.title}
      subtitle={t.artist}
      image={<TrackArt track={t} px={400} radius={music ? 8 : 6} />}
      onOpen={() => playList([t], 0, { kind: 'song', name: t.title })}
      onPlay={() => playList([t], 0, { kind: 'song', name: t.title })}
      onContextMenu={(e) => openMenu(e, trackMenu(t))}
    />
  )

  const empty = !lib.liked.length && !lib.playlists.length && !lib.recent.length

  return (
    <div className="page home">
      <h1 className="page-title">{music ? 'Home' : greeting()}</h1>

      {empty && (
        <div className="welcome">
          <h2>Welcome to Drift</h2>
          <p>Search for any song, link your phone in Settings to bring your playlists, liked songs and followed artists over, or import a playlist from Spotify.</p>
          <div className="welcome-buttons">
            <button className="btn primary" onClick={() => go({ name: 'search' })}>Search</button>
            <button className="btn" onClick={() => go({ name: 'settings' })}>Link your phone</button>
            <button className="btn" onClick={openImport}>Import from Spotify</button>
          </div>
        </div>
      )}

      {!music && (lib.liked.length > 0 || quick.length > 0) && (
        <div className="quick-grid">
          {lib.liked.length > 0 && (
            <button className="quick" onClick={() => go({ name: 'liked' })} onDoubleClick={() => playList(lib.liked, 0, { kind: 'liked', id: 'liked', name: 'Liked songs' })}>
              <LikedCover size={56} />
              <span>Liked songs</span>
            </button>
          )}
          {quick.map((p) => (
            <button key={p.id} className="quick" onClick={() => go({ name: 'playlist', id: p.id })} onContextMenu={(e) => openMenu(e, playlistMenu(p))}>
              <PlaylistCover p={p} size={56} />
              <span>{p.name}</span>
            </button>
          ))}
        </div>
      )}

      {lib.recent.length > 0 && (
        <Shelf title={music ? 'Recently Played' : 'Jump back in'}>{lib.recent.slice(0, 12).map(songCard)}</Shelf>
      )}

      {releases.length > 0 && (
        <Shelf title={music ? 'New Releases' : 'New releases'}>{releases.slice(0, 12).map((r) => albumCard(r.album, r.artistName))}</Shelf>
      )}

      {music && lib.playlists.length > 0 && (
        <Shelf title="Playlists" action={<button className="link see-all" onClick={() => go({ name: 'collection', kind: 'playlists' })}>See All</button>}>
          {lib.playlists.filter((p) => !p.isAlbum).slice(0, 12).map((p) => (
            <Card
              key={p.id}
              title={p.name}
              subtitle={plural(p.tracks.length, 'song')}
              image={<PlaylistCover p={p} radius={8} />}
              onOpen={() => go({ name: 'playlist', id: p.id })}
              onPlay={() => playList(p.tracks, 0, { kind: 'playlist', id: p.id, name: p.name })}
            />
          ))}
        </Shelf>
      )}

      {lib.artists.length > 0 && (
        <Shelf title={music ? 'Artists You Follow' : 'Artists you follow'}>
          {lib.artists.slice(0, 12).map((a) => (
            <Card
              key={a.artist.id}
              round
              title={a.artist.name}
              subtitle="Artist"
              image={<Art src={resized(a.artist.thumbnail, 400)} seed={a.artist.id} round />}
              onOpen={() => go({ name: 'artist', id: a.artist.id, hint: a.artist })}
            />
          ))}
        </Shelf>
      )}
    </div>
  )
}

// MARK: Search

export function SearchBox({ q }: { q: string }): JSX.Element {
  const [value, setValue] = useState(q)
  const input = useRef<HTMLInputElement>(null)
  useEffect(() => setValue(q), [q])
  useEffect(() => {
    input.current?.focus()
    const focus = (): void => input.current?.focus()
    window.addEventListener('drift:focus-search', focus)
    return () => window.removeEventListener('drift:focus-search', focus)
  }, [])
  return (
    <label className="search-box">
      <Icon name="search" size={18} />
      <input
        ref={input}
        value={value}
        placeholder="What do you want to play?"
        onChange={(e) => {
          setValue(e.target.value)
          go({ name: 'search', q: e.target.value })
        }}
        onKeyDown={(e) => e.key === 'Escape' && (setValue(''), go({ name: 'search', q: '' }))}
      />
      {value && (
        <button aria-label="Clear" onClick={() => (setValue(''), go({ name: 'search', q: '' }))}>
          <Icon name="close" size={14} />
        </button>
      )}
    </label>
  )
}

function rememberSearch(q: string): void {
  const s = q.trim()
  if (!s) return
  const list = readLocal<string[]>('searchHistory', []).filter((x) => x.toLowerCase() !== s.toLowerCase())
  writeLocal('searchHistory', [s, ...list].slice(0, 20))
}

export function SearchPage({ q }: { q: string }): JSX.Element {
  const music = useMusic()
  const [results, setResults] = useState<{ q: string; data?: SearchResults; error?: string } | null>(null)
  const [suggestions, setSuggestions] = useState<string[]>([])
  const [history, setHistory] = useState(() => readLocal<string[]>('searchHistory', []))
  const query = q.trim()

  useEffect(() => {
    if (!query) {
      setResults(null)
      return
    }
    let alive = true
    const timer = window.setTimeout(() => {
      drift.suggestions(query).then((s) => alive && setSuggestions(s)).catch(() => undefined)
      drift
        .search(query)
        .then((data) => {
          if (!alive) return
          setResults({ q: query, data })
          rememberSearch(query)
        })
        .catch((e) => alive && setResults({ q: query, error: cleanError(e) }))
    }, 350)
    return () => {
      alive = false
      clearTimeout(timer)
    }
  }, [query])

  if (!query) {
    return (
      <div className="page">
        {music && <h1 className="page-title">Search</h1>}
        {history.length > 0 ? (
          <section>
            <div className="shelf-head">
              <h2>Recent searches</h2>
              <button className="btn outline small" onClick={() => (writeLocal('searchHistory', []), setHistory([]))}>Clear all</button>
            </div>
            <div className="history">
              {history.map((h) => (
                <div key={h} className="history-row">
                  <button className="history-text" onClick={() => go({ name: 'search', q: h })}>
                    <Icon name="clock" size={16} />
                    {h}
                  </button>
                  <button
                    className="icon-btn"
                    aria-label={`Remove ${h}`}
                    onClick={() => {
                      const next = history.filter((x) => x !== h)
                      writeLocal('searchHistory', next)
                      setHistory(next)
                    }}
                  >
                    <Icon name="close" size={14} />
                  </button>
                </div>
              ))}
            </div>
          </section>
        ) : (
          <div className="empty">Search for songs, artists and albums on YouTube Music.</div>
        )}
      </div>
    )
  }

  const data = results?.q === query ? results.data : undefined
  const error = results?.q === query ? results.error : undefined
  return (
    <div className="page search-page">
      {suggestions.length > 0 && (
        <div className="suggestions">
          {suggestions.slice(0, 6).map((s) => (
            <button key={s} className="chip" onClick={() => go({ name: 'search', q: s })}>{s}</button>
          ))}
        </div>
      )}
      {error ? <Failed message={`Search didn’t work: ${error}`} /> : !data ? <Loading /> : <SearchResultsView data={data} q={query} />}
    </div>
  )
}

function SearchResultsView({ data, q }: { data: SearchResults; q: string }): JSX.Element {
  const music = useMusic()
  const norm = (s: string): string => s.toLowerCase().replace(/[^a-z0-9]/g, '')
  const topArtist = data.artists.find((a) => norm(a.name) === norm(q)) ?? null
  const topSong = data.songs[0]
  if (!data.songs.length && !data.artists.length && !data.albums.length && !data.videos.length) {
    return <div className="empty">Nothing found for “{q}”.</div>
  }
  return (
    <>
      <div className="search-top">
        {(topArtist || topSong) && (
          <section className="top-result">
            <h2>Top result</h2>
            {topArtist ? (
              <div className="top-card" onClick={() => go({ name: 'artist', id: topArtist.id, hint: topArtist })} role="button" tabIndex={0}>
                <Art src={resized(topArtist.thumbnail, 300)} seed={topArtist.id} size={96} round />
                <div className="top-name">{topArtist.name}</div>
                <div className="top-kind">Artist</div>
              </div>
            ) : (
              <div className="top-card" onDoubleClick={() => playList([topSong], 0, { kind: 'song', name: topSong.title })} onContextMenu={(e) => openMenu(e, trackMenu(topSong))}>
                <TrackArt track={topSong} size={96} radius={6} />
                <div className="top-name">{topSong.title}</div>
                <div className="top-kind">Song · {topSong.artist}</div>
                <span className="top-play"><BigPlay onClick={() => playList([topSong], 0, { kind: 'song', name: topSong.title })} /></span>
              </div>
            )}
          </section>
        )}
        {data.songs.length > 0 && (
          <section className="top-songs">
            <h2>Songs</h2>
            <TrackList tracks={data.songs.slice(0, 5)} context={{ kind: 'search', name: q }} showAlbum={false} numbered={false} compact />
          </section>
        )}
      </div>

      {data.artists.length > 0 && (
        <Shelf title="Artists">
          {data.artists.slice(0, 10).map((a: ArtistRef) => (
            <Card key={a.id} round title={a.name} subtitle="Artist" image={<Art src={resized(a.thumbnail, 400)} seed={a.id} round />} onOpen={() => go({ name: 'artist', id: a.id, hint: a })} />
          ))}
        </Shelf>
      )}
      {data.albums.length > 0 && (
        <Shelf title="Albums">
          {data.albums.slice(0, 10).map((a) => (
            <Card key={a.id} title={a.title} subtitle={a.subtitle} image={<Art src={resized(a.thumbnail, 400)} seed={a.id} radius={music ? 8 : 6} />} onOpen={() => go({ name: 'album', id: a.id, hint: a })} />
          ))}
        </Shelf>
      )}
      {data.songs.length > 5 && (
        <section className="section">
          <h2>More songs</h2>
          <TrackList tracks={data.songs.slice(5)} context={{ kind: 'search', name: q }} numbered={false} />
        </section>
      )}
      {data.videos.length > 0 && (
        <section className="section">
          <h2>Videos</h2>
          <TrackList tracks={data.videos.slice(0, 10)} context={{ kind: 'search', name: q }} showAlbum={false} numbered={false} />
        </section>
      )}
    </>
  )
}

// MARK: Artist

export function ArtistPage({ id, hint }: { id: string; hint?: ArtistRef }): JSX.Element {
  const lib = useStore(libraryStore)
  const music = useMusic()
  const player = usePlayer()
  const [page, setPage] = useState<{ id: string; data?: Artist; error?: string }>({ id })
  const [showAll, setShowAll] = useState(false)
  const [more, setMore] = useState<{ kind: 'albums' | 'singles'; list: AlbumRef[] } | null>(null)
  const load = (): void => {
    setPage({ id })
    drift.artist(id, hint?.name).then((data) => setPage({ id, data })).catch((e) => setPage({ id, error: cleanError(e) }))
  }
  useEffect(() => {
    setShowAll(false)
    setMore(null)
    load()
  }, [id])

  const following = lib.artists.some((a) => a.artist.id === id)
  const data = page.id === id ? page.data : undefined
  const name = data?.name ?? hint?.name ?? ''
  const image = resized(data?.thumbnail ?? hint?.thumbnail, 1200)
  const context = { kind: 'artist' as const, id, name }

  const followButton = (
    <button
      className={`btn outline follow ${following ? 'on' : ''}`}
      onClick={() => {
        if (following) void drift.unfollow(id)
        else {
          void drift.follow({ id, name, thumbnail: data?.thumbnail ?? hint?.thumbnail ?? null }, data ?? null)
          toast(`Following ${name}. New releases show up on Home.`)
        }
      }}
    >
      {following ? 'Following' : 'Follow'}
    </button>
  )

  const shelf = (title: string, list: AlbumRef[], kind: 'albums' | 'singles', moreRef?: Artist['albumsMore']): JSX.Element | null =>
    list.length ? (
      <Shelf
        title={title}
        action={
          moreRef ? (
            <button
              className="link see-all"
              onClick={() =>
                drift.discography(moreRef).then((all) => setMore({ kind, list: all })).catch(() => toast('Couldn’t load the full list'))
              }
            >
              {music ? 'See All' : 'Show all'}
            </button>
          ) : undefined
        }
      >
        {list.map((a) => (
          <Card key={a.id} title={a.title} subtitle={a.subtitle} image={<Art src={resized(a.thumbnail, 400)} seed={a.id} radius={music ? 8 : 6} />} onOpen={() => go({ name: 'album', id: a.id, hint: a })} />
        ))}
      </Shelf>
    ) : null

  return (
    <div className="page artist-page">
      <div className={`artist-hero ${image ? '' : 'no-image'}`} style={{ backgroundImage: image ? `url("${image}")` : undefined }}>
        <div className="artist-hero-shade" />
        <div className="artist-hero-text">
          <h1>{name}</h1>
          {data?.subtitle && <div className="artist-sub">{data.subtitle}</div>}
        </div>
      </div>
      <div className={music ? 'm-artist-actions' : 'd-actions'}>
        {music ? (
          <button className="pill" onClick={() => data && playList(data.topSongs, 0, context, { shuffle: false })} disabled={!data?.topSongs.length}>
            <Icon name="play" size={14} /> Play
          </button>
        ) : (
          <BigPlay onClick={() => data && playList(data.topSongs, 0, context, { shuffle: false })} playing={player.context?.kind === 'artist' && player.context.id === id && player.playing} />
        )}
        {music && (
          <button className="pill" onClick={() => data && playList(data.topSongs, -1, context, { shuffle: true })} disabled={!data?.topSongs.length}>
            <Icon name="shuffle" size={14} /> Shuffle
          </button>
        )}
        {followButton}
      </div>
      {page.error && page.id === id ? (
        <Failed message={`Couldn’t load this artist: ${page.error}`} retry={load} />
      ) : !data ? (
        <Loading />
      ) : more ? (
        <section className="section">
          <div className="shelf-head">
            <h2>{more.kind === 'albums' ? 'Albums' : 'Singles and EPs'}</h2>
            <button className="link see-all" onClick={() => setMore(null)}>Back to {name}</button>
          </div>
          <div className="grid">
            {more.list.map((a) => (
              <Card key={a.id} title={a.title} subtitle={a.subtitle} image={<Art src={resized(a.thumbnail, 400)} seed={a.id} radius={music ? 8 : 6} />} onOpen={() => go({ name: 'album', id: a.id, hint: a })} />
            ))}
          </div>
        </section>
      ) : (
        <>
          {data.topSongs.length > 0 && (
            <section className="section">
              <h2>{music ? 'Top Songs' : 'Popular'}</h2>
              <TrackList tracks={showAll ? data.topSongs : data.topSongs.slice(0, 5)} context={context} showAlbum={!music} />
              {data.topSongs.length > 5 && (
                <button className="link see-more" onClick={() => setShowAll(!showAll)}>{showAll ? 'Show less' : 'See more'}</button>
              )}
            </section>
          )}
          {shelf('Albums', data.albums, 'albums', data.albumsMore)}
          {shelf(music ? 'Singles & EPs' : 'Singles and EPs', data.singles, 'singles', data.singlesMore)}
        </>
      )}
    </div>
  )
}

// MARK: Album

export function AlbumPage({ id, hint }: { id: string; hint?: AlbumRef }): JSX.Element {
  const lib = useStore(libraryStore)
  const music = useMusic()
  const [page, setPage] = useState<{ id: string; data?: Album; error?: string }>({ id })
  const load = (): void => {
    setPage({ id })
    drift.album(id).then((data) => setPage({ id, data })).catch((e) => setPage({ id, error: cleanError(e) }))
  }
  useEffect(load, [id])
  const data = page.id === id ? page.data : undefined
  const saved = data ? lib.playlists.find((p) => p.isAlbum && p.name === data.title && p.albumArtist === data.artist) : undefined
  const title = data?.title ?? hint?.title ?? ''
  const thumb = resized(data?.thumbnail ?? hint?.thumbnail, 600)

  if (page.error && page.id === id) return <div className="page"><Failed message={`Couldn’t load this album: ${page.error}`} retry={load} /></div>
  return (
    <div className="page">
      <CollectionHeader
        cover={<Art src={thumb} seed={id} size={music ? 230 : 200} radius={music ? 10 : 6} />}
        coverURL={resized(data?.thumbnail ?? hint?.thumbnail, 120)}
        seed={id}
        kind={(data?.subtitle ?? hint?.subtitle ?? 'Album').split('•')[0].trim() || 'Album'}
        title={title}
        subtitle={
          data?.artist ? (
            <button className="link" onClick={() => drift.findArtist(data.artist).then((a) => a && go({ name: 'artist', id: a.id, hint: a }))}>
              {data.artist}
            </button>
          ) : undefined
        }
        meta={data ? `${data.subtitle.split('•').slice(1).join('·').trim()}${data.subtitle.includes('•') ? ' · ' : ''}${plural(data.tracks.length, 'song')}, ${formatTotal(data.tracks)}` : undefined}
        tracks={data?.tracks ?? []}
        context={{ kind: 'album', id, name: title }}
        buttons={
          data ? (
            <button
              className={music ? 'icon-btn tinted' : 'icon-btn big'}
              title={saved ? 'In your library' : 'Add to your library'}
              aria-label={saved ? 'In your library' : 'Add to your library'}
              onClick={() => {
                if (saved) return go({ name: 'playlist', id: saved.id })
                void drift.saveAlbum(data).then(() => toast(`Added ${data.title} to your library`))
              }}
            >
              <Icon name={saved ? 'check' : 'plus'} size={music ? 20 : 26} />
            </button>
          ) : undefined
        }
        onMore={data ? (e) => openMenu(e, [
          { label: 'Add to playlist', icon: 'plus', submenu: addToPlaylistItems(data.tracks) },
          { label: 'Download album', icon: 'download', action: () => { void drift.download(data.tracks); toast(`Downloading ${data.title}`) } }
        ]) : undefined}
      />
      {!data ? <Loading /> : <TrackList tracks={data.tracks} context={{ kind: 'album', id, name: title }} showAlbum={false} showArt={false} />}
    </div>
  )
}

export { artwork }
