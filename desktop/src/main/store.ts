// The library and settings, saved in Drift's folder on this computer.
import { app, BrowserWindow } from 'electron'
import { join } from 'node:path'
import { readFileSync, renameSync, writeFileSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
import type {
  AlbumPage, ArtistPage, ArtistRef, DriftEvent, FollowedArtist, Library, NewRelease, Playlist, Settings, Track
} from '@shared/types'
import { nowApple } from '@shared/types'

const path = (name: string): string => join(app.getPath('userData'), name)

function load<T>(name: string, fallback: T): T {
  try {
    return { ...fallback, ...JSON.parse(readFileSync(path(name), 'utf8')) }
  } catch {
    return fallback
  }
}

export function writeJSON(name: string, value: unknown): void {
  const tmp = path(name + '.tmp')
  writeFileSync(tmp, JSON.stringify(value))
  renameSync(tmp, path(name))
}

export function emit(event: DriftEvent, payload?: unknown): void {
  for (const w of BrowserWindow.getAllWindows()) w.webContents.send('drift:event', event, payload)
}

// MARK: Settings

const defaultSettings: Settings = {
  style: 'drift',
  appearance: 'device',
  accent: 0,
  preferOfficialAudio: true,
  volume: 0.8,
  openAtLogin: false
}

let settings: Settings | undefined

export function getSettings(): Settings {
  settings ??= load('settings.json', defaultSettings)
  return settings
}

export function setSettings(change: Partial<Settings>): Settings {
  settings = { ...getSettings(), ...change }
  writeJSON('settings.json', settings)
  if ('openAtLogin' in change && process.platform !== 'linux') {
    app.setLoginItemSettings({ openAtLogin: settings.openAtLogin })
  }
  emit('settings', settings)
  return settings
}

// MARK: Library

let library: Library | undefined
let saveTimer: NodeJS.Timeout | undefined
let changed: () => void = () => {}

/** Called after every change made on this computer (library sync sends it on). */
export function onLocalChange(f: () => void): void {
  changed = f
}

export function getLibrary(): Library {
  library ??= load<Library>('library.json', { liked: [], playlists: [], artists: [], recent: [] })
  return library
}

function save(local = true): void {
  emit('library', getLibrary())
  clearTimeout(saveTimer)
  saveTimer = setTimeout(() => writeJSON('library.json', getLibrary()), 300)
  if (local) changed()
}

export function flush(): void {
  if (saveTimer) {
    clearTimeout(saveTimer)
    writeJSON('library.json', getLibrary())
  }
}

function playlist(id: string): Playlist | undefined {
  return getLibrary().playlists.find((p) => p.id === id)
}

/** Only what the phone knows about a song (keeps files small and syncs cleanly). */
function clean(t: Track): Track {
  const out: Track = { id: t.id, title: t.title, artist: t.artist }
  for (const k of ['album', 'duration', 'artworkURL', 'podcast', 'channelID', 'channelAvatar', 'published', 'upload'] as const) {
    if (t[k] != null) (out as Record<string, unknown>)[k] = t[k]
  }
  return out
}

export function setLiked(t: Track, liked: boolean): void {
  const lib = getLibrary()
  const i = lib.liked.findIndex((x) => x.id === t.id)
  if (liked && i < 0) lib.liked.unshift(clean(t))
  else if (!liked && i >= 0) lib.liked.splice(i, 1)
  else return
  save()
}

export function createPlaylist(name: string, tracks: Track[], extra: Partial<Playlist> = {}): string {
  const lib = getLibrary()
  const p: Playlist = {
    id: randomUUID().toUpperCase(),
    name: name.trim() || `My playlist #${lib.playlists.length + 1}`,
    tracks: tracks.map(clean),
    colorIndex: lib.playlists.length,
    ...extra
  }
  lib.playlists.push(p)
  save()
  return p.id
}

export function addToPlaylist(id: string, tracks: Track[]): void {
  const p = playlist(id)
  if (!p) return
  p.tracks.push(...tracks.map(clean))
  save()
}

export function removeFromPlaylist(id: string, indexes: number[]): void {
  const p = playlist(id)
  if (!p) return
  const drop = new Set(indexes)
  p.tracks = p.tracks.filter((_, i) => !drop.has(i))
  save()
}

export function movePlaylistTrack(id: string, from: number, to: number): void {
  const p = playlist(id)
  if (!p || from === to || !p.tracks[from]) return
  const [t] = p.tracks.splice(from, 1)
  p.tracks.splice(Math.max(0, Math.min(to, p.tracks.length)), 0, t)
  save()
}

export function renamePlaylist(id: string, name: string): void {
  const p = playlist(id)
  if (!p || !name.trim()) return
  p.name = name.trim()
  save()
}

export function deletePlaylist(id: string, local = true): void {
  const lib = getLibrary()
  const before = lib.playlists.length
  lib.playlists = lib.playlists.filter((p) => p.id !== id)
  if (lib.playlists.length !== before) save(local)
}

export function saveAlbum(page: AlbumPage): string {
  const existing = getLibrary().playlists.find((p) => p.isAlbum && p.name === page.title && p.albumArtist === page.artist)
  if (existing) return existing.id
  return createPlaylist(page.title, page.tracks, { isAlbum: true, albumArtist: page.artist })
}

export function follow(artist: ArtistRef, page: ArtistPage | null): void {
  const lib = getLibrary()
  if (lib.artists.some((a) => a.artist.id === artist.id)) return
  const known = [...(page?.albums ?? []), ...(page?.singles ?? [])].map((a) => a.id)
  lib.artists.unshift({
    artist: { id: artist.id, name: page?.name || artist.name, thumbnail: page?.thumbnail ?? artist.thumbnail ?? null },
    followedAt: nowApple(),
    known,
    newReleases: []
  })
  save()
}

export function unfollow(id: string): void {
  const lib = getLibrary()
  lib.artists = lib.artists.filter((a) => a.artist.id !== id)
  save()
}

export function played(t: Track): void {
  const lib = getLibrary()
  lib.recent = [clean(t), ...lib.recent.filter((x) => x.id !== t.id)].slice(0, 30)
  save(false)
}

/** How long a release counts as new (same as the phone). */
const newFor = 30 * 86400

/** Compares a freshly loaded artist page with what was seen before. Returns what's new. */
export function updateArtist(id: string, page: ArtistPage): NewRelease[] {
  const a = getLibrary().artists.find((x) => x.artist.id === id)
  if (!a) return []
  const releases = [...page.albums, ...page.singles]
  const known = new Set(a.known)
  const found: NewRelease[] = []
  if (!known.size) {
    a.known = releases.map((r) => r.id)
  } else {
    for (const r of releases) {
      if (known.has(r.id)) continue
      known.add(r.id)
      const n = { album: r, artistName: page.name, foundAt: nowApple() }
      a.newReleases.unshift(n)
      found.push(n)
    }
    a.known = [...known]
  }
  const cutoff = nowApple() - newFor
  a.newReleases = a.newReleases.filter((n) => n.foundAt >= cutoff)
  if (page.thumbnail) a.artist = { id, name: page.name, thumbnail: page.thumbnail }
  save(false)
  return found
}

// MARK: Changes from other devices (library sync)

export function replaceLiked(list: Track[]): void {
  getLibrary().liked = list
  save(false)
}

/** Followed artists from other devices. Keeps what this computer already knew about each. */
export function replaceFollowed(list: FollowedArtist[]): void {
  const lib = getLibrary()
  lib.artists = list.map((remote) => {
    const mine = lib.artists.find((a) => a.artist.id === remote.artist.id)
    const merged: FollowedArtist = {
      ...remote,
      known: [...(remote.known ?? [])],
      newReleases: [...(remote.newReleases ?? [])]
    }
    if (mine) {
      merged.known = [...new Set([...merged.known, ...mine.known])]
      for (const r of mine.newReleases) {
        if (!merged.newReleases.some((x) => x.album.id === r.album.id)) merged.newReleases.push(r)
      }
    }
    return merged
  })
  save(false)
}

export function applyRemotePlaylist(p: Playlist, position: number): void {
  const lib = getLibrary()
  const i = lib.playlists.findIndex((x) => x.id === p.id)
  if (i >= 0) lib.playlists.splice(i, 1)
  lib.playlists.splice(Math.max(0, Math.min(position, lib.playlists.length)), 0, p)
  save(false)
}
