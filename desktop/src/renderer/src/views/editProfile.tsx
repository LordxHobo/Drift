// Edit your Drift profile from the computer: display name, username and photo (same rules as the phone).
import { useEffect, useRef, useState } from 'react'
import type { JSX } from 'react'
import { Icon } from '../icons'
import { drift, meStore, Store, toast, useStore } from '../state'
import { Spinner } from '../ui'
import { UserAvatar } from './social'
import { cleanError } from './common'
import { displayNameLimit } from '@shared/types'

export const editProfileStore = new Store(false)

/** A 160×160 JPEG like the phone makes (base64). */
async function avatarJPEG(file: File): Promise<string> {
  const url = URL.createObjectURL(file)
  try {
    const img = new Image()
    img.src = url
    await img.decode()
    const side = Math.min(img.naturalWidth, img.naturalHeight)
    const c = document.createElement('canvas')
    c.width = c.height = 160
    c.getContext('2d')!.drawImage(img, (img.naturalWidth - side) / 2, (img.naturalHeight - side) / 2, side, side, 0, 0, 160, 160)
    return c.toDataURL('image/jpeg', 0.7).split(',')[1]
  } finally {
    URL.revokeObjectURL(url)
  }
}

function problem(name: string): string | null {
  if (name.length < 3) return 'At least 3 characters'
  if (name.length > 20) return 'At most 20 characters'
  if (name.startsWith('.') || name.endsWith('.')) return 'Can’t start or end with a dot'
  return null
}

export function EditProfileDialog(): JSX.Element | null {
  const open = useStore(editProfileStore)
  const me = useStore(meStore)
  const [name, setName] = useState('')
  const [display, setDisplay] = useState('')
  const [avatar, setAvatar] = useState<string | null | undefined>(undefined) // undefined = unchanged
  const [check, setCheck] = useState<'idle' | 'checking' | 'free' | 'taken' | 'unknown'>('idle')
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string>()
  const file = useRef<HTMLInputElement>(null)

  useEffect(() => {
    if (!open || !me) return
    setName(me.username)
    setDisplay(me.displayName ?? '')
    setAvatar(undefined)
    setError(undefined)
    setCheck('idle')
  }, [open])

  const changedName = !!me && name !== me.username
  useEffect(() => {
    if (!open || !changedName || problem(name)) return setCheck('idle')
    setCheck('checking')
    let alive = true
    const t = window.setTimeout(() => {
      void drift.usernameAvailable(name).then((ok) => alive && setCheck(ok === null ? 'unknown' : ok ? 'free' : 'taken'))
    }, 400)
    return () => {
      alive = false
      clearTimeout(t)
    }
  }, [name, open])

  if (!open || !me) return null
  const close = (): void => editProfileStore.set(false)
  const nameProblem = changedName ? problem(name) : null
  const shownAvatar = avatar === undefined ? me.avatar : avatar ? `data:image/jpeg;base64,${avatar}` : undefined
  const changedDisplay = !!me && display.trim() !== (me.displayName ?? '').trim()
  const canSave = !saving && !nameProblem && check !== 'taken' && check !== 'checking' && (changedName || changedDisplay || avatar !== undefined)

  const save = (): void => {
    if (!canSave) return
    setSaving(true)
    setError(undefined)
    drift
      .updateProfile({
        ...(changedName ? { username: name } : {}),
        ...(changedDisplay ? { displayName: display } : {}),
        ...(avatar !== undefined ? { avatar } : {})
      })
      .then((m) => {
        if (m) meStore.set(m)
        toast('Profile saved')
        close()
      })
      .catch((e) => setError(cleanError(e)))
      .finally(() => setSaving(false))
  }

  return (
    <div className="dialog-layer" onMouseDown={close}>
      <form
        className="dialog edit-profile"
        onMouseDown={(e) => e.stopPropagation()}
        onSubmit={(e) => {
          e.preventDefault()
          save()
        }}
        onKeyDown={(e) => e.key === 'Escape' && close()}
      >
        <h3>Edit profile</h3>
        <div className="edit-body">
          <div className="profile-photo">
            <button type="button" className="edit-cover round" onClick={() => file.current?.click()} title="Choose a photo">
              <UserAvatar user={{ username: name || me.username, displayName: display, avatar: shownAvatar }} size={140} />
              <span className="edit-cover-hint"><Icon name="edit" size={22} /> Choose photo</span>
            </button>
            {shownAvatar && (
              <button type="button" className="link small-link" onClick={() => setAvatar(null)}>Remove photo</button>
            )}
          </div>
          <div className="edit-fields">
            <input
              className="field display-field"
              value={display}
              autoFocus
              maxLength={displayNameLimit}
              onChange={(e) => setDisplay(e.target.value)}
              placeholder="Display name"
            />
            <div className="set-detail">The name friends see. Capitals, spaces and emoji are fine; leave it empty to show your @username.</div>
            <label className="username-field">
              <span>@</span>
              <input
                value={name}
                maxLength={20}
                onChange={(e) => setName(e.target.value.toLowerCase().replace(/[^a-z0-9_.]/g, ''))}
                placeholder="username"
              />
            </label>
            <div className={`set-detail ${nameProblem || check === 'taken' ? 'bad' : check === 'free' ? 'good' : ''}`}>
              {nameProblem ??
                (check === 'checking' ? <><Spinner size={11} /> Checking…</>
                  : check === 'taken' ? 'That username is taken.'
                  : check === 'free' ? 'Available.'
                  : check === 'unknown' ? 'Couldn’t check right now; saving will tell.'
                  : '3–20 characters: letters, numbers, . and _')}
            </div>
            <p className="set-detail">Changes show on your phone and to friends too.</p>
            {error && <div className="set-error">{error}</div>}
          </div>
        </div>
        <input
          ref={file}
          type="file"
          accept="image/*"
          hidden
          onChange={(e) => {
            const f = e.target.files?.[0]
            e.target.value = ''
            if (f) avatarJPEG(f).then(setAvatar).catch(() => toast('That picture couldn’t be used. Try another one.'))
          }}
        />
        <div className="dialog-buttons">
          <button type="button" className="btn ghost" onClick={close}>Cancel</button>
          <button type="submit" className="btn primary" disabled={!canSave}>
            {saving ? <Spinner size={14} /> : null} Save
          </button>
        </div>
      </form>
    </div>
  )
}
