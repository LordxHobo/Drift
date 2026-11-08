// Sending songs to friends: "Send to a friend…" in a song's menu (pick friends who follow you back, add a
// note), and the inbox of songs friends sent you (a tab in the side panel).
import { useEffect, useState } from 'react'
import type { JSX } from 'react'
import type { InboxItem, Track, UserProfile } from '@shared/types'
import { nameOf } from '@shared/types'
import { accountStore, drift, inboxStore, Store, toast, useStore } from '../state'
import { Icon } from '../icons'
import { IconButton, isLiked, Spinner, toggleLike, TrackArt } from '../ui'
import { playList, toggle, usePlayer } from '../player'
import { timeAgo } from '../util'
import { NotLinked, UserAvatar } from './social'

const cleanMessage = (e: unknown): string =>
  e instanceof Error ? e.message.replace(/^Error invoking remote method '[^']+': (Error: )?/, '') : 'That didn’t work.'

/** A note is at most this long (the server checks it too). */
const maxNote = 280

/** The song being sent. */
const sendStore = new Store<Track | null>(null)

export function openSend(t: Track): void {
  sendStore.set(t)
}

export function SendDialog(): JSX.Element | null {
  const track = useStore(sendStore)
  const account = useStore(accountStore)
  const [friends, setFriends] = useState<UserProfile[] | null>(null)
  const [picked, setPicked] = useState<Set<string>>(new Set())
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (!track) return
    setFriends(null)
    setPicked(new Set())
    setNote('')
    if (account.linked) drift.friends().then(setFriends).catch(() => setFriends([]))
  }, [track])

  if (!track) return null
  const close = (): void => sendStore.set(null)
  // Only friends who follow you back and accept songs (the server checks this too).
  const sendable = (friends ?? []).filter((f) => !!account.uid && f.following.includes(account.uid) && f.allowSongs !== false)
  const nameFor = (id: string): string => {
    const f = sendable.find((x) => x.id === id)
    return f ? nameOf(f) : 'someone'
  }
  const ids = [...picked]

  const send = async (): Promise<void> => {
    setBusy(true)
    try {
      const failed = await drift.sendSong(ids, track, note)
      const sent = ids.filter((id) => !failed.includes(id))
      if (failed.length) toast(`Couldn’t send it to ${failed.map(nameFor).join(', ')}. They may have turned this off or stopped following you, or the security rules need updating.`)
      if (sent.length) toast(`Sent to ${sent.map(nameFor).join(', ')}`)
      close()
    } catch (e) {
      toast(cleanMessage(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="dialog-layer" onMouseDown={close}>
      <div className="dialog collab" onMouseDown={(e) => e.stopPropagation()} onKeyDown={(e) => e.key === 'Escape' && close()} tabIndex={-1}>
        <h3>Send to a friend</h3>
        <div className="invite-song">
          <TrackArt track={track} size={44} radius={4} />
          <div>
            <div className="invite-title">{track.title}</div>
            <div className="invite-artist">{track.artist}</div>
          </div>
        </div>
        {!account.linked ? (
          <div className="empty small">Link your phone in Settings first, so friends can find you.</div>
        ) : (
          <div className="collab-list">
            {friends === null ? (
              <div className="empty small"><Spinner size={18} /></div>
            ) : sendable.length === 0 ? (
              <div className="empty small">
                {friends.length ? 'None of the people you follow can get songs from you yet. They need to follow you back.' : 'Follow your friends first (Friends), then send them songs here.'}
              </div>
            ) : (
              sendable.map((f) => (
                <label key={f.id} className="collab-row">
                  <UserAvatar user={f} size={30} />
                  <span className="collab-name">{nameOf(f)}</span>
                  <input
                    type="checkbox"
                    checked={picked.has(f.id)}
                    onChange={(e) => {
                      const next = new Set(picked)
                      if (e.target.checked) next.add(f.id)
                      else next.delete(f.id)
                      setPicked(next)
                    }}
                  />
                </label>
              ))
            )}
          </div>
        )}
        <input
          className="field send-note"
          placeholder="Add a note (optional)"
          aria-label="Add a note"
          maxLength={maxNote}
          value={note}
          onChange={(e) => setNote(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && picked.size > 0 && !busy && void send()}
        />
        <div className="dialog-buttons">
          <span className="spacer" />
          <button className="btn ghost" onClick={close}>Cancel</button>
          <button className="btn primary" disabled={busy || picked.size === 0} onClick={() => void send()}>
            {busy ? 'Sending…' : ids.length === 1 ? `Send to ${nameFor(ids[0])}` : ids.length > 1 ? `Send to ${ids.length} friends` : 'Send'}
          </button>
        </div>
      </div>
    </div>
  )
}

/** The Inbox tab in the side panel: songs friends sent you, newest first. */
export function InboxPanel(): JSX.Element {
  const account = useStore(accountStore)
  const items = useStore(inboxStore)
  // Open: everything in it is seen (on every device), and a fresh look.
  useEffect(() => {
    void drift.refreshInbox()
  }, [])
  useEffect(() => {
    const unseen = items.filter((i) => !i.seen).map((i) => i.id)
    if (!unseen.length) return
    const t = window.setTimeout(() => void drift.inboxSeen(unseen), 1500)
    return () => window.clearTimeout(t)
  }, [items])
  if (!account.linked) return <div className="queue-panel"><NotLinked /></div>
  return (
    <div className="queue-panel inbox-panel">
      {items.length === 0 ? (
        <div className="empty small">Songs friends send you show up here. Send one from any song’s menu: Send to a friend.</div>
      ) : (
        items.map((i) => <InboxRow key={i.id} item={i} />)
      )}
    </div>
  )
}

function InboxRow({ item }: { item: InboxItem }): JSX.Element {
  const p = usePlayer()
  const t = item.track
  const playing = p.current?.id === t.id && p.playing
  const liked = isLiked(t.id)
  return (
    <article className={`inbox-item ${item.seen ? '' : 'new'}`}>
      <div className="inbox-head">
        <UserAvatar user={{ username: item.fromName, displayName: item.fromName }} size={24} />
        <span className="inbox-from"><b>{item.fromName}</b> sent you a song · {timeAgo(item.at)}</span>
        <IconButton icon="close" label="Clear" size={14} onClick={() => void drift.inboxClear(item.id)} />
      </div>
      {item.note && <p className="inbox-note">{item.note}</p>}
      <div className="inbox-song">
        <TrackArt track={t} size={40} radius={4} />
        <div className="inbox-text">
          <div className="inbox-title">{t.title}</div>
          <div className="inbox-artist">{t.artist}</div>
        </div>
        {!t.podcast && (
          <button className={`like-btn ${liked ? 'on' : ''}`} aria-label={liked ? 'Remove from Liked songs' : 'Save to Liked songs'} onClick={() => toggleLike(t)}>
            <Icon name={liked ? 'heartFill' : 'heart'} size={16} />
          </button>
        )}
        <button
          className="inbox-play"
          aria-label={playing ? 'Pause' : `Play ${t.title}`}
          onClick={() => (p.current?.id === t.id ? toggle() : playList([t], 0, { kind: 'song', name: t.title }, { shuffle: false }))}
        >
          <Icon name={playing ? 'pause' : 'play'} size={16} />
        </button>
      </div>
    </article>
  )
}
