// Small shared stores for the window: library, settings, account, navigation and pop-ups.
import { useSyncExternalStore } from 'react'
import type { Account, AppNotice, AlbumRef, ArtistRef, ConnectionsStatus, DownloadsState, PodcastChannel, PodcastsState, SharedPlaylist, UserProfile, ImportState, Library, PairingState, Settings, Track, UpdateState } from '@shared/types'

export class Store<T> {
  private listeners = new Set<() => void>()
  constructor(private value: T) {}
  get = (): T => this.value
  set(v: T): void {
    this.value = v
    for (const l of this.listeners) l()
  }
  update(f: (v: T) => T): void {
    this.set(f(this.value))
  }
  subscribe = (l: () => void): (() => void) => {
    this.listeners.add(l)
    return () => this.listeners.delete(l)
  }
}

export function useStore<T>(s: Store<T>): T {
  return useSyncExternalStore(s.subscribe, s.get)
}

export const drift = window.drift

export const libraryStore = new Store<Library>({ liked: [], playlists: [], artists: [], recent: [] })
export const settingsStore = new Store<Settings>({
  style: 'drift', appearance: 'device', accent: 0, preferOfficialAudio: true, preferExplicit: true, volume: 0.8, openAtLogin: false,
  skipNonMusic: true, skipSponsors: true, podcastSpeed: 1, orbitEnabled: false, orbitUrl: '', discordEnabled: false,
  discordAppId: '', closeToTray: true, podcastVideo: false, videoQuality: 720
})
export const accountStore = new Store<Account>({ linked: false, syncing: false })
export const pairingStore = new Store<PairingState>({ phase: 'idle' })
export const platformStore = new Store<string>('win32')
export const updateStore = new Store<UpdateState>({ phase: 'idle' })
export const importStore = new Store<ImportState>({ phase: 'idle', total: 0, processed: 0, missing: [] })
export const downloadsStore = new Store<DownloadsState>({ done: [], queued: [], active: [], keep: [], bytes: 0, folder: '', rate: 0, failed: [] })
export const podcastsStore = new Store<PodcastsState>({ subscriptions: [], progress: {}, feeds: {}, refreshing: false })
export const connectionsStore = new Store<ConnectionsStatus>({ orbit: { state: 'off', hasToken: false }, discord: { state: 'off' } })
/** Drift's notifications on this computer (import reports). */
export const notificationsStore = new Store<AppNotice[]>([])
/** Asked to open a notification (clicked in the system's notifications). */
export const openNoticeStore = new Store<string | null>(null)
/** Your Drift profile (when linked with the phone). */
export const meStore = new Store<UserProfile | null>(null)
/** Hide what you listen to until Drift closes. */
export const privateSessionStore = new Store(false)
/** The Spotify import window. */
export const importOpenStore = new Store(false)

export async function loadAll(): Promise<void> {
  const [lib, settings, account, pairing, info, update] = await Promise.all([
    drift.library(), drift.settings(), drift.account(), drift.pairing(), drift.appInfo(), drift.updateState()
  ])
  updateStore.set(update)
  drift.on('update', (v) => updateStore.set(v))
  connectionsStore.set(await drift.connections())
  drift.on('connections', (v) => connectionsStore.set(v))
  notificationsStore.set(await drift.notifications())
  drift.on('notifications', (v) => notificationsStore.set(v))
  drift.on('openNotice', (v) => openNoticeStore.set(v))
  podcastsStore.set(await drift.podcasts())
  drift.on('podcasts', (v) => podcastsStore.set(v))
  downloadsStore.set(await drift.downloads())
  drift.on('downloads', (v) => downloadsStore.set(v))
  importStore.set(await drift.importState())
  drift.on('import', (v) => importStore.set(v))
  libraryStore.set(lib)
  settingsStore.set(settings)
  accountStore.set(account)
  pairingStore.set(pairing)
  platformStore.set(info.platform)
  drift.on('library', (v) => libraryStore.set(v))
  drift.on('settings', (v) => settingsStore.set(v))
  drift.on('account', (v) => {
    const was = accountStore.get().linked
    accountStore.set(v)
    if (v.linked && !was) void drift.me().then((m) => meStore.set(m)).catch(() => undefined)
  })
  drift.on('me', (v) => meStore.set(v))
  if (account.linked) void drift.me().then((m) => meStore.set(m)).catch(() => undefined)
  drift.on('pairing', (v) => pairingStore.set(v))
}

export function setSettings(change: Partial<Settings>): void {
  settingsStore.update((s) => ({ ...s, ...change }))
  void drift.setSettings(change)
}

// MARK: Navigation

export type Route =
  | { name: 'home' }
  | { name: 'search'; q?: string }
  | { name: 'artist'; id: string; hint?: ArtistRef }
  | { name: 'album'; id: string; hint?: AlbumRef; exact?: boolean }
  | { name: 'playlist'; id: string }
  | { name: 'liked' }
  | { name: 'collection'; kind: 'artists' | 'albums' | 'songs' | 'recent' | 'playlists' | 'downloaded' }
  | { name: 'song'; track: Track }
  | { name: 'lyrics' }
  | { name: 'settings' }
  | { name: 'friends' }
  | { name: 'video' }
  | { name: 'podcasts'; q?: string }
  | { name: 'channel'; channel: PodcastChannel }
  | { name: 'user'; id: string; hint?: UserProfile }
  | { name: 'shared'; playlist: SharedPlaylist }

interface Nav {
  stack: Route[]
  index: number
}

export const navStore = new Store<Nav>({ stack: [{ name: 'home' }], index: 0 })

export function useRoute(): Route {
  const n = useStore(navStore)
  return n.stack[n.index]
}

export function go(route: Route): void {
  navStore.update((n) => {
    const cur = n.stack[n.index]
    if (JSON.stringify(cur) === JSON.stringify(route)) return n
    // Typing in search replaces the search page instead of piling up history.
    if (cur.name === 'search' && route.name === 'search') {
      const stack = n.stack.slice(0, n.index + 1)
      stack[n.index] = route
      return { stack, index: n.index }
    }
    const stack = [...n.stack.slice(0, n.index + 1), route].slice(-60)
    return { stack, index: stack.length - 1 }
  })
  document.querySelector('.main-scroll')?.scrollTo({ top: 0 })
}

export function back(): void {
  navStore.update((n) => (n.index > 0 ? { ...n, index: n.index - 1 } : n))
}

export function forward(): void {
  navStore.update((n) => (n.index < n.stack.length - 1 ? { ...n, index: n.index + 1 } : n))
}

// MARK: Side panel (lyrics, queue, details)

export type Panel = 'none' | 'lyrics' | 'queue' | 'friends'
export const panelStore = new Store<Panel>(readLocal<Panel>('panel', 'none'))
panelStore.subscribe(() => writeLocal('panel', panelStore.get()))

export function togglePanel(p: Panel): void {
  panelStore.update((cur) => (cur === p ? 'none' : p))
}

/** The full-screen player (Apple Music style). */
export const fullPlayerStore = new Store(false)

// MARK: Pop-ups

export interface MenuItem {
  label: string
  icon?: string
  danger?: boolean
  disabled?: boolean
  checked?: boolean
  action?: () => void
  submenu?: MenuItem[]
  separator?: boolean
}

export const menuStore = new Store<{ x: number; y: number; items: MenuItem[] } | null>(null)

export function openMenu(e: { clientX: number; clientY: number; preventDefault?: () => void; stopPropagation?: () => void }, items: MenuItem[]): void {
  e.preventDefault?.()
  e.stopPropagation?.()
  menuStore.set({ x: e.clientX, y: e.clientY, items })
}

export function openMenuAt(el: HTMLElement, items: MenuItem[]): void {
  const r = el.getBoundingClientRect()
  menuStore.set({ x: r.left, y: r.bottom + 4, items })
}

export type Dialog =
  | { kind: 'prompt'; title: string; value: string; placeholder?: string; confirm: string; onDone: (v: string) => void }
  | { kind: 'confirm'; title: string; message: string; confirm: string; danger?: boolean; onDone: () => void }

export const dialogStore = new Store<Dialog | null>(null)

export const toastStore = new Store<{ id: number; text: string } | null>(null)
let toastTimer: number | undefined

export function toast(text: string): void {
  const id = Date.now()
  toastStore.set({ id, text })
  clearTimeout(toastTimer)
  toastTimer = window.setTimeout(() => toastStore.set(null), 3200)
}

// MARK: Local conveniences

export function readLocal<T>(key: string, fallback: T): T {
  try {
    const v = localStorage.getItem(`drift.${key}`)
    return v == null ? fallback : (JSON.parse(v) as T)
  } catch {
    return fallback
  }
}

export function writeLocal(key: string, value: unknown): void {
  try {
    localStorage.setItem(`drift.${key}`, JSON.stringify(value))
  } catch {
    // storage full or unavailable
  }
}
