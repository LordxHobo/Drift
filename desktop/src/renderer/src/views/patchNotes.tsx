// What's new: shown once after an update (the same notes as on the phone, in shared/patchNotes.json).
import { useEffect, useState } from 'react'
import type { JSX } from 'react'
import data from '@shared/patchNotes.json'
import { drift, Store, useStore } from '../state'

/** Set to show every note again (tapping the version in Settings). */
const reopenStore = new Store(0)
export function showPatchNotes(): void {
  reopenStore.set(reopenStore.get() + 1)
}

interface Note {
  text: string
  platforms?: string[]
}
interface Entry {
  id: number
  date: string
  title: string
  notes: Note[]
}

const seenKey = 'drift.patchNotesSeen'
const buildsKey = 'drift.patchNotesBuilds'

/**
 * Which version each note came with: every build brings a new note, so the newest one is this
 * version's. Remembered on this computer, since version numbers are only known once a build is made.
 */
function builds(version: string): Record<string, string> {
  let map: Record<string, string> = {}
  try {
    map = JSON.parse(localStorage.getItem(buildsKey) ?? '{}') ?? {}
  } catch {
    map = {}
  }
  const newest = (data.entries as Entry[])[0]?.id
  if (version && newest !== undefined && !map[newest]) {
    map[newest] = version
    try {
      localStorage.setItem(buildsKey, JSON.stringify(map))
    } catch {
      // nothing to remember it in
    }
  }
  return map
}
const entries = (data.entries as Entry[])
  .map((e) => ({ ...e, notes: e.notes.filter((n) => !n.platforms || n.platforms.includes('desktop')) }))
  .filter((e) => e.notes.length)
const latest = Math.max(0, ...(data.entries as Entry[]).map((e) => e.id))

/** Notes not seen yet: everything newer than the last ones seen (just the latest, the first time). */
function unseen(): Entry[] {
  let seen: number | undefined
  try {
    const v = localStorage.getItem(seenKey)
    if (v != null) seen = Number(v)
  } catch {
    // no storage: show the latest
  }
  return seen === undefined || !Number.isFinite(seen) ? entries.slice(0, 1) : entries.filter((e) => e.id > seen!)
}

function markSeen(): void {
  try {
    localStorage.setItem(seenKey, String(latest))
  } catch {
    // nothing to remember it in
  }
}

const dateText = (d: string): string => new Date(d + 'T12:00:00').toLocaleDateString(undefined, { day: 'numeric', month: 'long', year: 'numeric' })

export function PatchNotes(): JSX.Element | null {
  const [list, setList] = useState<Entry[]>(unseen)
  const reopen = useStore(reopenStore)
  const [versions, setVersions] = useState<Record<string, string>>({})
  useEffect(() => {
    if (reopen) setList(entries)
  }, [reopen])
  useEffect(() => {
    void drift.appInfo().then((i) => setVersions(builds(i.version))).catch(() => undefined)
  }, [])
  if (!list.length) return null
  const close = (): void => {
    markSeen()
    setList([])
  }
  return (
    <div className="dialog-layer" onMouseDown={close}>
      <div className="dialog patch-notes" onMouseDown={(e) => e.stopPropagation()} onKeyDown={(e) => e.key === 'Escape' && close()} tabIndex={-1}>
        <h3>What’s new in Drift</h3>
        <div className="patch-notes-list">
          {list.map((e) => (
            <section key={e.id}>
              <div className="patch-notes-head">
                <span className="patch-notes-title">{e.title}</span>
                <span className="patch-notes-date">{[versions[e.id] && `Version ${versions[e.id]}`, dateText(e.date)].filter(Boolean).join(' · ')}</span>
              </div>
              <ul>
                {e.notes.map((n, i) => (
                  <li key={i}>{n.text}</li>
                ))}
              </ul>
            </section>
          ))}
        </div>
        <div className="dialog-buttons">
          <span className="spacer" />
          <button className="btn primary" onClick={close} autoFocus>Got it</button>
        </div>
      </div>
    </div>
  )
}
