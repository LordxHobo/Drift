// Collaborative playlists: one shared document per playlist (collabs/{playlist id}) that every member
// can change. Each device remembers the list as it last saw it there, so only its own changes are
// sent, merged into the newest list (see shared/collabMerge.ts; the phone does the same).
import type { CollabInfo, CoverStyle, Playlist, Track } from '@shared/types'
import { hasLocalChanges, mergeName, mergeTracks } from '@shared/collabMerge'
import { FirebaseError, FV, docName } from './firebase'
import * as account from './account'
import * as store from './store'

/** What the server had when this device last synced each playlist. */
interface Base {
  updateTime: string
  ids: string[]
  name: string
  /** The cover as it was here after the last sync (to notice a change here), and when the shared cover
   * last changed (to notice a change by someone else). */
  coverSig?: string
  coverAt?: number
}

const stateFile = 'collab-state.json'
let bases: Record<string, Base> | undefined
/** Playlists left here (so they don't come back before the server has caught up). */
let left = new Set<string>()

function load(): Record<string, Base> {
  if (!bases) {
    const s = store.readJSON<{ bases?: Record<string, Base>; left?: string[] }>(stateFile, {})
    bases = s.bases ?? {}
    left = new Set(s.left ?? [])
  }
  return bases
}

function save(): void {
  store.writeJSON(stateFile, { bases: load(), left: [...left] })
}

interface Remote {
  id: string
  updateTime: string
  info: CollabInfo
  name: string
  colorIndex: number
  tracks: Track[]
  coverStyle: CoverStyle | null
  coverSymbol: string | null
  cover: string | null
  coverAt: number
}

function parse(doc: any): Remote | undefined {
  const f = doc?.fields
  const id = docName(doc)
  const owner = FV.string(f, 'owner')
  const tracks = account.decodeTracks(FV.string(f, 'tracks'))
  if (!id || !owner || !tracks || typeof doc.updateTime !== 'string') return undefined
  const names: Record<string, string> = {}
  for (const [k, v] of Object.entries(FV.mapFields(f, 'names') ?? {})) {
    const s = (v as any)?.stringValue
    if (typeof s === 'string') names[k] = s
  }
  return {
    id,
    updateTime: doc.updateTime,
    info: { owner, members: FV.stringArray(f, 'members'), names },
    name: FV.string(f, 'name') ?? 'Playlist',
    colorIndex: FV.int(f, 'colorIndex') ?? 0,
    tracks,
    coverStyle: (FV.string(f, 'coverStyle') as CoverStyle | undefined) || null,
    coverSymbol: FV.string(f, 'coverSymbol') || null,
    cover: FV.data(f, 'cover') ?? null,
    coverAt: FV.int(f, 'coverAt') ?? 0
  }
}

function infoFields(info: CollabInfo): Record<string, unknown> {
  const names: Record<string, unknown> = {}
  for (const [k, v] of Object.entries(info.names)) names[k] = FV.s(v)
  return { owner: FV.s(info.owner), members: FV.strings(info.members), names: FV.map(names) }
}

function myName(): string {
  return account.myName()
}

/** Takes the server's version as it is (nothing changed here). */
function adopt(r: Remote): void {
  const local = store.getLibrary().playlists.find((p) => p.id === r.id)
  const p: Playlist = local
    ? { ...local, name: r.name, tracks: r.tracks, collab: r.info }
    : { id: r.id, name: r.name, tracks: r.tracks, colorIndex: r.colorIndex, collab: r.info }
  store.setCollabPlaylist(p)
  const old = load()[r.id]
  load()[r.id] = { updateTime: r.updateTime, ids: r.tracks.map((t) => t.id), name: r.name, coverSig: old?.coverSig, coverAt: old?.coverAt }
  // A cover set by someone else (or the shared one, the first time).
  if (r.coverAt && (!local || r.coverAt !== old?.coverAt)) adoptCover(r)
}

// MARK: The cover (colour, symbol or photo): whoever changed it last wins

function coverSig(p: Playlist | undefined): string {
  if (!p) return ''
  return `${p.coverStyle ?? 'auto'}|${p.coverSymbol ?? ''}|${p.colorIndex}|${p.cover ? `${p.cover.length}:${p.cover.slice(-24)}` : ''}`
}

const findPlaylist = (id: string): Playlist | undefined => store.getLibrary().playlists.find((p) => p.id === id)

function adoptCover(r: Remote): void {
  store.setCollabCover(r.id, { coverStyle: r.coverStyle ?? 'auto', coverSymbol: r.coverSymbol, colorIndex: r.colorIndex, cover: r.cover })
  const b = load()[r.id]
  if (b) {
    b.coverAt = r.coverAt
    b.coverSig = coverSig(findPlaylist(r.id))
  }
}

async function sendCover(p: Playlist): Promise<void> {
  const link = account.linked()
  if (!link) return
  const now = Date.now()
  const photo = p.coverStyle === 'photo' ? p.cover ?? null : null
  const updateTime = await link.db.patch(
    `collabs/${p.id}`,
    {
      coverStyle: FV.s(p.coverStyle === 'photo' && !photo ? 'auto' : p.coverStyle ?? 'auto'),
      coverSymbol: FV.s(p.coverSymbol ?? ''),
      colorIndex: FV.i(p.colorIndex),
      cover: photo ? FV.bytes(photo) : FV.null(),
      coverAt: FV.i(now)
    },
    { mask: ['coverStyle', 'coverSymbol', 'colorIndex', 'cover', 'coverAt'] }
  )
  const b = load()[p.id]
  if (b) {
    b.coverAt = now
    b.coverSig = coverSig(p)
    if (updateTime) b.updateTime = updateTime
  }
}

/** After the songs: a cover changed here goes up; one changed by someone else comes down. */
async function syncCover(r: Remote): Promise<void> {
  const base = load()[r.id]
  const local = findPlaylist(r.id)
  if (!base || !local) return
  const now = coverSig(local)
  if (base.coverSig === undefined) {
    base.coverSig = now // first sync with covers: remember how it is now
    if (r.coverAt) base.coverAt = r.coverAt
  } else if (base.coverSig !== now) {
    await sendCover(local)
  } else if (r.coverAt && r.coverAt !== (base.coverAt ?? 0)) {
    adoptCover(r)
  }
}

// MARK: Syncing

let running = false
let again = false
let timer: NodeJS.Timeout | undefined

export function startCollab(): void {
  // Local edits: send them a moment later. Every so often: look for changes from the others.
  store.onLibraryChange(() => {
    if (store.getLibrary().playlists.some((p) => p.collab)) schedule(2000)
  })
  setInterval(() => schedule(0), 30_000)
  setTimeout(() => schedule(0), 4000)
}

/** A shared playlist on screen: checked every few seconds (the window says which, or null). */
let watchTimer: NodeJS.Timeout | undefined
export function watch(id: string | null): void {
  clearInterval(watchTimer)
  watchTimer = undefined
  if (!id) return
  schedule(0)
  watchTimer = setInterval(() => schedule(0), 4000)
}

/** Syncs right away (and waits for it). */
export async function syncNow(): Promise<void> {
  clearTimeout(timer)
  if (running) {
    again = true
    while (running) await new Promise((r) => setTimeout(r, 50))
    return
  }
  await run()
}

export function schedule(ms: number): void {
  clearTimeout(timer)
  timer = setTimeout(() => void run(), ms)
}

async function run(): Promise<void> {
  if (running) {
    again = true
    return
  }
  running = true
  try {
    do {
      again = false
      await sync().catch(() => undefined)
    } while (again)
  } finally {
    running = false
  }
}

async function sync(): Promise<void> {
  const link = account.linked()
  if (!link) return
  const { db, uid } = link
  const docs = await db.query({
    from: [{ collectionId: 'collabs' }],
    where: { fieldFilter: { field: { fieldPath: 'members' }, op: 'ARRAY_CONTAINS', value: { stringValue: uid } } }
  })
  const remotes = docs.map(parse).filter((r): r is Remote => !!r)
  const b = load()
  const seen = new Set<string>()

  for (const r of remotes) {
    seen.add(r.id)
    if (left.has(r.id)) continue
    const local = store.getLibrary().playlists.find((p) => p.id === r.id)
    const base = b[r.id]
    if (!local || !base) {
      // New (invited, or made collaborative on another device of yours).
      adopt(r)
      continue
    }
    if (hasLocalChanges(base.ids, base.name, local.tracks, local.name)) {
      await send(r, local, base)
    } else if (r.updateTime !== base.updateTime) {
      adopt(r)
    } else if (JSON.stringify(local.collab) !== JSON.stringify(r.info)) {
      store.setCollabInfo(r.id, r.info)
    }
    await syncCover(r).catch(() => undefined)
  }

  // Shared playlists that are gone (stopped by their owner, or you were removed).
  for (const p of store.getLibrary().playlists) {
    if (!p.collab || seen.has(p.id)) continue
    if (p.collab.owner === uid) store.setCollabInfo(p.id, null) // yours: it's a normal playlist again
    else store.deletePlaylist(p.id)
    delete b[p.id]
  }
  for (const id of [...left]) if (!seen.has(id)) left.delete(id)
  save()
}

/** Sends this device's changes, merged into the newest version (tries again if someone was quicker). */
async function send(remote: Remote, local: Playlist, base: Base): Promise<void> {
  const link = account.linked()
  if (!link) return
  let r = remote
  for (let attempt = 0; attempt < 3; attempt++) {
    const tracks = mergeTracks(base.ids, local.tracks, r.tracks, link.uid)
    const name = mergeName(base.name, local.name, r.name)
    const names = { ...r.info.names, [link.uid]: myName() }
    try {
      const updateTime = await link.db.patch(
        `collabs/${r.id}`,
        { name: FV.s(name), tracks: FV.s(account.tracksJSON(tracks)), names: infoFields({ ...r.info, names }).names, updatedAt: FV.i(Date.now()), updatedBy: FV.s(link.uid) },
        { mask: ['name', 'tracks', 'names', 'updatedAt', 'updatedBy'], updateTime: r.updateTime }
      )
      adopt({ ...r, name, tracks, info: { ...r.info, names }, updateTime: updateTime ?? r.updateTime })
      return
    } catch (e) {
      if (!(e instanceof FirebaseError) || (e.status !== 400 && e.status !== 409 && e.status !== 412)) throw e
      // Someone else changed it first: merge into their version instead.
      const fresh = parse(await link.db.get(`collabs/${r.id}`))
      if (!fresh) return
      r = fresh
    }
  }
}

// MARK: Sharing, inviting, leaving

/** Makes one of your playlists collaborative (you're the owner). */
export async function share(id: string, invite: { id: string; username: string }[]): Promise<void> {
  const link = account.linked()
  if (!link) throw new Error('Link your phone first (Settings), so friends can find you.')
  const p = store.getLibrary().playlists.find((x) => x.id === id)
  if (!p) return
  if (p.collab) return setMembers(id, invite)
  const names: Record<string, string> = { [link.uid]: myName() }
  for (const f of invite) names[f.id] = f.username
  const info: CollabInfo = { owner: link.uid, members: [link.uid, ...invite.map((f) => f.id)], names }
  const tracks = p.tracks.map((t) => ({ ...t, addedBy: t.addedBy ?? link.uid }))
  const updateTime = await link.db.patch(
    `collabs/${id}`,
    { ...infoFields(info), name: FV.s(p.name), tracks: FV.s(account.tracksJSON(tracks)), colorIndex: FV.i(p.colorIndex), createdAt: FV.i(Date.now()), updatedAt: FV.i(Date.now()), updatedBy: FV.s(link.uid) },
    { mustNotExist: true }
  )
  left.delete(id)
  store.setCollabPlaylist({ ...p, tracks, collab: info })
  load()[id] = { updateTime: updateTime ?? '', ids: tracks.map((t) => t.id), name: p.name, coverSig: '', coverAt: 0 } // '' = send the cover next sync
  save()
}

/** The owner changes who's in it. */
export async function setMembers(id: string, people: { id: string; username: string }[]): Promise<void> {
  const link = account.linked()
  if (!link) return
  const r = parse(await link.db.get(`collabs/${id}`))
  if (!r || r.info.owner !== link.uid) return
  const names: Record<string, string> = { [link.uid]: myName() }
  for (const f of people) names[f.id] = f.username
  const info: CollabInfo = { owner: link.uid, members: [link.uid, ...people.map((f) => f.id).filter((x) => x !== link.uid)], names }
  const updateTime = await link.db.patch(`collabs/${id}`, infoFields(info), { mask: ['owner', 'members', 'names'], updateTime: r.updateTime })
  store.setCollabInfo(id, info)
  const base = load()[id]
  if (base && updateTime) base.updateTime = updateTime
  save()
}

/** A member leaves (the playlist goes from their library). */
export async function leave(id: string): Promise<void> {
  const link = account.linked()
  if (!link) return
  const r = parse(await link.db.get(`collabs/${id}`))
  if (r && r.info.owner !== link.uid) {
    const members = r.info.members.filter((m) => m !== link.uid)
    await link.db.patch(`collabs/${id}`, { members: FV.strings(members) }, { mask: ['members'], updateTime: r.updateTime })
  }
  left.add(id)
  delete load()[id]
  store.deletePlaylist(id)
  save()
}

/** The owner stops sharing: the playlist is a normal one again (and goes from everyone else's library). */
export async function stop(id: string): Promise<void> {
  const link = account.linked()
  if (!link) return
  await link.db.delete(`collabs/${id}`)
  delete load()[id]
  store.setCollabInfo(id, null)
  save()
}
