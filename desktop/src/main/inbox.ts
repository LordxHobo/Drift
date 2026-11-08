// Songs sent to friends: sending them (from a song's menu) and the inbox of ones friends sent you.
// Each is a document at users/{them}/inbox/{you}_{ms}; the server only accepts it when you follow each
// other and they allow it. Same documents as the phone's (iPhone and Android).
import type { InboxItem, Track } from '@shared/types'
import { nameOf } from '@shared/types'
import { BrowserWindow, Notification } from 'electron'
import * as account from './account'
import { FV, docName } from './firebase'
import { emit } from './store'
import { cachedMe, me } from './social'

/** Songs stay in the inbox this long. */
const keepFor = 30 * 86_400_000
/** A note is at most this long (the server checks it too). */
export const maxNote = 280

let items: InboxItem[] = []
let timer: NodeJS.Timeout | undefined
let checking = false
/** Ones already shown as a notification (each only once). */
const notified = new Set<string>()
let firstCheck = true

/** What travels with a sent song: what's needed to play it, nothing from your library. */
function songOnly(t: Track): Track {
  const s: Track = { id: t.id, title: t.title, artist: t.artist }
  if (t.album) s.album = t.album
  if (t.duration) s.duration = t.duration
  if (t.artworkURL) s.artworkURL = t.artworkURL
  if (t.explicit) s.explicit = t.explicit
  if (t.upload) s.upload = t.upload
  if (t.chosen) s.chosen = t.chosen
  if (t.podcast) {
    s.podcast = true
    if (t.channelID) s.channelID = t.channelID
    if (t.channelAvatar) s.channelAvatar = t.channelAvatar
    if (t.published) s.published = t.published
    if (t.audioURL) s.audioURL = t.audioURL
    if (t.feedURL) s.feedURL = t.feedURL
  }
  return s
}

/** Sends a song to these friends (profile ids), with an optional note. Returns the ids it couldn't send to. */
export async function sendSong(friendIds: string[], track: Track, note: string): Promise<string[]> {
  const l = account.linked()
  if (!l) throw new Error('Link your phone first (Settings), so friends can find you.')
  const mine = cachedMe() ?? (await me())
  const text = note.trim().slice(0, maxNote)
  const failed: string[] = []
  for (const id of friendIds) {
    const at = Date.now()
    try {
      await l.db.patch(`users/${id}/inbox/${l.uid}_${at}`, {
        from: FV.s(l.uid),
        fromName: FV.s(mine ? nameOf(mine) : 'A friend'),
        track: FV.s(JSON.stringify(songOnly(track))),
        ...(text ? { note: FV.s(text) } : {}),
        at: FV.i(at)
      }, { mustNotExist: true })
    } catch {
      failed.push(id)
    }
  }
  return failed
}

function parse(doc: any): InboxItem | null {
  const f = doc?.fields
  const from = FV.string(f, 'from')
  const raw = FV.string(f, 'track')
  if (!from || !raw) return null
  let track: Track
  try {
    track = JSON.parse(raw)
  } catch {
    return null
  }
  if (!track?.id || !track.title) return null
  return {
    id: docName(doc),
    from,
    fromName: FV.string(f, 'fromName') ?? 'A friend',
    track,
    note: FV.string(f, 'note') ?? '',
    at: FV.int(f, 'at') ?? 0,
    seen: FV.bool(f, 'seen') ?? false
  }
}

export const inbox = (): InboxItem[] => items

function set(next: InboxItem[]): void {
  items = next
  emit('inbox', items)
}

async function check(): Promise<void> {
  const l = account.linked()
  if (checking || !l) {
    if (!l && items.length) set([])
    return
  }
  checking = true
  try {
    const docs = await l.db.list(`users/${l.uid}/inbox`)
    const now = Date.now()
    const next: InboxItem[] = []
    for (const d of docs) {
      const i = parse(d)
      if (!i) continue
      // Old ones are cleared.
      if (now - i.at > keepFor) {
        void l.db.delete(`users/${l.uid}/inbox/${i.id}`).catch(() => undefined)
        continue
      }
      next.push(i)
    }
    next.sort((a, b) => b.at - a.at)
    // A notification for each new one (not for what was already there when Drift opened).
    for (const i of next) {
      if (notified.has(i.id)) continue
      notified.add(i.id)
      if (!firstCheck && !i.seen) notify(i)
    }
    firstCheck = false
    if (JSON.stringify(next) !== JSON.stringify(items)) set(next)
  } catch {
    // offline: try again next time
  } finally {
    checking = false
  }
}

/** Marks these as seen (on every device). */
export async function markSeen(ids: string[]): Promise<void> {
  const l = account.linked()
  if (!l) return
  const todo = items.filter((i) => ids.includes(i.id) && !i.seen)
  if (!todo.length) return
  set(items.map((i) => (ids.includes(i.id) ? { ...i, seen: true } : i)))
  for (const i of todo) await l.db.patch(`users/${l.uid}/inbox/${i.id}`, { seen: FV.b(true) }, { mask: ['seen'] }).catch(() => undefined)
}

/** Clears one from the inbox (on every device). */
export async function clear(id: string): Promise<void> {
  const l = account.linked()
  if (!l) return
  set(items.filter((i) => i.id !== id))
  await l.db.delete(`users/${l.uid}/inbox/${id}`).catch(() => undefined)
}

/** Drift isn't the window in front: a system notification. */
function notify(i: InboxItem): void {
  const win = BrowserWindow.getAllWindows()[0]
  if ((win && win.isVisible() && win.isFocused()) || !Notification.isSupported()) return
  const n = new Notification({
    title: `${i.fromName} sent you a song`,
    body: `“${i.track.title}” by ${i.track.artist}${i.note ? ` · ${i.note}` : ''}`
  })
  n.on('click', () => {
    const w = BrowserWindow.getAllWindows()[0]
    if (!w) return
    if (w.isMinimized()) w.restore()
    w.show()
    w.focus()
    emit('openInbox')
  })
  n.show()
}

/** Looks for new songs every 20 s, and right away when asked (opening the inbox). */
export function startInbox(): void {
  if (timer) return
  timer = setInterval(() => void check(), 20_000)
  setTimeout(() => void check(), 4_000)
}

export const refreshInbox = (): Promise<void> => check()

/** Whether friends can send you songs (the server checks it too). Same setting as on the phones. */
export async function setAllowSongs(on: boolean): Promise<void> {
  const l = account.linked()
  if (!l) return
  await l.db.patch(`users/${l.uid}`, { allowSongs: FV.b(on) }, { mask: ['allowSongs'] })
  await me().catch(() => undefined)
}
