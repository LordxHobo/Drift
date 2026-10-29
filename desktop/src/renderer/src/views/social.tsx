// Friends: what people you follow are listening to, profiles, and the playlists they show.
import { useEffect, useState } from 'react'
import type { JSX } from 'react'
import type { Playlist, SharedPlaylist, Track, UserProfile } from '@shared/types'
import { Icon } from '../icons'
import { accountStore, drift, go, meStore, openMenu, toast, useStore } from '../state'
import { playList } from '../player'
import { Card, PlaylistCover, Spinner, TrackArt, TrackList, trackMenu } from '../ui'
import { formatTotal, plural } from '../util'
import { CollectionHeader, Failed, Loading, cleanError, useMusic } from './common'
import { editProfileStore } from './editProfile'
import { joinFriend } from './jam'

// MARK: Helpers

export function listeningNow(u: UserProfile): boolean {
  if (!u.playing || !u.nowPlaying || !u.updatedAt) return false
  return Date.now() / 1000 - u.updatedAt < (u.nowPlaying.duration ?? 0) + 15 * 60
}

function activityText(u: UserProfile): string | undefined {
  if (!u.nowPlaying) return undefined
  if (listeningNow(u)) return 'Listening now'
  if (!u.updatedAt) return undefined
  const s = Date.now() / 1000 - u.updatedAt
  if (s < 3600) return `${Math.max(1, Math.round(s / 60))} min`
  if (s < 86400) return `${Math.round(s / 3600)} h`
  if (s < 7 * 86400) return `${Math.round(s / 86400)} d`
  return `${Math.round(s / (7 * 86400))} w`
}

export function UserAvatar({ user, size = 40 }: { user: Pick<UserProfile, 'username' | 'avatar'>; size?: number }): JSX.Element {
  return user.avatar ? (
    <img className="avatar" src={user.avatar} alt="" style={{ width: size, height: size }} />
  ) : (
    <span className="avatar avatar-letter" style={{ width: size, height: size, fontSize: size * 0.42 }}>
      {user.username.slice(0, 1).toUpperCase()}
    </span>
  )
}

function FollowButton({ user }: { user: UserProfile }): JSX.Element | null {
  const me = useStore(meStore)
  const [busy, setBusy] = useState(false)
  if (!me || me.id === user.id) return null
  const following = me.following.includes(user.id)
  return (
    <button
      className={`btn outline follow ${following ? 'on' : ''}`}
      disabled={busy}
      onClick={(e) => {
        e.stopPropagation()
        setBusy(true)
        drift
          .followUser(user.id, !following)
          .then((m) => m && meStore.set(m))
          .catch((err) => toast(cleanError(err)))
          .finally(() => setBusy(false))
      }}
    >
      {following ? 'Following' : 'Follow'}
    </button>
  )
}

const playActivity = (u: UserProfile): void => {
  if (u.nowPlaying) playList([u.nowPlaying], 0, { kind: 'song', name: `${u.username}’s activity` })
}

/** A friend and what they're playing. */
function FriendRow({ user, button }: { user: UserProfile; button?: boolean }): JSX.Element {
  const now = listeningNow(user)
  const when = activityText(user)
  return (
    <div className="friend-row" role="button" tabIndex={0} onClick={() => go({ name: 'user', id: user.id, hint: user })} onKeyDown={(e) => e.key === 'Enter' && go({ name: 'user', id: user.id, hint: user })}>
      <span className="friend-avatar">
        <UserAvatar user={user} size={44} />
        {now && (
          <span className="friend-live" aria-label="Listening now">
            <i />
            <i />
            <i />
          </span>
        )}
      </span>
      <span className="friend-text">
        <span className="friend-top">
          <b>{user.username}</b>
          {when && <span className={`friend-when ${now ? 'now' : ''}`}>{when}</span>}
        </span>
        {user.nowPlaying ? (
          <button
            className="friend-track link"
            title={`Play ${user.nowPlaying.title}`}
            onClick={(e) => {
              e.stopPropagation()
              playActivity(user)
            }}
            onContextMenu={(e) => openMenu(e, trackMenu(user.nowPlaying!))}
          >
            {user.nowPlaying.title} · {user.nowPlaying.artist}
          </button>
        ) : (
          <span className="friend-track muted">{user.shareActivity ? 'Nothing played yet' : 'Listening activity is hidden'}</span>
        )}
      </span>
      {user.jam && (
        <button
          className="btn small jam-join-btn"
          title={`Listen together with ${user.username}`}
          onClick={(e) => {
            e.stopPropagation()
            joinFriend(user)
          }}
        >
          Join
        </button>
      )}
      {button && <FollowButton user={user} />}
    </div>
  )
}

/** People you follow, refreshed every minute while shown. */
function useFriends(): { friends?: UserProfile[]; error?: string; reload: () => void } {
  const account = useStore(accountStore)
  const [state, setState] = useState<{ friends?: UserProfile[]; error?: string }>({})
  const [n, setN] = useState(0)
  useEffect(() => {
    if (!account.linked) return
    let alive = true
    const load = (): void =>
      void drift
        .friends()
        .then((f) => alive && setState({ friends: f }))
        .catch((e) => alive && setState((s) => ({ ...s, error: cleanError(e) })))
    load()
    const t = window.setInterval(load, 60_000)
    return () => {
      alive = false
      clearInterval(t)
    }
  }, [account.linked, n])
  return { ...state, reload: () => setN((x) => x + 1) }
}

function NotLinked(): JSX.Element {
  return (
    <div className="empty">
      Friends need your Drift profile. Link your phone to see what friends are listening to.
      <div>
        <button className="btn primary" onClick={() => go({ name: 'settings' })}>Link your phone</button>
      </div>
    </div>
  )
}

// MARK: Side panel

export function FriendActivityPanel(): JSX.Element {
  const account = useStore(accountStore)
  const { friends, error } = useFriends()
  if (!account.linked) return <div className="queue-panel"><NotLinked /></div>
  return (
    <div className="queue-panel friends-panel">
      {error && !friends ? (
        <div className="empty small">{error}</div>
      ) : !friends ? (
        <div className="loading"><Spinner /></div>
      ) : friends.length ? (
        friends.map((u) => <FriendRow key={u.id} user={u} />)
      ) : (
        <div className="empty small">
          Follow friends to see what they’re listening to.
          <div><button className="btn small" onClick={() => go({ name: 'friends' })}>Find friends</button></div>
        </div>
      )}
      <button className="link see-all friends-more" onClick={() => go({ name: 'friends' })}>Find friends</button>
    </div>
  )
}

// MARK: Friends page

export function FriendsPage(): JSX.Element {
  const account = useStore(accountStore)
  const me = useStore(meStore)
  const { friends, error, reload } = useFriends()
  const [tab, setTab] = useState<'following' | 'followers'>('following')
  const [followers, setFollowers] = useState<UserProfile[] | null>(null)
  const [q, setQ] = useState('')
  const [results, setResults] = useState<UserProfile[] | null>(null)

  useEffect(() => {
    if (tab !== 'followers' || !account.linked) return
    void drift.followers().then(setFollowers).catch(() => setFollowers([]))
  }, [tab, account.linked])

  useEffect(() => {
    const text = q.trim()
    if (!text) return setResults(null)
    let alive = true
    const t = window.setTimeout(() => void drift.searchUsers(text).then((r) => alive && setResults(r)).catch(() => alive && setResults([])), 300)
    return () => {
      alive = false
      clearTimeout(t)
    }
  }, [q])

  // Reload when you follow someone from the search.
  useEffect(reload, [me?.following.length])

  if (!account.linked) {
    return (
      <div className="page">
        <h1 className="page-title">Friends</h1>
        <NotLinked />
      </div>
    )
  }

  const list = tab === 'following' ? friends : followers
  return (
    <div className="page friends-page">
      <div className="page-title-row">
        <h1 className="page-title">Friends</h1>
        {me && (
          <button className="btn" onClick={() => go({ name: 'user', id: me.id, hint: me })}>
            <UserAvatar user={me} size={22} /> Your profile
          </button>
        )}
      </div>
      <label className="search-box people-search">
        <Icon name="search" size={18} />
        <input value={q} placeholder="Find people by username" onChange={(e) => setQ(e.target.value)} onKeyDown={(e) => e.key === 'Escape' && setQ('')} />
      </label>

      {results ? (
        <section className="section">
          {results.length ? results.map((u) => <FriendRow key={u.id} user={u} button />) : <div className="empty small">No one called “{q.trim()}”.</div>}
        </section>
      ) : (
        <>
          <div className="chips friends-tabs">
            <button className={`chip ${tab === 'following' ? 'on' : ''}`} onClick={() => setTab('following')}>
              Following{me ? ` · ${me.following.length}` : ''}
            </button>
            <button className={`chip ${tab === 'followers' ? 'on' : ''}`} onClick={() => setTab('followers')}>
              Followers{followers ? ` · ${followers.length}` : ''}
            </button>
          </div>
          {error && !list ? (
            <Failed message={error} retry={reload} />
          ) : !list ? (
            <Loading />
          ) : list.length ? (
            list.map((u) => <FriendRow key={u.id} user={u} button={tab === 'followers'} />)
          ) : (
            <div className="empty small">
              {tab === 'following' ? 'You don’t follow anyone yet. Find friends by their username above.' : 'No followers yet.'}
            </div>
          )}
        </>
      )}
    </div>
  )
}

// MARK: Profile page

/** Someone's followers, or the people they follow. */
function FollowDialog({ title, load, empty, close }: { title: string; load: () => Promise<UserProfile[]>; empty: string; close: () => void }): JSX.Element {
  const [list, setList] = useState<UserProfile[] | null>(null)
  useEffect(() => {
    let alive = true
    load().then((l) => alive && setList(l)).catch(() => alive && setList([]))
    return () => {
      alive = false
    }
  }, [title])
  return (
    <div className="dialog-layer" onMouseDown={close}>
      <div className="dialog collab" onMouseDown={(e) => e.stopPropagation()} onKeyDown={(e) => e.key === 'Escape' && close()} tabIndex={-1}>
        <h3>{title}</h3>
        <div className="collab-list follow-list">
          {list === null ? (
            <div className="empty small"><Spinner size={18} /></div>
          ) : list.length === 0 ? (
            <div className="empty small">{empty}</div>
          ) : (
            list.map((u) => (
              <button
                key={u.id}
                className="collab-row follow-row"
                onClick={() => {
                  close()
                  go({ name: 'user', id: u.id, hint: u })
                }}
              >
                <UserAvatar user={u} size={30} />
                <span className="collab-name">{u.username}</span>
              </button>
            ))
          )}
        </div>
        <div className="dialog-buttons">
          <span className="spacer" />
          <button className="btn ghost" onClick={close}>Close</button>
        </div>
      </div>
    </div>
  )
}

export function UserPage({ id, hint }: { id: string; hint?: UserProfile }): JSX.Element {
  const me = useStore(meStore)
  const music = useMusic()
  const [user, setUser] = useState<UserProfile | undefined>(hint)
  const [lists, setLists] = useState<SharedPlaylist[] | null>(null)
  const [followerList, setFollowerList] = useState<UserProfile[] | null>(null)
  const followers = followerList?.length ?? null
  const [error, setError] = useState<string>()
  const [showing, setShowing] = useState<'followers' | 'following' | null>(null)

  useEffect(() => {
    let alive = true
    setError(undefined)
    setLists(null)
    setShowing(null)
    drift
      .user(id)
      .then((u) => {
        if (!alive) return
        if (!u) return setError('This profile doesn’t exist anymore.')
        setUser(u)
        void drift.sharedPlaylists(u).then((l) => alive && setLists(l)).catch(() => alive && setLists([]))
      })
      .catch((e) => alive && setError(cleanError(e)))
    void drift.followers(id).then((f) => alive && setFollowerList(f)).catch(() => undefined)
    return () => {
      alive = false
    }
  }, [id])

  useEffect(() => {
    if (me && me.id === id) setUser((u) => (u ? { ...u, username: me.username, avatar: me.avatar } : u))
  }, [me?.username, me?.avatar])

  if (error && !user) return <div className="page"><Failed message={error} /></div>
  if (!user) return <div className="page"><Loading /></div>
  const isMe = me?.id === user.id
  const now = listeningNow(user)

  return (
    <div className="page user-page">
      {showing && (
        <FollowDialog
          title={showing === 'followers' ? `${isMe ? 'Your' : `${user.username}’s`} followers` : `${isMe ? 'You follow' : `${user.username} follows`}`}
          load={() => (showing === 'followers' ? (followerList ? Promise.resolve(followerList) : drift.followers(user.id)) : drift.users(user.following))}
          empty={showing === 'followers' ? 'No followers yet.' : 'Not following anyone yet.'}
          close={() => setShowing(null)}
        />
      )}
      <div className="user-head">
        {isMe ? (
          <button className="edit-cover round" onClick={() => editProfileStore.set(true)} title="Edit profile">
            <UserAvatar user={user} size={160} />
            <span className="edit-cover-hint"><Icon name="edit" size={24} /></span>
          </button>
        ) : (
          <UserAvatar user={user} size={160} />
        )}
        <div className="user-text">
          <div className="d-kind">Profile</div>
          <h1>{user.username}</h1>
          <div className="user-counts">
            <span><b>{lists?.length ?? '–'}</b> public {lists?.length === 1 ? 'playlist' : 'playlists'}</span>
            <button className="link count-link" onClick={() => setShowing('followers')}>
              <b>{followers ?? '–'}</b> {followers === 1 ? 'follower' : 'followers'}
            </button>
            <button className="link count-link" onClick={() => setShowing('following')}>
              <b>{user.following.length}</b> following
            </button>
          </div>
          <div className="user-buttons">
            {isMe ? (
              <button className="btn outline" onClick={() => editProfileStore.set(true)}>
                <Icon name="edit" size={14} /> Edit profile
              </button>
            ) : (
              <>
                <FollowButton user={user} />
                {user.jam && (
                  <button className="btn primary" onClick={() => joinFriend(user)}>
                    <Icon name="together" size={14} /> Listen together
                  </button>
                )}
              </>
            )}
          </div>
        </div>
      </div>

      {user.nowPlaying ? (
        <div className="activity-card" onDoubleClick={() => playActivity(user)} onContextMenu={(e) => openMenu(e, trackMenu(user.nowPlaying!))}>
          <TrackArt track={user.nowPlaying} size={64} radius={6} />
          <div className="activity-text">
            <div className={`activity-label ${now ? 'now' : ''}`}>{now ? 'LISTENING NOW' : 'LAST PLAYED'}</div>
            <div className="activity-title">{user.nowPlaying.title}</div>
            <div className="activity-artist">{user.nowPlaying.artist}</div>
          </div>
          <button className="big-play small" aria-label={`Play ${user.nowPlaying.title}`} onClick={() => playActivity(user)}>
            <Icon name="play" size={18} />
          </button>
        </div>
      ) : !user.shareActivity && !isMe ? (
        <div className="empty small">{user.username} keeps their listening activity private.</div>
      ) : null}

      <section className="section">
        <h2>Public playlists</h2>
        {!lists ? (
          <Loading />
        ) : lists.length ? (
          <div className="grid">
            {lists.map((p) => (
              <Card
                key={p.id}
                title={p.name}
                subtitle={plural(p.count, 'song')}
                image={<SharedCover p={p} radius={music ? 8 : 6} />}
                onOpen={() => go({ name: 'shared', playlist: p })}
              />
            ))}
          </div>
        ) : (
          <div className="empty small">No public playlists.</div>
        )}
      </section>
    </div>
  )
}

function asPlaylist(p: SharedPlaylist, tracks?: Track[]): Playlist {
  return { id: p.id, name: p.name, tracks: tracks ?? p.preview, colorIndex: p.colorIndex, coverStyle: p.style, cover: p.cover ?? null }
}

function SharedCover({ p, size, radius }: { p: SharedPlaylist; size?: number; radius?: number }): JSX.Element {
  return <PlaylistCover p={asPlaylist(p)} size={size} radius={radius} />
}

// MARK: Someone's playlist

export function SharedPlaylistPage({ playlist: p }: { playlist: SharedPlaylist }): JSX.Element {
  const music = useMusic()
  const [tracks, setTracks] = useState<Track[] | null>(null)
  const [error, setError] = useState<string>()
  const [saved, setSaved] = useState<string | null>(null)
  const load = (): void => {
    setError(undefined)
    drift.sharedPlaylistTracks(p.ownerId, p.id).then(setTracks).catch((e) => setError(cleanError(e)))
  }
  useEffect(load, [p.ownerId, p.id])
  const context = { kind: 'playlist' as const, id: `shared-${p.ownerId}-${p.id}`, name: p.name }

  return (
    <div className="page">
      <CollectionHeader
        cover={<SharedCover p={p} size={music ? 230 : 200} radius={music ? 10 : 6} />}
        seed={p.id}
        kind="Public playlist"
        title={p.name}
        subtitle={
          <button className="link" onClick={() => go({ name: 'user', id: p.ownerId })}>
            {p.ownerName}
          </button>
        }
        meta={tracks ? `${plural(tracks.length, 'song')}, ${formatTotal(tracks)}` : plural(p.count, 'song')}
        tracks={tracks ?? []}
        context={context}
        buttons={
          <button
            className={music ? 'icon-btn tinted' : 'icon-btn big'}
            title={saved ? 'Saved to your library' : 'Save a copy to your library'}
            aria-label={saved ? 'Saved to your library' : 'Save a copy to your library'}
            disabled={!tracks?.length}
            onClick={() => {
              if (saved) return go({ name: 'playlist', id: saved })
              void drift.createPlaylist(p.name, tracks ?? []).then((id) => {
                setSaved(id)
                toast(`Saved a copy of ${p.name} to your library`)
              })
            }}
          >
            <Icon name={saved ? 'check' : 'plus'} size={music ? 20 : 26} />
          </button>
        }
      />
      {error ? <Failed message={`Couldn’t load this playlist: ${error}`} retry={load} /> : !tracks ? <Loading /> : <TrackList tracks={tracks} context={context} emptyText="This playlist is empty." />}
    </div>
  )
}
