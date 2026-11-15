// The YouTube viewer: the switch in the title bar, signing in, its side menu and pages (home with new
// videos from subscriptions, history, Watch later, liked videos, channels, search) and the watch page.
// Videos play through the normal player, as episodes that always show their picture, so speed,
// SponsorBlock, media keys, downloads and the mini video all work the same.
import { useEffect, useRef, useState } from 'react'
import type { JSX } from 'react'
import type { Track, YTChannel, YTComment, YTVideo, YTVideoDetails } from '@shared/types'
import { Icon, Logo } from '../icons'
import { drift, go, setViewerMode, settingsStore, toast, useRoute, useStore, ytAccountStore, ytSignInStore, Store, refreshYouTubeAccount, accountStore, readLocal, writeLocal } from '../state'
import type { Route } from '../state'
import { playList, positionStore, seek, setSponsorBlock, toggle, toggleMute, usePlayer } from '../player'
import { IconButton, Spinner } from '../ui'
import { formatTime } from '../util'
import { VideoSurface } from '../videoView'
import { openSend } from './inbox'

const cleanMessage = (e: unknown): string =>
  e instanceof Error ? e.message.replace(/^Error invoking remote method '[^']+': (Error: )?/, '') : 'That didn’t work.'

const same = (a: Route, b: Route): boolean => JSON.stringify(a) === JSON.stringify(b)

/** A video as something the player can play: an episode that always shows its picture. */
export function toTrack(v: YTVideo): Track {
  return {
    id: v.id,
    title: v.title,
    artist: v.channel,
    duration: v.duration,
    artworkURL: v.thumbnail,
    podcast: true,
    watch: true,
    channelID: v.channelId,
    upload: true
  }
}

/** Plays a video (then the ones after it, like YouTube's autoplay) and opens its watch page. */
export function playVideo(v: YTVideo, after: YTVideo[] = []): void {
  const list = [v, ...after.filter((x) => x.id !== v.id && !x.live)]
  playList(list.map(toTrack), 0, { kind: 'youtube', name: v.channel || 'YouTube' }, { shuffle: false })
  go({ name: 'yt-watch', id: v.id })
}

// MARK: Loading

const cache = new Map<string, { at: number; value: unknown }>()

/** Loads from YouTube (kept for a couple of minutes, so going back and forth is instant). */
function useYT<T>(key: string, load: () => Promise<T>): { data: T | undefined; error: string | undefined; reload: () => void } {
  const [state, setState] = useState<{ data?: T; error?: string }>(() => {
    const c = cache.get(key)
    return c ? { data: c.value as T } : {}
  })
  const [tick, setTick] = useState(0)
  useEffect(() => {
    let live = true
    const c = cache.get(key)
    if (c && Date.now() - c.at < 120_000 && tick === 0) {
      setState({ data: c.value as T })
      return
    }
    if (!c) setState({})
    load()
      .then((value) => {
        cache.set(key, { at: Date.now(), value })
        if (live) setState({ data: value })
      })
      .catch((e) => live && setState((s) => ({ data: s.data, error: cleanMessage(e) })))
    return () => {
      live = false
    }
  }, [key, tick])
  return { data: state.data, error: state.error, reload: () => setTick((t) => t + 1) }
}

const channelsStore = new Store<YTChannel[]>([])
let channelsLoaded = 0

function useChannels(): YTChannel[] {
  const list = useStore(channelsStore)
  const signedIn = !!useStore(ytAccountStore)
  useEffect(() => {
    if (!signedIn || Date.now() - channelsLoaded < 300_000) return
    channelsLoaded = Date.now()
    drift.ytChannels().then((c) => channelsStore.set(c)).catch(() => (channelsLoaded = 0))
  }, [signedIn])
  return list
}

// MARK: The switch and signing in

/** Music ↔ YouTube, in the title bar. */
export function ModeSwitch(): JSX.Element {
  const mode = useStore(settingsStore).viewerMode
  const on = mode === 'youtube'
  return (
    <div className="mode-switch no-drag">
      <span className="mode-brand">Drift</span>
      <button
        role="switch"
        aria-checked={on}
        aria-label="YouTube viewer"
        title={on ? 'Back to music' : 'Watch YouTube'}
        className={`mode-toggle ${on ? 'on' : ''}`}
        onClick={() => setViewerMode(on ? 'music' : 'youtube')}
      >
        <span className="mode-knob">
          <Icon name={on ? 'video' : 'note'} size={10} />
        </span>
      </button>
      <span className={`mode-label ${on ? 'on' : ''}`}>{on ? 'YouTube' : 'Music'}</span>
    </div>
  )
}

/** Asked before the viewer opens the first time on this computer. */
export function YouTubeSignIn(): JSX.Element | null {
  const open = useStore(ytSignInStore)
  const [busy, setBusy] = useState(false)
  if (!open) return null
  const close = (): void => ytSignInStore.set(false)
  const signIn = async (): Promise<void> => {
    setBusy(true)
    try {
      const ok = await drift.ytSignIn()
      await refreshYouTubeAccount()
      if (ok && ytAccountStore.get()) {
        close()
        setViewerMode('youtube')
      } else {
        toast('Not signed in. Try again whenever you like.')
      }
    } catch (e) {
      toast(cleanMessage(e))
    } finally {
      setBusy(false)
    }
  }
  return (
    <div className="dialog-layer" onMouseDown={close}>
      <div className="dialog yt-signin" role="dialog" aria-label="Sign in to YouTube" onMouseDown={(e) => e.stopPropagation()} onKeyDown={(e) => e.key === 'Escape' && close()} tabIndex={-1}>
        <div className="yt-signin-icon"><Icon name="youtube" size={34} /></div>
        <h3>Sign in to watch YouTube</h3>
        <p>The YouTube viewer uses your own YouTube account, so YouTube sees a signed-in viewer instead of an app, and your subscriptions, Watch later and history come along.</p>
        <div className="yt-signin-note">
          <Icon name="info" size={18} />
          <span>Use an account you don’t mind Drift using. Google sometimes asks apps like this to sign in again, rarely more.</span>
        </div>
        <button className="btn yt-google" disabled={busy} onClick={() => void signIn()}>
          {busy ? <Spinner size={16} /> : <span className="g-dot" aria-hidden="true" />}
          {busy ? 'Waiting for Google…' : 'Sign in with Google'}
        </button>
        <button className="btn ghost" onClick={close}>Not now, back to music</button>
        <span className="yt-signin-fine">Google’s own sign-in page opens in a Drift window. Drift never sees your password.</span>
      </div>
    </div>
  )
}

// MARK: Side menu

export function YouTubeSidebar(): JSX.Element {
  const route = useRoute()
  const music = useStore(settingsStore).style === 'music'
  const yt = useStore(ytAccountStore)
  const channels = useChannels()
  const [q, setQ] = useState(route.name === 'yt-search' ? route.q : '')
  const search = (
    <form
      className={music ? 'm-search' : 'yt-search-box'}
      onSubmit={(e) => {
        e.preventDefault()
        if (q.trim()) go({ name: 'yt-search', q: q.trim() })
      }}
    >
      <Icon name="search" size={15} />
      <input placeholder="Search YouTube" aria-label="Search YouTube" value={q} onChange={(e) => setQ(e.target.value)} />
    </form>
  )
  const item = (r: Route, icon: string, label: string): JSX.Element => (
    <button key={label} className={`${music ? 'm-item' : 'nav-item'} ${same(route, r) ? 'on' : ''}`} onClick={() => go(r)}>
      <Icon name={icon} size={music ? 18 : 22} className="m-icon yt-icon" />
      <span>{label}</span>
    </button>
  )
  const channelRows = channels.map((c) => (
    <button key={c.id} className={`yt-chan ${same(route, { name: 'yt-channel', id: c.id }) ? 'on' : ''}`} onClick={() => go({ name: 'yt-channel', id: c.id })}>
      {c.avatar ? <img src={c.avatar} alt="" /> : <span className="yt-chan-blank" />}
      <span className="yt-chan-name">{c.name}</span>
      {c.fresh && <span className="yt-dot" aria-label="New videos" />}
    </button>
  ))
  const you = [
    ...(yt?.channelId ? [item({ name: 'yt-channel', id: yt.channelId }, 'person', 'Your channel')] : []),
    item({ name: 'yt-feed', feed: 'history' }, 'clock', 'History'),
    item({ name: 'yt-feed', feed: 'watchLater' }, 'clock', 'Watch later'),
    item({ name: 'yt-feed', feed: 'liked' }, 'thumbUp', 'Liked videos'),
    item({ name: 'collection', kind: 'downloaded' }, 'download', 'Downloaded')
  ]
  const accountRow = (
    <button className={music ? 'm-profile' : 'yt-account'} onClick={() => go({ name: 'settings' })}>
      {yt?.avatar ? <img className="yt-avatar" src={yt.avatar} alt="" /> : <span className="yt-avatar blank" />}
      <span>{yt?.handle || yt?.name || 'YouTube'}</span>
      <Icon name="gear" size={16} />
    </button>
  )
  if (music) {
    return (
      <aside className="m-sidebar yt-mode">
        {search}
        <div className="m-scroll">
          {item({ name: 'yt-home' }, 'homeLine', 'Home')}
          {item({ name: 'yt-channels' }, 'subscriptions', 'Subscriptions')}
          {item({ name: 'podcasts' }, 'podcast', 'Podcasts')}
          <div className="m-section">You</div>
          {you}
          <div className="m-section">Subscriptions</div>
          {channelRows}
        </div>
        {accountRow}
      </aside>
    )
  }
  return (
    <aside className="sidebar yt-mode">
      <nav className="panel nav-panel">
        <div className="brand">
          <Logo size={20} />
          <span>Drift</span>
          <span className="yt-badge">YouTube</span>
        </div>
        {search}
        {item({ name: 'yt-home' }, 'home', 'Home')}
        {item({ name: 'yt-channels' }, 'subscriptions', 'Subscriptions')}
        {item({ name: 'podcasts' }, 'podcast', 'Podcasts')}
      </nav>
      <div className="panel lib-panel yt-lib">
        <div className="yt-section">You</div>
        {you}
        <div className="yt-section">Subscriptions</div>
        <div className="yt-chans">{channelRows}</div>
        {accountRow}
      </div>
    </aside>
  )
}

// MARK: Pages

function VideoCard({ v, list }: { v: YTVideo; list: YTVideo[] }): JSX.Element {
  return (
    <button className="yt-card" onClick={() => playVideo(v, list.slice(list.indexOf(v) + 1))}>
      <span className="yt-thumb">
        <img src={v.thumbnail} alt="" loading="lazy" />
        {(v.live || v.duration) && <span className={`yt-len ${v.live ? 'live' : ''}`}>{v.live ? 'LIVE' : formatTime(v.duration)}</span>}
      </span>
      <span className="yt-card-text">
        <span className="yt-card-title">{v.title}</span>
        {v.channel && (
          <span
            className="yt-card-channel"
            role="link"
            tabIndex={-1}
            onClick={(e) => {
              if (!v.channelId) return
              e.stopPropagation()
              go({ name: 'yt-channel', id: v.channelId })
            }}
          >
            {v.channel}
          </span>
        )}
        <span className="yt-card-meta">{[v.views, v.published].filter(Boolean).join(' · ')}</span>
      </span>
    </button>
  )
}

function Grid({ list, empty }: { list: YTVideo[] | undefined; empty: string }): JSX.Element {
  if (!list) return <div className="empty"><Spinner /></div>
  if (!list.length) return <div className="empty">{empty}</div>
  return (
    <div className="yt-grid">
      {list.map((v) => (
        <VideoCard key={v.id} v={v} list={list} />
      ))}
    </div>
  )
}

function Failed({ error, reload }: { error: string; reload: () => void }): JSX.Element {
  return (
    <div className="empty">
      {error} <button className="btn" onClick={reload}>Try again</button>
    </div>
  )
}

/** Home: new videos from your subscriptions, newest first. */
export function YouTubeHome(): JSX.Element {
  const { data, error, reload } = useYT('subscriptions', () => drift.ytFeed('subscriptions'))
  const [chip, setChip] = useState<'all' | 'live' | 'long'>('all')
  const list = data?.filter((v) => (chip === 'live' ? v.live : chip === 'long' ? (v.duration ?? 0) >= 1200 : true))
  return (
    <div className="page yt-page">
      <h1 className="page-title">Home</h1>
      <div className="yt-chips" role="tablist">
        {(
          [
            ['all', 'All'],
            ['long', '20 min+'],
            ['live', 'Live']
          ] as const
        ).map(([k, l]) => (
          <button key={k} role="tab" aria-selected={chip === k} className={`yt-chip ${chip === k ? 'on' : ''}`} onClick={() => setChip(k)}>
            {l}
          </button>
        ))}
        <IconButton icon="sync" label="Refresh" size={16} onClick={reload} />
      </div>
      {error && !data ? <Failed error={error} reload={reload} /> : <Grid list={list} empty="Nothing new from your subscriptions." />}
    </div>
  )
}

const feedTitles = { history: 'History', watchLater: 'Watch later', liked: 'Liked videos' } as const

export function YouTubeFeed({ feed }: { feed: 'history' | 'watchLater' | 'liked' }): JSX.Element {
  const { data, error, reload } = useYT(feed, () => drift.ytFeed(feed))
  return (
    <div className="page yt-page">
      <h1 className="page-title">{feedTitles[feed]}</h1>
      {error && !data ? <Failed error={error} reload={reload} /> : <Grid list={data} empty="Nothing here yet." />}
    </div>
  )
}

export function YouTubeChannels(): JSX.Element {
  const channels = useChannels()
  return (
    <div className="page yt-page">
      <h1 className="page-title">Subscriptions</h1>
      {channels.length === 0 ? (
        <div className="empty">Channels you subscribe to on YouTube show up here.</div>
      ) : (
        <div className="yt-channel-grid">
          {channels.map((c) => (
            <button key={c.id} className="yt-channel-tile" onClick={() => go({ name: 'yt-channel', id: c.id })}>
              {c.avatar ? <img src={c.avatar} alt="" /> : <span className="yt-chan-blank big" />}
              <span>{c.name}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

export function YouTubeChannel({ id }: { id: string }): JSX.Element {
  const { data, error, reload } = useYT(`channel:${id}`, () => drift.ytChannelVideos(id))
  const [subscribed, setSubscribed] = useState<boolean | null>(null)
  const known = useStore(channelsStore).some((c) => c.id === id)
  const isSub = subscribed ?? known
  const own = useStore(ytAccountStore)?.channelId === id
  return (
    <div className="page yt-page">
      <div className="yt-channel-head">
        {data?.channel.avatar ? <img src={data.channel.avatar} alt="" /> : <span className="yt-chan-blank huge" />}
        <h1 className="page-title">{data?.channel.name ?? ' '}</h1>
        {own ? <span className="yt-own">Your channel</span> : <SubscribeButton channelId={id} subscribed={isSub} onChange={setSubscribed} />}
      </div>
      {error && !data ? <Failed error={error} reload={reload} /> : <Grid list={data?.videos} empty="No videos." />}
    </div>
  )
}

export function YouTubeSearch({ q }: { q: string }): JSX.Element {
  const { data, error, reload } = useYT(`search:${q}`, () => drift.ytSearch(q))
  return (
    <div className="page yt-page">
      <h1 className="page-title">“{q}”</h1>
      {error && !data ? <Failed error={error} reload={reload} /> : <Grid list={data} empty="No videos found." />}
    </div>
  )
}

function SubscribeButton({ channelId, subscribed, onChange }: { channelId: string; subscribed: boolean; onChange: (on: boolean) => void }): JSX.Element {
  const [busy, setBusy] = useState(false)
  return (
    <button
      className={`btn yt-sub ${subscribed ? 'on' : ''}`}
      disabled={busy || !channelId}
      onClick={async () => {
        setBusy(true)
        try {
          await drift.ytSubscribe(channelId, !subscribed)
          onChange(!subscribed)
          channelsLoaded = 0
        } catch (e) {
          toast(cleanMessage(e))
        } finally {
          setBusy(false)
        }
      }}
    >
      {subscribed && <Icon name="bell" size={16} />}
      {subscribed ? 'Subscribed' : 'Subscribe'}
    </button>
  )
}

// MARK: Watching

export function YouTubeWatch({ id }: { id: string }): JSX.Element {
  const p = usePlayer()
  const settings = useStore(settingsStore)
  const linked = useStore(accountStore).linked
  const { data } = useYT<YTVideoDetails>(`video:${id}`, () => drift.ytVideo(id))
  const [subscribed, setSubscribed] = useState<boolean | null>(null)
  const [more, setMore] = useState(false)
  const [theater, setTheater] = useState(() => readLocal('ytTheater', false))
  const started = useRef(false)
  const toggleTheater = (): void =>
    setTheater((on) => {
      writeLocal('ytTheater', !on)
      return !on
    })
  // Opened from a link or history while something else plays: start this one.
  useEffect(() => {
    if (started.current || p.current?.id === id || !data) return
    started.current = true
    playVideo(
      { id, title: data.title, channel: data.channel.name, channelId: data.channel.id, thumbnail: `https://i.ytimg.com/vi/${id}/hqdefault.jpg`, duration: null, views: data.views, published: data.published, live: false },
      data.related
    )
  }, [data, id])
  useEffect(() => {
    setSubscribed(null)
    setMore(false)
  }, [id])
  // YouTube's keys: F full screen, T theater, K play/pause, J/L back/ahead 10 s, M mute.
  useEffect(() => {
    const key = (e: KeyboardEvent): void => {
      const target = e.target as HTMLElement
      if (e.ctrlKey || e.metaKey || e.altKey || target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable) return
      const k = e.key.toLowerCase()
      if (k === 'f') {
        const el = document.querySelector('.yt-player.video-surface')
        if (document.fullscreenElement) void document.exitFullscreen()
        else if (el) void el.requestFullscreen()
      } else if (k === 't') toggleTheater()
      else if (k === 'k') toggle()
      else if (k === 'j') seek(Math.max(0, positionStore.get() - 10))
      else if (k === 'l') seek(positionStore.get() + 10)
      else if (k === 'm') toggleMute()
      else return
      e.preventDefault()
    }
    window.addEventListener('keydown', key)
    return () => window.removeEventListener('keydown', key)
  }, [])
  const playing = p.current?.id === id
  const t = playing ? p.current : undefined
  const title = data?.title || t?.title || ''
  const act = async (f: () => Promise<void>, done: string): Promise<void> => {
    try {
      await f()
      toast(done)
    } catch (e) {
      toast(cleanMessage(e))
    }
  }
  const player = playing ? (
    <VideoSurface className="big yt-player" controls theater={theater} onTheater={toggleTheater} />
  ) : (
    <div className="yt-player placeholder">
      <Spinner />
    </div>
  )
  return (
    <div className={`yt-watch-page ${theater ? 'theater' : ''}`}>
      {theater && <div className="yt-stage">{player}</div>}
      <div className="yt-watch">
        <div className="yt-watch-main">
          {!theater && player}
          <h1 className="yt-watch-title">{title}</h1>
          <div className="yt-watch-row">
            {data?.channel.avatar && <img className="yt-owner" src={data.channel.avatar} alt="" />}
            <button className="yt-owner-text" onClick={() => data?.channel.id && go({ name: 'yt-channel', id: data.channel.id })}>
              <span className="yt-owner-name">{data?.channel.name ?? t?.artist}</span>
              <span className="yt-owner-subs">{data?.subscribers}</span>
            </button>
            {data && <SubscribeButton channelId={data.channel.id} subscribed={subscribed ?? data.subscribed} onChange={setSubscribed} />}
            <span className="spacer" />
            <button className="btn yt-act" onClick={() => void act(() => drift.ytLike(id), 'Liked')}>
              <Icon name="thumbUp" size={16} />
              Like
            </button>
            <button className="btn yt-act" onClick={() => void act(() => drift.ytWatchLater(id), 'Saved to Watch later')}>
              <Icon name="clock" size={16} />
              Watch later
            </button>
            {t && (
              <button className="btn yt-act" onClick={() => void act(async () => void (await drift.download([t])), 'Downloading')}>
                <Icon name="download" size={16} />
                Download
              </button>
            )}
            {t && linked && (
              <button className="btn yt-act" onClick={() => openSend(t)}>
                <Icon name="send" size={16} />
                Send
              </button>
            )}
            <button
              className={`btn yt-act ${settings.skipSponsors ? 'on' : ''}`}
              aria-pressed={settings.skipSponsors}
              title="Skip sponsors, self-promotion and subscribe reminders the SponsorBlock community marked (and show them on the timeline)"
              onClick={() => setSponsorBlock(!settings.skipSponsors)}
            >
              <span className="sb-dot" aria-hidden="true" />
              SponsorBlock {settings.skipSponsors ? 'on' : 'off'}
            </button>
          </div>
          {data && (data.description || data.views) && (
            <div className={`yt-desc ${more ? 'open' : ''}`}>
              <b>{[data.views, data.published].filter(Boolean).join(' · ')}</b>
              <p>{data.description}</p>
              {data.description.length > 200 && (
                <button className="link" onClick={() => setMore(!more)}>
                  {more ? 'Show less' : 'Show more'}
                </button>
              )}
            </div>
          )}
          <CommentSection key={id} videoId={id} />
        </div>
        <aside className="yt-next">
          <div className="yt-next-head">Up next</div>
          {!data && <Spinner />}
          {data?.related.slice(0, 20).map((v, i) => (
            <button key={v.id} className="yt-next-row" onClick={() => playVideo(v, data.related.slice(i + 1))}>
              <span className="yt-thumb small">
                <img src={v.thumbnail} alt="" loading="lazy" />
                {v.duration ? <span className="yt-len">{formatTime(v.duration)}</span> : null}
              </span>
              <span className="yt-card-text">
                <span className="yt-card-title">{v.title}</span>
                <span className="yt-card-meta">{v.channel}</span>
                <span className="yt-card-meta">{[v.views, v.published].filter(Boolean).join(' · ')}</span>
              </span>
            </button>
          ))}
        </aside>
      </div>
    </div>
  )
}

/** Comments under the video: top or newest, more as you ask, and writing your own. */
function CommentSection({ videoId }: { videoId: string }): JSX.Element {
  const yt = useStore(ytAccountStore)
  const [sort, setSort] = useState<'top' | 'newest'>('top')
  const [list, setList] = useState<YTComment[] | null>(null)
  const [next, setNext] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [draft, setDraft] = useState('')
  const [posting, setPosting] = useState(false)
  const load = async (more?: string): Promise<void> => {
    setLoading(true)
    setError(null)
    try {
      const r = await drift.ytComments(videoId, sort, more)
      setList((old) => (more ? [...(old ?? []), ...r.comments] : r.comments))
      setNext(r.more)
    } catch (e) {
      setError(cleanMessage(e))
      if (!more) setList([])
    } finally {
      setLoading(false)
    }
  }
  useEffect(() => {
    setList(null)
    void load()
  }, [sort])
  const post = async (): Promise<void> => {
    const text = draft.trim()
    if (!text) return
    setPosting(true)
    try {
      await drift.ytPostComment(videoId, text)
      setList((old) => [{ id: `mine-${Date.now()}`, author: yt?.handle || yt?.name || 'You', authorAvatar: yt?.avatar ?? null, authorChannelId: yt?.channelId ?? null, text, published: 'just now', likes: '', replies: 0, pinned: false, byCreator: false }, ...(old ?? [])])
      setDraft('')
    } catch (e) {
      toast(cleanMessage(e))
    } finally {
      setPosting(false)
    }
  }
  return (
    <section className="yt-comments" aria-label="Comments">
      <div className="yt-comments-head">
        <h2>Comments</h2>
        <div className="yt-chips">
          <button className={`yt-chip ${sort === 'top' ? 'on' : ''}`} aria-pressed={sort === 'top'} onClick={() => setSort('top')}>Top</button>
          <button className={`yt-chip ${sort === 'newest' ? 'on' : ''}`} aria-pressed={sort === 'newest'} onClick={() => setSort('newest')}>Newest</button>
        </div>
      </div>
      <form
        className="yt-comment-new"
        onSubmit={(e) => {
          e.preventDefault()
          void post()
        }}
      >
        {yt?.avatar ? <img className="yt-avatar" src={yt.avatar} alt="" /> : <span className="yt-avatar blank" />}
        <input placeholder="Add a comment…" aria-label="Add a comment" value={draft} maxLength={10000} onChange={(e) => setDraft(e.target.value)} />
        {draft.trim() && (
          <button className="btn primary" disabled={posting}>
            {posting ? 'Posting…' : 'Comment'}
          </button>
        )}
      </form>
      {list === null && <Spinner />}
      {error && list?.length === 0 && <div className="empty small">{error}</div>}
      {list?.length === 0 && !error && <div className="empty small">No comments.</div>}
      {list?.map((c) => (
        <article key={c.id} className="yt-comment">
          {c.authorAvatar ? <img className="yt-avatar" src={c.authorAvatar} alt="" /> : <span className="yt-avatar blank" />}
          <div className="yt-comment-body">
            <div className="yt-comment-meta">
              {c.pinned && <span className="yt-pinned">Pinned</span>}
              <button
                className={`yt-comment-author ${c.byCreator ? 'creator' : ''}`}
                onClick={() => c.authorChannelId && go({ name: 'yt-channel', id: c.authorChannelId })}
              >
                {c.author}
              </button>
              <span>{c.published}</span>
            </div>
            <p>{c.text}</p>
            <div className="yt-comment-foot">
              <Icon name="thumbUp" size={13} />
              <span>{c.likes || ''}</span>
              {c.replies > 0 && <span>{c.replies === 1 ? '1 reply' : `${c.replies} replies`}</span>}
            </div>
          </div>
        </article>
      ))}
      {next && (
        <button className="btn yt-more" disabled={loading} onClick={() => void load(next)}>
          {loading ? <Spinner size={14} /> : 'More comments'}
        </button>
      )}
    </section>
  )
}

// MARK: Settings

/** The YouTube account row in Settings. */
export function YouTubeAccountSetting(): JSX.Element {
  const yt = useStore(ytAccountStore)
  if (!yt) {
    return (
      <button className="btn" onClick={() => ytSignInStore.set(true)}>
        Sign in to YouTube
      </button>
    )
  }
  return (
    <div className="yt-setting">
      {yt.avatar && <img className="yt-avatar" src={yt.avatar} alt="" />}
      <span>{yt.handle || yt.name}</span>
      <button
        className="btn"
        onClick={async () => {
          await drift.ytSignOut()
          await refreshYouTubeAccount()
          if (settingsStore.get().viewerMode === 'youtube') setViewerMode('music')
        }}
      >
        Sign out
      </button>
    </div>
  )
}
