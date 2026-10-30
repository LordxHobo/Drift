// Linking to the phone's Drift profile, and keeping the library the same on both
// (a port of the phone's LibrarySync.swift: same documents, same rules).
import { app } from 'electron'
import { join } from 'node:path'
import { readFileSync } from 'node:fs'
import { createDecipheriv, createECDH, hkdfSync, randomInt } from 'node:crypto'
import { hostname } from 'node:os'
import type { Account, FollowedArtist, PairingState, Playlist, Track } from '@shared/types'
import { Auth, Firestore, FV, docName, deleteSession, loadSession, saveSession, FirebaseError } from './firebase'
import * as store from './store'
import { artistPage } from './ytmusic'

let auth: Auth | undefined
let db: Firestore | undefined
let account: Account = { linked: false, syncing: false }

function setAccount(change: Partial<Account>): void {
  account = { ...account, ...change }
  store.emit('account', account)
}

/** The linked profile's Firestore access (undefined until linked). */
export function linked(): { db: Firestore; uid: string } | undefined {
  return db && auth?.uid ? { db, uid: auth.uid } : undefined
}

export function getAccount(): Account {
  return account
}

function useSession(s: { uid: string; refreshToken: string }): void {
  auth = new Auth(s, saveSession)
  db = new Firestore(auth)
  setAccount({ linked: true, uid: s.uid, error: undefined })
}

export function start(): void {
  store.onLocalChange(() => schedule(3000, false))
  const s = loadSession()
  if (s) {
    useSession(s)
    void loadProfile()
    refresh(true)
  }
  setInterval(() => refresh(false), 5 * 60_000)
  setTimeout(() => void checkNewReleases(false), 8000)
  setInterval(() => void checkNewReleases(false), 3 * 3600_000)
}

export async function loadProfile(): Promise<void> {
  if (!db || !auth?.uid) return
  try {
    const doc = await db.get(`users/${auth.uid}`)
    const f = doc?.fields
    const avatar = FV.data(f, 'avatar')
    setAccount({ username: FV.string(f, 'username'), displayName: FV.string(f, 'displayName') || undefined, avatar: avatar ? `data:image/jpeg;base64,${avatar}` : undefined })
  } catch {
    // shown again on the next try
  }
}

// MARK: Sync state (what was last sent or received for each document)

interface Synced {
  fingerprint: string
  updatedAt: number
}

const stateFile = (): string => join(app.getPath('userData'), 'sync-state.json')
let synced: Record<string, Synced> = {}
let syncedUID: string | undefined

function loadState(uid: string): void {
  if (syncedUID === uid) return
  syncedUID = uid
  try {
    const s = JSON.parse(readFileSync(stateFile(), 'utf8'))
    synced = s.uid === uid ? s.synced : {}
  } catch {
    synced = {}
  }
}

function saveState(): void {
  if (syncedUID) store.writeJSON('sync-state.json', { uid: syncedUID, synced })
}

// MARK: Scheduling

let timer: NodeJS.Timeout | undefined
let running = false
let again = false
let wantsPull = false
let pulledThisLaunch = false
let lastPull = 0

export function refresh(force: boolean): void {
  if (!force && Date.now() - lastPull < 60_000) return
  schedule(500, true)
}

function schedule(ms: number, pull: boolean): void {
  if (pull) wantsPull = true
  if (running) {
    again = true
    return
  }
  clearTimeout(timer)
  timer = setTimeout(() => void run(), ms)
}

async function run(): Promise<void> {
  running = true
  do {
    again = false
    await sync()
  } while (again)
  running = false
}

export async function syncNow(): Promise<void> {
  wantsPull = true
  if (running) {
    again = true
    return
  }
  clearTimeout(timer)
  await run()
}

async function sync(): Promise<void> {
  if (!db || !auth?.uid) return
  const uid = auth.uid
  loadState(uid)
  setAccount({ syncing: true })
  try {
    if (wantsPull || !pulledThisLaunch) {
      await pull(uid)
      wantsPull = false
      pulledThisLaunch = true
      lastPull = Date.now()
    }
    await push(uid)
    setAccount({ syncing: false, lastSync: Date.now(), error: undefined })
  } catch (e) {
    const message =
      e instanceof FirebaseError && e.status === 403
        ? 'Drift’s server refused the sync. The security rules may need publishing again.'
        : e instanceof Error
          ? e.message
          : 'Couldn’t sync.'
    setAccount({ syncing: false, error: message })
  }
}

// MARK: Fingerprints

function hash(s: string): string {
  let h = 0xcbf29ce484222325n
  for (const b of Buffer.from(s, 'utf8')) {
    h ^= BigInt(b)
    h = (h * 0x100000001b3n) & 0xffffffffffffffffn
  }
  return h.toString(16)
}

function playlistFingerprint(p: Playlist, position: number): string {
  return hash(
    [position, p.name, p.coverStyle ?? 'auto', p.colorIndex, p.coverSymbol ?? '', p.cover ? `${p.cover.length}:${p.cover.slice(-16)}` : '',
      p.isPublic ?? true, p.isAlbum === true, p.albumArtist ?? ''].join('|') +
      '|' + p.tracks.map((t) => t.id).join(',')
  )
}

function currentFingerprint(name: string): string | undefined {
  const lib = store.getLibrary()
  if (name === 'liked') return hash(lib.liked.map((t) => t.id).join(','))
  if (name === 'artists') return hash(lib.artists.map((a) => a.artist.id).join(','))
  const i = lib.playlists.findIndex((p) => `pl-${p.id}` === name)
  return i >= 0 ? playlistFingerprint(lib.playlists[i], i) : undefined
}

/** Songs as JSON text; very large lists drop artwork links to stay under Firestore's 1 MB limit. */
export function tracksJSON(tracks: Track[]): string {
  const full = JSON.stringify(tracks)
  if (Buffer.byteLength(full) < 850_000) return full
  return JSON.stringify(tracks.map((t) => ({ ...t, artworkURL: undefined, channelAvatar: undefined })))
}

export function decodeTracks(s: string | undefined): Track[] | undefined {
  if (!s) return undefined
  try {
    const list = JSON.parse(s)
    return Array.isArray(list) ? list.filter((t) => typeof t?.id === 'string') : undefined
  } catch {
    return undefined
  }
}

// MARK: Pull and push

async function pull(uid: string): Promise<void> {
  const docs = await db!.list(`users/${uid}/library`, ['updatedAt', 'deleted'])
  for (const doc of docs) {
    const name = docName(doc)
    const updatedAt = FV.int(doc.fields, 'updatedAt') ?? 0
    const known = synced[name]
    if (known && known.updatedAt >= updatedAt) continue
    if (FV.bool(doc.fields, 'deleted') === true) {
      // (Not a collaborative one: those come and go with their shared document.)
      const id = name.slice(3)
      if (name.startsWith('pl-') && !store.getLibrary().playlists.some((p) => p.id === id && p.collab)) store.deletePlaylist(id, false)
      synced[name] = { fingerprint: 'deleted', updatedAt }
      continue
    }
    const full = await db!.get(`users/${uid}/library/${name}`)
    if (!full?.fields) continue
    apply(name, full.fields)
    synced[name] = { fingerprint: currentFingerprint(name) ?? '', updatedAt }
  }
  saveState()
}

function apply(name: string, f: any): void {
  const lib = store.getLibrary()
  if (name === 'liked') {
    const remote = decodeTracks(FV.string(f, 'tracks'))
    if (!remote) return
    if (!synced.liked) {
      // First time on this computer: keep both (remote first, then anything only liked here).
      const ids = new Set(remote.map((t) => t.id))
      store.replaceLiked([...remote, ...lib.liked.filter((t) => !ids.has(t.id))])
    } else {
      store.replaceLiked(remote)
    }
  } else if (name === 'artists') {
    let remote: FollowedArtist[]
    try {
      remote = JSON.parse(FV.string(f, 'artists') ?? '')
    } catch {
      return
    }
    if (!Array.isArray(remote)) return
    if (!synced.artists) {
      const ids = new Set(remote.map((a) => a.artist.id))
      store.replaceFollowed([...remote, ...lib.artists.filter((a) => !ids.has(a.artist.id))])
    } else {
      store.replaceFollowed(remote)
    }
  } else if (name.startsWith('pl-')) {
    // Collaborative playlists sync through their shared document instead.
    if (lib.playlists.some((x) => x.id === name.slice(3) && x.collab)) return
    const title = FV.string(f, 'name')
    const tracks = decodeTracks(FV.string(f, 'tracks'))
    if (!title || !tracks) return
    const style = FV.string(f, 'style')
    const p: Playlist = {
      id: name.slice(3),
      name: title,
      tracks,
      colorIndex: FV.int(f, 'colorIndex') ?? 0,
      coverStyle: style === 'color' || style === 'photo' ? style : style === 'auto' ? 'auto' : null,
      coverSymbol: FV.string(f, 'symbol') ?? null,
      isPublic: FV.bool(f, 'isPublic') ?? null,
      isAlbum: FV.bool(f, 'isAlbum') === true ? true : null,
      albumArtist: FV.string(f, 'albumArtist') ?? null,
      cover: FV.data(f, 'cover') ?? null
    }
    store.applyRemotePlaylist(p, FV.int(f, 'position') ?? 0)
  }
}

function documentFields(name: string, updatedAt: number): Record<string, unknown> | undefined {
  const lib = store.getLibrary()
  const f: Record<string, unknown> = { updatedAt: FV.i(updatedAt), deleted: FV.b(false) }
  if (name === 'liked') {
    f.tracks = FV.s(tracksJSON(lib.liked))
  } else if (name === 'artists') {
    f.artists = FV.s(JSON.stringify(lib.artists))
  } else {
    const i = lib.playlists.findIndex((p) => `pl-${p.id}` === name)
    if (i < 0) return undefined
    const p = lib.playlists[i]
    f.name = FV.s(p.name)
    f.position = FV.i(i)
    f.tracks = FV.s(tracksJSON(p.tracks))
    f.style = FV.s(p.coverStyle ?? 'auto')
    f.colorIndex = FV.i(p.colorIndex)
    f.symbol = FV.s(p.coverSymbol ?? 'music.note.list')
    f.isPublic = FV.b(p.isPublic ?? true)
    f.isAlbum = FV.b(p.isAlbum === true)
    if (p.albumArtist) f.albumArtist = FV.s(p.albumArtist)
    if (p.cover && p.cover.length < 270_000) f.cover = FV.bytes(p.cover)
  }
  return f
}

async function push(uid: string): Promise<void> {
  const now = Date.now()
  const lib = store.getLibrary()
  const items: [string, string][] = []
  for (const name of ['liked', 'artists']) {
    const fp = currentFingerprint(name)
    if (fp) items.push([name, fp])
  }
  // Collaborative playlists sync through their shared document instead (see collab.ts).
  lib.playlists.forEach((p, i) => {
    if (!p.collab) items.push([`pl-${p.id}`, playlistFingerprint(p, i)])
  })

  for (const [name, fp] of items) {
    if (synced[name]?.fingerprint === fp) continue
    const fields = documentFields(name, now)
    if (!fields) continue
    await db!.patch(`users/${uid}/library/${name}`, fields)
    synced[name] = { fingerprint: fp, updatedAt: now }
    saveState()
  }

  // Playlists deleted here: leave a marker so other devices delete them too.
  const present = new Set(lib.playlists.map((p) => `pl-${p.id}`))
  for (const [name, state] of Object.entries(synced)) {
    if (!name.startsWith('pl-') || present.has(name) || state.fingerprint === 'deleted') continue
    await db!.patch(`users/${uid}/library/${name}`, { deleted: FV.b(true), updatedAt: FV.i(now) })
    synced[name] = { fingerprint: 'deleted', updatedAt: now }
    saveState()
  }
}

// MARK: New releases from followed artists

let checking = false

export async function checkNewReleases(force: boolean): Promise<void> {
  const lib = store.getLibrary()
  if (checking || !lib.artists.length) return
  const lastFile = 'releases-check.json'
  let last = 0
  try {
    last = JSON.parse(readFileSync(join(app.getPath('userData'), lastFile), 'utf8')).last ?? 0
  } catch {
    // never checked
  }
  if (!force && Date.now() - last < 3 * 3600_000) return
  checking = true
  try {
    const artists = lib.artists.map((a) => a.artist)
    for (let i = 0; i < artists.length; i += 4) {
      const batch = artists.slice(i, i + 4)
      const pages = await Promise.all(batch.map((a) => artistPage(a.id, a.name).catch(() => undefined)))
      pages.forEach((p, j) => p && store.updateArtist(batch[j].id, p))
    }
    store.writeJSON(lastFile, { last: Date.now() })
  } finally {
    checking = false
  }
}

// MARK: Linking with the phone

let pairing: PairingState = { phase: 'idle' }
let pairingRun = 0

function setPairing(p: PairingState): void {
  pairing = p
  store.emit('pairing', p)
}

export function getPairing(): PairingState {
  return pairing
}

const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'

export function cancelPairing(): void {
  pairingRun++
  if (pairing.phase !== 'done') setPairing({ phase: 'idle' })
}

/**
 * Shows a code; the phone (Settings → Link a computer) answers with its sign-in, encrypted for this
 * computer only (P-256 key exchange + AES-GCM). A short-lived account is used to post the code and is
 * deleted afterwards.
 */
export async function startPairing(): Promise<void> {
  const run = ++pairingRun
  setPairing({ phase: 'starting' })
  const temp = new Auth()
  const tempDB = new Firestore(temp)
  let code = ''
  try {
    const ecdh = createECDH('prime256v1')
    ecdh.generateKeys()
    for (let attempt = 0; attempt < 3 && !code; attempt++) {
      const candidate = Array.from({ length: 8 }, () => alphabet[randomInt(alphabet.length)]).join('')
      try {
        await tempDB.patch(
          `pairings/${candidate}`,
          {
            owner: FV.s(await temp.token().then(() => temp.uid!)),
            desktopKey: FV.bytes(ecdh.getPublicKey().toString('base64')),
            device: FV.s(deviceName()),
            createdAt: FV.i(Date.now())
          },
          { mustNotExist: true }
        )
        code = candidate
      } catch (e) {
        if (!(e instanceof FirebaseError) || (e.status !== 400 && e.status !== 409)) throw e
      }
    }
    if (!code) throw new Error('Couldn’t make a code. Try again.')
    const expires = Date.now() + 10 * 60_000
    setPairing({ phase: 'waiting', code: `${code.slice(0, 4)}-${code.slice(4)}`, expires })

    while (run === pairingRun && Date.now() < expires) {
      await new Promise((r) => setTimeout(r, 2000))
      if (run !== pairingRun) break
      const doc = await tempDB.get(`pairings/${code}`).catch(() => undefined)
      const phoneKey = FV.data(doc?.fields, 'phoneKey')
      const box = FV.data(doc?.fields, 'box')
      if (!phoneKey || !box) continue

      setPairing({ phase: 'linking' })
      const secret = ecdh.computeSecret(Buffer.from(phoneKey, 'base64'))
      const key = Buffer.from(hkdfSync('sha256', secret, Buffer.from(code), Buffer.from('drift-pairing-v1'), 32))
      const sealed = Buffer.from(box, 'base64')
      const decipher = createDecipheriv('aes-256-gcm', key, sealed.subarray(0, 12))
      decipher.setAuthTag(sealed.subarray(sealed.length - 16))
      const plain = Buffer.concat([decipher.update(sealed.subarray(12, sealed.length - 16)), decipher.final()])
      const session = JSON.parse(plain.toString('utf8'))
      if (typeof session?.uid !== 'string' || typeof session?.refreshToken !== 'string') throw new Error('The phone sent something unexpected.')

      // Check the sign-in works before keeping it.
      const linked = new Auth({ uid: session.uid, refreshToken: session.refreshToken })
      await linked.token()
      saveSession(linked.session!)
      useSession(linked.session!)
      await tempDB.delete(`pairings/${code}`).catch(() => undefined)
      await temp.deleteAccount().catch(() => undefined)
      setPairing({ phase: 'done' })
      pulledThisLaunch = false
      synced = {}
      syncedUID = undefined
      void loadProfile()
      void syncNow()
      return
    }
    if (run === pairingRun) setPairing({ phase: 'failed', message: 'The code expired. Make a new one.' })
  } catch (e) {
    if (run === pairingRun) setPairing({ phase: 'failed', message: e instanceof Error ? e.message : 'Linking failed.' })
  }
  // Clean up the code and the short-lived account.
  if (code) await tempDB.delete(`pairings/${code}`).catch(() => undefined)
  if (temp.uid) await temp.deleteAccount().catch(() => undefined)
}

function deviceName(): string {
  const kind = process.platform === 'win32' ? 'Windows' : process.platform === 'darwin' ? 'Mac' : 'Linux'
  const host = hostname().replace(/\.local$/, '')
  return host ? `${host} (${kind})` : `${kind} computer`
}

export function unlink(): void {
  deleteSession()
  auth = undefined
  db = undefined
  synced = {}
  syncedUID = undefined
  pulledThisLaunch = false
  store.writeJSON('sync-state.json', {})
  setPairing({ phase: 'idle' })
  account = { linked: false, syncing: false }
  store.emit('account', account)
}

/** What friends see you as: your display name, or your username. */
export function myName(): string {
  const a = getAccount()
  return a.displayName?.trim() || a.username || 'Someone'
}
