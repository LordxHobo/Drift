// Podcasts: any YouTube channel can be followed as a show, and any video played as an episode.
import { useEffect, useState } from 'react'
import type { JSX } from 'react'
import type { PodcastChannel, Track } from '@shared/types'
import { appleEpoch } from '@shared/types'
import { Icon } from '../icons'
import { drift, go, openMenu, podcastsStore, toast, useStore } from '../state'
import type { MenuItem } from '../state'
import { playList, playNext, usePlayer } from '../player'
import type { PlayContext } from '../player'
import { Art, Card, EqualizerIcon, IconButton, addToPlaylistItems } from '../ui'
import { downloadMenuItem } from '../downloads'
import { formatTime, resized } from '../util'
import { Failed, Loading, cleanError } from './common'

function published(t: Track): string | undefined {
  if (t.published == null) return undefined
  const ms = (t.published + appleEpoch) * 1000
  const days = (Date.now() - ms) / 86400_000
  if (days < 1) return 'Today'
  if (days < 2) return 'Yesterday'
  if (days < 7) return `${Math.floor(days)} days ago`
  const d = new Date(ms)
  return d.toLocaleDateString(undefined, d.getFullYear() === new Date().getFullYear() ? { day: 'numeric', month: 'short' } : { day: 'numeric', month: 'short', year: 'numeric' })
}

function lengthText(seconds: number): string {
  const m = Math.max(1, Math.round(seconds / 60))
  return m >= 60 ? `${Math.floor(m / 60)} hr ${m % 60} min` : `${m} min`
}

export function channelOf(t: Track): PodcastChannel | undefined {
  return t.channelID ? { id: t.channelID, name: t.artist, avatarURL: t.channelAvatar ?? null } : undefined
}

function episodeMenu(t: Track): MenuItem[] {
  const p = podcastsStore.get()
  const done = p.progress[t.id]?.finished
  const started = !!p.progress[t.id]
  const channel = channelOf(t)
  const following = channel && p.subscriptions.some((s) => s.id === channel.id)
  return [
    { label: 'Play next', icon: 'queue', action: () => playNext([t]) },
    ...(!done ? [{ label: 'Mark as played', icon: 'check', action: () => void drift.markPlayed(t, true) }] : []),
    ...(started ? [{ label: 'Mark as unplayed', icon: 'sync', action: () => void drift.markPlayed(t, false) }] : []),
    downloadMenuItem(t),
    { label: 'Add to playlist', icon: 'plus', submenu: addToPlaylistItems([t]) },
    { label: '', separator: true },
    ...(channel
      ? [
          { label: `Go to ${channel.name}`, icon: 'mic', action: () => go({ name: 'channel', channel }) },
          following
            ? { label: `Unfollow ${channel.name}`, icon: 'close', action: () => void drift.followChannel(channel, false) }
            : { label: `Follow ${channel.name}`, icon: 'plus', action: () => void drift.followChannel(channel, true) }
        ]
      : []),
    { label: 'Open on YouTube', icon: 'external', action: () => void drift.openExternal(`https://www.youtube.com/watch?v=${t.id}`) }
  ]
}

/** One episode: thumbnail, title, show, date, length or time left, and progress. */
export function EpisodeRow({ t, list, index, context }: { t: Track; list: Track[]; index: number; context: PlayContext }): JSX.Element {
  const p = useStore(podcastsStore).progress[t.id]
  const player = usePlayer()
  const current = player.current?.id === t.id
  const fraction = p && !p.finished && p.position >= 30 && p.duration > 0 ? Math.min(1, p.position / p.duration) : undefined
  const left = fraction !== undefined ? p!.duration - p!.position : undefined
  const play = (): void => playList(list, index, context, { shuffle: false })
  return (
    <div className={`episode ${current ? 'current' : ''} ${p?.finished ? 'finished' : ''}`} onDoubleClick={play} onContextMenu={(e) => openMenu(e, episodeMenu(t))}>
      <button className="episode-thumb" onClick={play} aria-label={`Play ${t.title}`}>
        <img src={t.artworkURL ?? `https://i.ytimg.com/vi/${t.id}/mqdefault.jpg`} alt="" loading="lazy" />
        <span className="episode-play">{current && player.playing ? <EqualizerIcon /> : <Icon name="play" size={18} />}</span>
      </button>
      <div className="episode-text">
        <div className="episode-title">{t.title}</div>
        <div className="episode-meta">
          {t.channelID ? (
            <button className="link" onClick={() => go({ name: 'channel', channel: channelOf(t)! })}>{t.artist}</button>
          ) : (
            <span>{t.artist}</span>
          )}
          {published(t) && <span>{published(t)}</span>}
          {p?.finished ? (
            <span className="episode-played"><Icon name="check" size={12} /> Played</span>
          ) : left !== undefined ? (
            <span>{lengthText(left)} left</span>
          ) : t.duration ? (
            <span>{lengthText(t.duration)}</span>
          ) : null}
        </div>
        {fraction !== undefined && (
          <div className="episode-progress">
            <div style={{ width: `${fraction * 100}%` }} />
          </div>
        )}
      </div>
      <button className="more-btn episode-more" aria-label="More" onClick={(e) => openMenu(e, episodeMenu(t))}>
        <Icon name="more" size={16} />
      </button>
    </div>
  )
}

function ShowCard({ c }: { c: PodcastChannel }): JSX.Element {
  return (
    <Card
      round
      title={c.name}
      subtitle={c.subtitle ?? 'Show'}
      image={<Art src={resized(c.avatarURL, 400)} seed={c.id} round />}
      onOpen={() => go({ name: 'channel', channel: c })}
    />
  )
}

// MARK: Podcasts page

export function PodcastsPage({ q }: { q: string }): JSX.Element {
  const p = useStore(podcastsStore)
  const [query, setQuery] = useState(q)
  const [results, setResults] = useState<{ q: string; channels: PodcastChannel[]; episodes: Track[]; error?: string } | null>(null)
  const [linkTrack, setLinkTrack] = useState<Track | null>(null)

  useEffect(() => void drift.refreshPodcasts(false), [])
  useEffect(() => {
    const text = query.trim()
    setLinkTrack(null)
    if (!text) return setResults(null)
    let alive = true
    const t = window.setTimeout(() => {
      if (/youtu/.test(text)) {
        void drift.videoFromLink(text).then((v) => alive && setLinkTrack(v)).catch(() => undefined)
      }
      drift
        .searchPodcasts(text)
        .then((r) => alive && setResults({ q: text, ...r }))
        .catch((e) => alive && setResults({ q: text, channels: [], episodes: [], error: cleanError(e) }))
    }, 400)
    return () => {
      alive = false
      clearTimeout(t)
    }
  }, [query])

  const followed = p.subscriptions
  const newEpisodes = followed
    .flatMap((c) => p.feeds[c.id] ?? [])
    .sort((a, b) => (b.published ?? 0) - (a.published ?? 0))
    .slice(0, 40)
  const continueListening = Object.values(p.progress)
    .filter((x) => !x.finished && x.position >= 30)
    .sort((a, b) => b.updated - a.updated)
    .slice(0, 8)
    .map((x) => x.track)

  return (
    <div className="page podcasts">
      <div className="page-title-row">
        <h1 className="page-title">Podcasts</h1>
        {followed.length > 0 && (
          <IconButton icon="sync" label={p.refreshing ? 'Looking for new episodes…' : 'Look for new episodes'} disabled={p.refreshing} onClick={() => void drift.refreshPodcasts(true)} />
        )}
      </div>
      <label className="search-box people-search">
        <Icon name="search" size={18} />
        <input value={query} placeholder="Search shows and episodes, or paste a YouTube link" onChange={(e) => setQuery(e.target.value)} onKeyDown={(e) => e.key === 'Escape' && setQuery('')} />
      </label>

      {query.trim() ? (
        <>
          {linkTrack && (
            <section className="section">
              <h2>From the link</h2>
              <EpisodeRow t={linkTrack} list={[linkTrack]} index={0} context={{ kind: 'song', name: linkTrack.title }} />
            </section>
          )}
          {!results || results.q !== query.trim() ? (
            <Loading />
          ) : results.error ? (
            <Failed message={`Search didn’t work: ${results.error}`} />
          ) : (
            <>
              {results.channels.length > 0 && (
                <section className="shelf">
                  <div className="shelf-head"><h2>Shows</h2></div>
                  <div className="shelf-row">{results.channels.slice(0, 10).map((c) => <ShowCard key={c.id} c={c} />)}</div>
                </section>
              )}
              <section className="section">
                <h2>Episodes</h2>
                {results.episodes.length ? (
                  results.episodes.slice(0, 30).map((t) => (
                    <EpisodeRow key={t.id} t={t} list={[t]} index={0} context={{ kind: 'song', name: t.title }} />
                  ))
                ) : (
                  <div className="empty small">No episodes found.</div>
                )}
              </section>
            </>
          )}
        </>
      ) : (
        <>
          {!followed.length && !continueListening.length && (
            <div className="welcome">
              <h2>Follow your first show</h2>
              <p>Search for a show or any YouTube channel above and click Follow. New episodes show up here, and every episode remembers where you stopped. You can also paste a YouTube link to play any video.</p>
            </div>
          )}
          {continueListening.length > 0 && (
            <section className="section">
              <h2>Continue listening</h2>
              {continueListening.map((t, i) => (
                <EpisodeRow key={t.id} t={t} list={continueListening} index={i} context={{ kind: 'queue', name: 'Continue listening' }} />
              ))}
            </section>
          )}
          {followed.length > 0 && (
            <section className="shelf">
              <div className="shelf-head"><h2>Your shows</h2></div>
              <div className="shelf-row">{followed.map((c) => <ShowCard key={c.id} c={c} />)}</div>
            </section>
          )}
          {newEpisodes.length > 0 && (
            <section className="section">
              <h2>New episodes</h2>
              {newEpisodes.map((t, i) => (
                <EpisodeRow key={t.id} t={t} list={newEpisodes} index={i} context={{ kind: 'queue', name: 'New episodes' }} />
              ))}
            </section>
          )}
        </>
      )}
    </div>
  )
}

// MARK: One show

export function ChannelPage({ channel }: { channel: PodcastChannel }): JSX.Element {
  const p = useStore(podcastsStore)
  const [episodes, setEpisodes] = useState<Track[] | null>(p.feeds[channel.id] ?? null)
  const [error, setError] = useState<string>()
  const following = p.subscriptions.some((s) => s.id === channel.id)
  const info = p.subscriptions.find((s) => s.id === channel.id) ?? channel
  const load = (): void => {
    setError(undefined)
    drift.channelEpisodes(channel).then(setEpisodes).catch((e) => setError(cleanError(e)))
  }
  useEffect(load, [channel.id])
  const context: PlayContext = { kind: 'artist', id: `channel-${channel.id}`, name: channel.name }
  const avatar = info.avatarURL ?? episodes?.find((e) => e.channelAvatar)?.channelAvatar

  return (
    <div className="page channel-page">
      <div className="user-head">
        <Art src={resized(avatar, 400)} seed={channel.id} size={160} round />
        <div className="user-text">
          <div className="d-kind">Show</div>
          <h1>{info.name}</h1>
          {info.subtitle && <div className="user-counts">{info.subtitle}</div>}
          <div className="user-buttons">
            <button
              className={`btn outline follow ${following ? 'on' : ''}`}
              onClick={() => {
                void drift.followChannel({ ...info, avatarURL: avatar ?? null }, !following)
                if (!following) toast(`Following ${info.name}. New episodes show up in Podcasts.`)
              }}
            >
              {following ? 'Following' : 'Follow'}
            </button>
            {episodes?.[0] && (
              <button className="btn" onClick={() => playList(episodes, 0, context, { shuffle: false })}>
                <Icon name="play" size={14} /> Latest episode
              </button>
            )}
          </div>
        </div>
      </div>
      {error && !episodes ? (
        <Failed message={`Couldn’t load the episodes: ${error}`} retry={load} />
      ) : !episodes ? (
        <Loading />
      ) : episodes.length ? (
        episodes.map((t, i) => <EpisodeRow key={t.id} t={t} list={episodes} index={i} context={context} />)
      ) : (
        <div className="empty">No episodes found.</div>
      )}
    </div>
  )
}

/** The speed button in the player (episodes only). */
export function SpeedButton({ speed, onPick }: { speed: number; onPick: (s: number) => void }): JSX.Element {
  const speeds = [0.75, 1, 1.25, 1.5, 1.75, 2]
  return (
    <button
      className="speed-btn"
      title="Playback speed"
      aria-label={`Playback speed ${speed}×`}
      onClick={(e) =>
        openMenu(
          { clientX: e.currentTarget.getBoundingClientRect().left, clientY: e.currentTarget.getBoundingClientRect().top - 250 },
          speeds.map((s) => ({ label: `${s}×`, checked: s === speed, action: () => onPick(s) }))
        )
      }
    >
      {speed}×
    </button>
  )
}

export { formatTime }
