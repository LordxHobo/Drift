// Drift's own notifications on this computer (import reports), like the phone's notification list.
import { Notification } from 'electron'
import { randomUUID } from 'node:crypto'
import type { AppNotice, MissingSong } from '@shared/types'
import * as store from './store'

let items: AppNotice[] | undefined
let show: () => void = () => {}

/** How to bring Drift's window to the front (set once by the app). */
export function setShowWindow(f: () => void): void {
  show = f
}

function load(): AppNotice[] {
  items ??= store.readJSON<AppNotice[]>('notifications.json', [])
  return items
}

function save(): void {
  store.writeJSON('notifications.json', load())
  store.emit('notifications', load())
}

export function getNotifications(): AppNotice[] {
  return load()
}

export function post(n: Omit<AppNotice, 'id' | 'date' | 'read'>): AppNotice {
  const full: AppNotice = { ...n, id: randomUUID(), date: Date.now(), read: false }
  const list = load()
  list.unshift(full)
  if (list.length > 100) list.length = 100
  save()
  return full
}

export function markAllRead(): void {
  const list = load()
  if (!list.some((n) => !n.read)) return
  for (const n of list) n.read = true
  save()
}

export function remove(id: string): void {
  items = load().filter((n) => n.id !== id)
  save()
}

/** After looking for the missing songs again: keep only the ones still not found. */
export function updateMissing(id: string, missing: MissingSong[], found: number): void {
  const n = load().find((x) => x.id === id)
  if (!n) return
  n.missing = missing
  n.title = missing.length ? `${missing.length} ${missing.length === 1 ? 'song' : 'songs'} still not found` : 'All missing songs found'
  n.detail = `Found ${found} more on another search (added to the playlist).`
  save()
}

/** A notification from the system (Windows, macOS, Linux); clicking it opens Drift (and the report). */
export function system(title: string, body: string, open?: string): void {
  if (!Notification.isSupported()) return
  const note = new Notification({ title, body, silent: false })
  note.on('click', () => {
    show()
    if (open) store.emit('openNotice', open)
  })
  note.show()
}
