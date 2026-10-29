// Merging edits to a collaborative playlist (the phone does exactly the same, in CollabSync.swift).
//
// Each device remembers the list as it last saw it on the server ("base"). Its own changes are what
// differ between that and its copy now ("local"). Those changes are applied to the newest list on
// the server ("remote"), so two people editing at once both keep their changes.
import type { Track } from './types'

export function mergeTracks(base: string[], local: Track[], remote: Track[], me: string): Track[] {
  const baseSet = new Set(base)
  const localIds = new Set(local.map((t) => t.id))
  const removed = new Set(base.filter((id) => !localIds.has(id)))
  const added = local.filter((t) => !baseSet.has(t.id))

  // Songs removed here stay removed.
  let result = remote.filter((t) => !removed.has(t.id))

  // Moved here: the songs this device knew about take its order, in the places they hold now
  // (so songs others added in the meantime stay where they are).
  const commonLocal = local.filter((t) => baseSet.has(t.id)).map((t) => t.id)
  const commonBase = base.filter((id) => localIds.has(id))
  if (commonLocal.join(',') !== commonBase.join(',')) {
    const order = new Map(commonLocal.map((id, i) => [id, i]))
    const known = result.filter((t) => order.has(t.id)).sort((a, b) => order.get(a.id)! - order.get(b.id)!)
    let k = 0
    result = result.map((t) => (order.has(t.id) ? known[k++] : t))
  }

  // Added here: after the song it follows here (or at the start), marked as added by this person.
  for (const t of added) {
    if (result.some((x) => x.id === t.id)) continue
    const i = local.findIndex((x) => x.id === t.id)
    const before = i > 0 ? local[i - 1].id : null
    const at = before === null ? 0 : result.findIndex((x) => x.id === before)
    const place = before === null ? 0 : at >= 0 ? at + 1 : result.length
    result.splice(place, 0, { ...t, addedBy: t.addedBy ?? me })
  }
  return result
}

/** The name: renamed here wins, otherwise the server's. */
export function mergeName(baseName: string, localName: string, remoteName: string): string {
  return localName !== baseName ? localName : remoteName
}

/** Has this device changed anything since it last saw the server's list? */
export function hasLocalChanges(base: string[], baseName: string, local: Track[], localName: string): boolean {
  return localName !== baseName || base.join(',') !== local.map((t) => t.id).join(',')
}
