// Listen Together: start a session, join one (from a friend or with a code), see who's in it, leave.
import { useEffect, useState } from 'react'
import type { JSX } from 'react'
import type { UserProfile } from '@shared/types'
import { Icon } from '../icons'
import { accountStore, drift, Store, toast, useStore } from '../state'
import { IconButton, Spinner } from '../ui'
import { jamStore, joinSession, leaveSession, startSession } from '../jam'
import { UserAvatar } from './social'
import { nameOf } from '@shared/types'

export const jamOpenStore = new Store(false)

const cleanMessage = (e: unknown): string =>
  e instanceof Error ? e.message.replace(/^Error invoking remote method '[^']+': (Error: )?/, '') : 'That didn’t work.'

/** Joins a friend's session (from their profile or the Friends list). */
export function joinFriend(u: UserProfile): void {
  if (!u.jam) return
  joinSession(u.jam)
    .then(() => toast(`Listening together with ${nameOf(u)}`))
    .catch((e) => toast(cleanMessage(e)))
}

/** The player's Listen Together button (lit up, with a count, while in a session). */
export function JamButton(): JSX.Element {
  const s = useStore(jamStore)
  return (
    <span className="jam-button">
      <IconButton icon="together" label={s ? `Listening together (${s.members.length})` : 'Listen together'} active={!!s} size={18} onClick={() => jamOpenStore.set(true)} />
      {s && <span className="jam-count">{s.members.length}</span>}
    </span>
  )
}

export function JamDialog(): JSX.Element | null {
  const open = useStore(jamOpenStore)
  const s = useStore(jamStore)
  const account = useStore(accountStore)
  const [code, setCode] = useState('')
  const [busy, setBusy] = useState(false)
  const [friends, setFriends] = useState<UserProfile[] | null>(null)

  useEffect(() => {
    if (!open || !account.linked) return
    setFriends(null)
    drift.friends().then(setFriends).catch(() => setFriends([]))
  }, [open, account.linked])

  if (!open) return null
  const close = (): void => jamOpenStore.set(false)
  const run = (task: () => Promise<void>): void => {
    setBusy(true)
    task()
      .catch((e) => toast(cleanMessage(e)))
      .finally(() => setBusy(false))
  }
  const inSessions = (friends ?? []).filter((f) => f.jam && f.jam !== s?.code)

  return (
    <div className="dialog-layer" onMouseDown={close}>
      <div className="dialog jam" onMouseDown={(e) => e.stopPropagation()} onKeyDown={(e) => e.key === 'Escape' && close()} tabIndex={-1}>
        <h3>Listen Together</h3>
        {!account.linked ? (
          <p>Link your phone in Settings first, so friends can find you.</p>
        ) : s ? (
          <>
            <p>Everyone hears the same songs at the same time, each on their own device. Anyone can pick songs, play, pause, skip and change what’s next.</p>
            <div className="jam-code">
              <span>{s.code}</span>
              <IconButton icon="copy" label="Copy code" size={16} onClick={() => void navigator.clipboard.writeText(s.code).then(() => toast('Code copied'))} />
            </div>
            <p className="jam-hint">Friends can join from their Friends list, or with this code.</p>
            <div className="collab-list">
              {s.members.map((m) => (
                <div key={m} className="collab-row">
                  <UserAvatar user={{ username: s.names[m] ?? '?' }} size={30} />
                  <span className="collab-name">{m === s.me ? 'You' : s.names[m] ?? 'Someone'}</span>
                  {m === s.host && <span className="collab-owner">Host</span>}
                </div>
              ))}
            </div>
            <div className="dialog-buttons">
              <button className="btn ghost danger-text" disabled={busy} onClick={() => run(async () => { await leaveSession(); close() })}>
                {s.host === s.me ? 'End for everyone' : 'Leave'}
              </button>
              <span className="spacer" />
              <button className="btn primary" onClick={close}>Done</button>
            </div>
          </>
        ) : (
          <>
            <p>Listen to the same songs at the same time as your friends, each on your own phone or computer. Anyone in it can pick songs, play, pause and skip.</p>
            <button className="btn primary jam-start" disabled={busy} onClick={() => run(async () => { await startSession(); toast('Session started') })}>
              <Icon name="together" size={16} /> Start a session
            </button>
            <form
              className="jam-join"
              onSubmit={(e) => {
                e.preventDefault()
                if (code.trim()) run(async () => { await joinSession(code); toast('Joined') })
              }}
            >
              <input className="field" value={code} onChange={(e) => setCode(e.target.value.toUpperCase())} placeholder="Code (e.g. K7QM4X)" maxLength={8} />
              <button className="btn" type="submit" disabled={busy || code.trim().length < 6}>Join</button>
            </form>
            <div className="jam-friends-head">Friends listening together</div>
            <div className="collab-list">
              {friends === null ? (
                <div className="empty small"><Spinner size={18} /></div>
              ) : inSessions.length === 0 ? (
                <div className="empty small">None of your friends are in a session right now.</div>
              ) : (
                inSessions.map((f) => (
                  <div key={f.id} className="collab-row">
                    <UserAvatar user={f} size={30} />
                    <span className="collab-name">{nameOf(f)}</span>
                    <button className="btn small" disabled={busy} onClick={() => run(async () => { await joinSession(f.jam!); toast(`Listening together with ${nameOf(f)}`) })}>
                      Join
                    </button>
                  </div>
                ))
              )}
            </div>
            <div className="dialog-buttons">
              <button className="btn ghost" onClick={close}>Close</button>
            </div>
          </>
        )}
      </div>
    </div>
  )
}
