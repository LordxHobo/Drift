// Listen Together invites: "Invite to listen together" from a song's menu (pick friends who follow you
// back), and the popup when a friend invites you (join or decline).
import { useEffect, useState } from 'react'
import type { JSX } from 'react'
import type { JamInvite, Track, UserProfile } from '@shared/types'
import { accountStore, drift, Store, toast, useStore } from '../state'
import { Art, Spinner } from '../ui'
import { playList } from '../player'
import { jamStore, joinSession, startSession } from '../jam'
import { resized } from '../util'
import { UserAvatar } from './social'

const cleanMessage = (e: unknown): string =>
  e instanceof Error ? e.message.replace(/^Error invoking remote method '[^']+': (Error: )?/, '') : 'That didn’t work.'

/** The song friends are being invited to listen to. */
export const inviteStore = new Store<Track | null>(null)
/** Invites from friends waiting for an answer (the first is shown). */
const incomingStore = new Store<JamInvite[]>([])

export function openInvite(t: Track): void {
  inviteStore.set(t)
}

/** Listens for invites from the main process. */
export function startInvites(): void {
  drift.on('jamInvite', (i) => {
    // Already in that session: nothing to ask.
    if (jamStore.get()?.code === i.code) return void drift.jamInviteAnswered(i)
    const list = incomingStore.get()
    if (!list.some((x) => x.from === i.from && x.code === i.code)) incomingStore.set([...list, i])
  })
}

export function InviteDialog(): JSX.Element | null {
  const track = useStore(inviteStore)
  const account = useStore(accountStore)
  const [friends, setFriends] = useState<UserProfile[] | null>(null)
  const [picked, setPicked] = useState<Set<string>>(new Set())
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (!track) return
    setFriends(null)
    setPicked(new Set())
    if (account.linked) drift.friends().then(setFriends).catch(() => setFriends([]))
  }, [track])

  if (!track) return null
  const close = (): void => inviteStore.set(null)
  // Only friends who follow you back and accept invites (the server checks this too).
  const invitable = (friends ?? []).filter((f) => !!account.uid && f.following.includes(account.uid) && f.allowInvites !== false)

  const send = async (): Promise<void> => {
    setBusy(true)
    try {
      playList([track], 0, { kind: 'song', name: track.title }, { shuffle: false })
      if (!jamStore.get()) await startSession()
      const code = jamStore.get()?.code
      if (!code) throw new Error('Couldn’t start a session.')
      const ids = [...picked]
      const failed = await drift.jamInvite(ids, code, track)
      const names = (ids: string[]): string => ids.map((id) => invitable.find((f) => f.id === id)?.username ?? 'someone').join(', ')
      if (failed.length) toast(`Drift’s server refused the invite to ${names(failed)}. They may have turned invites off or stopped following you, or the security rules need updating.`)
      const sent = ids.filter((id) => !failed.includes(id))
      if (sent.length) toast(`Invited ${names(sent)} to listen together`)
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
        <h3>Invite to listen together</h3>
        <div className="invite-song">
          <Art src={resized(track.artworkURL ?? `https://i.ytimg.com/vi/${track.id}/mqdefault.jpg`, 120)} seed={track.id} size={44} />
          <div>
            <div className="invite-title">{track.title}</div>
            <div className="invite-artist">{track.artist}</div>
          </div>
        </div>
        <p>Drift plays this song for you all at the same time, each on your own device. Only friends who follow you back and allow invites are shown.</p>
        {!account.linked ? (
          <div className="empty small">Link your phone in Settings first, so friends can find you.</div>
        ) : (
          <div className="collab-list">
            {friends === null ? (
              <div className="empty small"><Spinner size={18} /></div>
            ) : invitable.length === 0 ? (
              <div className="empty small">
                {friends.length ? 'None of the people you follow can be invited yet. They need to follow you back and have invites turned on.' : 'Follow your friends first (Friends), then invite them here.'}
              </div>
            ) : (
              invitable.map((f) => (
                <label key={f.id} className="collab-row">
                  <UserAvatar user={f} size={30} />
                  <span className="collab-name">{f.username}</span>
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
        <div className="dialog-buttons">
          <span className="spacer" />
          <button className="btn ghost" onClick={close}>Cancel</button>
          <button className="btn primary" disabled={busy || picked.size === 0} onClick={() => void send()}>
            {busy ? 'Inviting…' : 'Invite'}
          </button>
        </div>
      </div>
    </div>
  )
}

/** "mira invited you to listen together": join or decline. */
export function IncomingInvite(): JSX.Element | null {
  const list = useStore(incomingStore)
  const [busy, setBusy] = useState(false)
  const invite = list[0]
  if (!invite) return null
  const done = (): void => {
    incomingStore.set(incomingStore.get().slice(1))
    void drift.jamInviteAnswered(invite)
  }
  const join = (): void => {
    setBusy(true)
    joinSession(invite.code)
      .then(() => toast(`Listening together with ${invite.fromName}`))
      .catch((e) => toast(cleanMessage(e)))
      .finally(() => {
        setBusy(false)
        done()
      })
  }
  return (
    <div className="dialog-layer">
      <div className="dialog invite-incoming" onKeyDown={(e) => e.key === 'Escape' && done()} tabIndex={-1}>
        <h3>Listen together?</h3>
        <p>
          {invite.title
            ? <><b>{invite.fromName}</b> invited you to listen to “{invite.title}” by {invite.artist} together.</>
            : <><b>{invite.fromName}</b> invited you to listen together.</>}
        </p>
        <div className="dialog-buttons">
          <span className="spacer" />
          <button className="btn ghost" disabled={busy} onClick={done}>Decline</button>
          <button className="btn primary" disabled={busy} onClick={join}>{busy ? 'Joining…' : 'Join'}</button>
        </div>
      </div>
    </div>
  )
}
