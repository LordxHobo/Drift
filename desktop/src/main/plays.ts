// What you've listened to, for Listening stats. Kept on this computer, and (when linked to your phone) also in
// your synced library, one document per device and month ("plays-<device>-<yyyy-mm>"), so the stats add up
// what you played on every device. Same format as the phone (see PlayHistory.swift).
import { randomBytes } from 'node:crypto'
import type { PlayRecord } from '@shared/stats'
import { decodePlays, encodePlays, minimumListen, playMonth } from '@shared/stats'
import type { Track } from '@shared/types'
import * as account from './account'
import { FV, docName } from './firebase'
import { readJSON, writeJSON } from './store'

interface Stored {
  device: string
  plays: PlayRecord[]
  dirty: string[]
}

let data: Stored | undefined
/** Which play each listen (one song, from when it started) is. */
const listens = new Map<string, number>()
let saveTimer: NodeJS.Timeout | undefined
let uploadTimer: NodeJS.Timeout | undefined

function get(): Stored {
  if (!data) {
    const s = readJSON<Partial<Stored> | null>('plays.json', null)
    data = {
      device: s?.device || `pc${randomBytes(4).toString('hex')}`,
      plays: Array.isArray(s?.plays) ? s!.plays : [],
      dirty: Array.isArray(s?.dirty) ? s!.dirty : []
    }
  }
  return data
}

function save(): void {
  clearTimeout(saveTimer)
  saveTimer = undefined
  writeJSON('plays.json', get())
}

/** The window reports how long a song has been listened to (`key` is one listen of it). */
export function listened(t: Track, key: string, secs: number): void {
  if (secs < minimumListen || t.podcast) return
  const d = get()
  const i = listens.get(key)
  let at: number
  if (i !== undefined && d.plays[i]) {
    d.plays[i].secs = Math.round(secs)
    at = d.plays[i].at
  } else {
    at = Math.round(Date.now() / 1000 - secs)
    const art = t.artworkURL ?? `https://i.ytimg.com/vi/${t.id}/hqdefault.jpg`
    d.plays.push({ id: t.id, title: t.title, artist: t.artist, art, at, secs: Math.round(secs) })
    listens.set(key, d.plays.length - 1)
  }
  const m = playMonth(at)
  if (!d.dirty.includes(m)) d.dirty.push(m)
  saveTimer ??= setTimeout(save, 15_000)
  uploadTimer ??= setTimeout(() => {
    uploadTimer = undefined
    void upload()
  }, 5 * 60_000)
}

async function upload(): Promise<void> {
  const l = account.linked()
  const d = get()
  if (!l || !d.dirty.length) return
  for (const month of [...d.dirty].sort()) {
    const list = d.plays.filter((p) => playMonth(p.at) === month)
    try {
      await l.db.patch(`users/${l.uid}/library/plays-${d.device}-${month}`, {
        plays: FV.s(encodePlays(list)),
        device: FV.s(d.device),
        updatedAt: FV.i(Date.now()),
        deleted: FV.b(false)
      })
      d.dirty = d.dirty.filter((x) => x !== month)
    } catch {
      return
    }
  }
  save()
}

/** Drift is closing: save now (and send what's new, if there's time). */
export function flush(): void {
  if (saveTimer) save()
  if (uploadTimer) {
    clearTimeout(uploadTimer)
    uploadTimer = undefined
    void upload()
  }
}

/** Everything you've listened to: this computer, plus your other devices when linked. */
export async function everything(): Promise<{ plays: PlayRecord[]; devices: number }> {
  const d = get()
  const l = account.linked()
  if (!l) return { plays: d.plays, devices: 1 }
  let docs: any[] = []
  try {
    docs = await l.db.list(`users/${l.uid}/library`, ['plays', 'device'])
  } catch {
    return { plays: d.plays, devices: 1 }
  }
  const plays = [...d.plays]
  const devices = new Set([d.device])
  for (const doc of docs) {
    if (!docName(doc).startsWith('plays-')) continue
    const device = FV.string(doc.fields, 'device')
    if (!device || device === d.device) continue
    devices.add(device)
    plays.push(...decodePlays(FV.string(doc.fields, 'plays')))
  }
  return { plays, devices: devices.size }
}
