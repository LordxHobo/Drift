// Collaborative playlists: share one of yours with friends (they can add, remove and move songs too),
// change who's in it, leave one, or stop sharing.
import { useEffect, useState } from 'react'
import type { JSX } from 'react'
import type { Playlist, UserProfile } from '@shared/types'
import { accountStore, drift, libraryStore, Store, toast, useStore } from '../state'
import { Spinner } from '../ui'
import { UserAvatar } from './social'

/** The playlist whose collaborators are shown. */
export const collabStore = new Store<string | null>(null)

export function openCollab(id: string): void {
  collabStore.set(id)
}

/** "You, mira and echo" */
export function collabNames(p: Playlist, me?: string): string {
  if (!p.collab) return ''
  const names = p.collab.members.map((m) => (m === me ? 'You' : p.collab!.names[m] ?? 'Someone'))
  return names.length <= 1 ? names.join('') : `${names.slice(0, -1).join(', ')} and ${names.at(-1)}`
}

export function CollabDialog(): JSX.Element | null {
  const id = useStore(collabStore)
  const lib = useStore(libraryStore)
  const account = useStore(accountStore)
  const p = lib.playlists.find((x) => x.id === id)
  const [friends, setFriends] = useState<UserProfile[] | null>(null)
  const [picked, setPicked] = useState<Set<string>>(new Set())
  const [busy, setBusy] = useState(false)
  const me = account.uid
  const owner = !p?.collab || p.collab.owner === me

  useEffect(() => {
    if (!id) return
    setFriends(null)
    setPicked(new Set(p?.collab?.members.filter((m) => m !== me) ?? []))
    if (account.linked) drift.friends().then(setFriends).catch(() => setFriends([]))
  }, [id])

  if (!id || !p) return null
  const close = (): void => collabStore.set(null)
  const run = (task: () => Promise<void>, done: string): void => {
    setBusy(true)
    task()
      .then(() => {
        toast(done)
        close()
      })
      .catch((e) => toast(e instanceof Error ? e.message.replace(/^Error invoking remote method '[^']+': (Error: )?/, '') : 'That didn’t work.'))
      .finally(() => setBusy(false))
  }

  // People to pick from: who you follow, plus anyone already in it.
  const people: { id: string; username: string }[] = [...(friends ?? []).map((f) => ({ id: f.id, username: f.username }))]
  for (const m of p.collab?.members ?? []) {
    if (m !== me && !people.some((x) => x.id === m)) people.push({ id: m, username: p.collab!.names[m] ?? 'Someone' })
  }
  const chosen = people.filter((x) => picked.has(x.id))

  return (
    <div className="dialog-layer" onMouseDown={close}>
      <div className="dialog collab" onMouseDown={(e) => e.stopPropagation()} onKeyDown={(e) => e.key === 'Escape' && close()} tabIndex={-1}>
        <h3>{p.collab ? 'Collaborators' : 'Make collaborative'}</h3>
        <p>
          {p.collab
            ? `“${p.name}” is shared with ${collabNames(p, me)}. Everyone in it can add, remove and move songs.`
            : `Invite friends to “${p.name}”. They can add, remove and move songs too, and see each change.`}
        </p>
        {!account.linked ? (
          <div className="empty small">Link your phone in Settings first, so friends can find you.</div>
        ) : owner ? (
          <div className="collab-list">
            {friends === null ? (
              <div className="empty small"><Spinner size={18} /></div>
            ) : people.length === 0 ? (
              <div className="empty small">Follow your friends first (Friends), then invite them here.</div>
            ) : (
              people.map((f) => (
                <label key={f.id} className="collab-row">
                  <UserAvatar user={friends?.find((x) => x.id === f.id) ?? { username: f.username }} size={30} />
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
        ) : (
          <div className="collab-list">
            {p.collab!.members.map((m) => (
              <div key={m} className="collab-row">
                <UserAvatar user={{ username: p.collab!.names[m] ?? '?' }} size={30} />
                <span className="collab-name">{m === me ? 'You' : p.collab!.names[m] ?? 'Someone'}</span>
                {m === p.collab!.owner && <span className="collab-owner">Owner</span>}
              </div>
            ))}
          </div>
        )}
        <div className="dialog-buttons">
          {p.collab && owner && (
            <button className="btn ghost danger-text" disabled={busy} onClick={() => run(() => drift.collabStop(p.id), 'Stopped sharing. It’s your own playlist again.')}>
              Stop sharing
            </button>
          )}
          {p.collab && !owner && (
            <button className="btn ghost danger-text" disabled={busy} onClick={() => run(() => drift.collabLeave(p.id), `Left “${p.name}”`)}>
              Leave playlist
            </button>
          )}
          <span className="spacer" />
          <button className="btn ghost" onClick={close}>{owner ? 'Cancel' : 'Close'}</button>
          {owner && account.linked && (
            <button
              className="btn primary"
              disabled={busy || (!p.collab && chosen.length === 0)}
              onClick={() => run(() => drift.collabShare(p.id, chosen), p.collab ? 'Collaborators updated' : `“${p.name}” is now collaborative`)}
            >
              {p.collab ? 'Save' : 'Share'}
            </button>
          )}
        </div>
      </div>
    </div>
  )
}
