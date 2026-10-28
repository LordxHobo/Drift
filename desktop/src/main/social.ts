// Friends: profiles, following, what people are listening to, and the playlists they show.
// Same Firestore documents as the phone's SocialStore and PlaylistSharing.
import type { SharedPlaylist, Track, UserProfile } from '@shared/types'
import { FV, FirebaseError, docName } from './firebase'
import { linked, loadProfile } from './account'
import { emit } from './store'

function need(): NonNullable<ReturnType<typeof linked>> {
  const l = linked()
  if (!l) throw new Error('Link your phone first (Settings → Your phone).')
  return l
}

function profile(doc: any): UserProfile | null {
  const f = doc?.fields
  const username = FV.string(f, 'username')
  if (!username) return null
  const avatar = FV.data(f, 'avatar')
  const np = FV.mapFields(f, 'nowPlaying')
  let nowPlaying: Track | undefined
  const npId = FV.string(np, 'id')
  const npTitle = FV.string(np, 'title')
  if (npId && npTitle) {
    nowPlaying = {
      id: npId,
      title: npTitle,
      artist: FV.string(np, 'artist') ?? '',
      duration: FV.int(np, 'duration') ?? null,
      artworkURL: FV.string(np, 'artwork') ?? null,
      podcast: FV.bool(np, 'podcast') ?? null
    }
  }
  return {
    id: docName(doc),
    username,
    avatar: avatar ? `data:image/jpeg;base64,${avatar}` : undefined,
    following: FV.stringArray(f, 'following'),
    shareActivity: FV.bool(f, 'shareActivity') ?? true,
    nowPlaying,
    playing: FV.bool(f, 'playing') ?? false,
    updatedAt: FV.int(f, 'updatedAt')
  }
}

/** Playing right now (a recent update while playing), not just the last thing played. */
export function listeningNow(u: UserProfile): boolean {
  if (!u.playing || !u.nowPlaying || !u.updatedAt) return false
  const allowance = (u.nowPlaying.duration ?? 0) + 15 * 60
  return Date.now() / 1000 - u.updatedAt < allowance
}

let meCache: UserProfile | null = null

export async function me(): Promise<UserProfile | null> {
  const l = linked()
  if (!l) return null
  const doc = await l.db.get(`users/${l.uid}`)
  meCache = doc ? profile(doc) : null
  emit('me', meCache)
  return meCache
}

export async function user(id: string): Promise<UserProfile | null> {
  const doc = await need().db.get(`users/${id}`)
  return doc ? profile(doc) : null
}

/** Everyone you follow: listening now first, then most recent. */
export async function friends(): Promise<UserProfile[]> {
  const { db } = need()
  const mine = await me()
  if (!mine?.following.length) return []
  const docs = await db.batchGet(mine.following.map((id) => `users/${id}`))
  return docs
    .map(profile)
    .filter((u): u is UserProfile => !!u)
    .sort((a, b) => {
      const la = listeningNow(a)
      const lb = listeningNow(b)
      if (la !== lb) return la ? -1 : 1
      return (b.updatedAt ?? 0) - (a.updatedAt ?? 0)
    })
}

export async function followers(id?: string): Promise<UserProfile[]> {
  const { db, uid } = need()
  const docs = await db.query({
    from: [{ collectionId: 'users' }],
    where: { fieldFilter: { field: { fieldPath: 'following' }, op: 'ARRAY_CONTAINS', value: FV.s(id ?? uid) } },
    limit: 200
  })
  return docs.map(profile).filter((u): u is UserProfile => !!u)
}

/** Usernames starting with what was typed. */
export async function searchUsers(text: string): Promise<UserProfile[]> {
  const { db, uid } = need()
  const q = text.toLowerCase().replace(/[^a-z0-9_.]/g, '')
  if (!q) return []
  const docs = await db.query({
    from: [{ collectionId: 'users' }],
    where: {
      compositeFilter: {
        op: 'AND',
        filters: [
          { fieldFilter: { field: { fieldPath: 'usernameLower' }, op: 'GREATER_THAN_OR_EQUAL', value: FV.s(q) } },
          { fieldFilter: { field: { fieldPath: 'usernameLower' }, op: 'LESS_THAN', value: FV.s(q + '') } }
        ]
      }
    },
    orderBy: [{ field: { fieldPath: 'usernameLower' } }],
    limit: 20
  })
  return docs.map(profile).filter((u): u is UserProfile => !!u && u.id !== uid)
}

export async function followUser(id: string, follow: boolean): Promise<UserProfile | null> {
  const { db, uid } = need()
  if (id === uid) return meCache
  // Start from the latest list, so a follow made on the phone meanwhile isn't lost.
  const mine = await me()
  if (!mine) return null
  const list = mine.following.filter((x) => x !== id)
  if (follow) list.push(id)
  await db.patch(`users/${uid}`, { following: FV.strings(list) }, { mask: ['following'] })
  meCache = { ...mine, following: list }
  emit('me', meCache)
  return meCache
}

export async function setShareActivity(on: boolean): Promise<void> {
  const { db, uid } = need()
  await db.patch(`users/${uid}`, { shareActivity: FV.b(on) }, { mask: ['shareActivity'] })
  if (meCache) meCache = { ...meCache, shareActivity: on }
  emit('me', meCache)
  lastPublished = undefined
  if (lastTrack !== undefined) void publishActivity(lastTrack, lastPlaying)
}

// MARK: Sharing what's playing

let privateSession = false
let lastPublished: string | undefined
let lastTrack: Track | null | undefined
let lastPlaying = false

/** Hides activity until Drift closes. */
export function setPrivateSession(on: boolean): void {
  privateSession = on
  lastPublished = undefined
  if (lastTrack !== undefined) void publishActivity(lastTrack, lastPlaying)
}

export async function publishActivity(track: Track | null, playing: boolean): Promise<void> {
  lastTrack = track
  lastPlaying = playing
  const l = linked()
  if (!l) return
  if (!meCache) await me().catch(() => null)
  const hidden = !(meCache?.shareActivity ?? true) || privateSession
  const t = hidden ? null : track
  const isPlaying = !hidden && playing
  const signature = `${t?.id ?? '-'}|${isPlaying}|${hidden}`
  if (signature === lastPublished) return
  const fields: Record<string, unknown> = { playing: FV.b(isPlaying), updatedAt: FV.i(Math.floor(Date.now() / 1000)) }
  const mask = ['playing', 'updatedAt']
  if (hidden) {
    fields.nowPlaying = FV.null()
    mask.push('nowPlaying')
  } else if (t) {
    const np: Record<string, unknown> = { id: FV.s(t.id), title: FV.s(t.title), artist: FV.s(t.artist), podcast: FV.b(!!t.podcast) }
    np.artwork = FV.s(t.artworkURL ?? `https://i.ytimg.com/vi/${t.id}/hqdefault.jpg`)
    if (t.duration) np.duration = FV.i(t.duration)
    fields.nowPlaying = FV.map(np)
    mask.push('nowPlaying')
  }
  try {
    await l.db.patch(`users/${l.uid}`, fields, { mask })
    lastPublished = signature
  } catch {
    // tried again on the next change
  }
}

// MARK: Shared playlists

interface Compact {
  i: string
  t: string
  a: string
  d?: number | null
  w?: string | null
  p?: boolean | null
}

function decodeTracks(s: string | undefined): Track[] {
  if (!s) return []
  try {
    const list = JSON.parse(s) as Compact[]
    return list.map((x) => ({ id: x.i, title: x.t, artist: x.a, duration: x.d ?? null, artworkURL: x.w ?? null, podcast: x.p ?? null }))
  } catch {
    return []
  }
}

export async function sharedPlaylists(u: UserProfile): Promise<SharedPlaylist[]> {
  const docs = await need().db.list(`users/${u.id}/playlists`, ['name', 'position', 'count', 'duration', 'style', 'colorIndex', 'symbol', 'cover', 'preview'])
  return docs
    .map((d) => {
      const f = d.fields
      const name = FV.string(f, 'name')
      if (!name) return null
      const style = FV.string(f, 'style')
      return {
        p: {
          id: docName(d),
          ownerId: u.id,
          ownerName: u.username,
          name,
          count: FV.int(f, 'count') ?? 0,
          duration: FV.int(f, 'duration') ?? 0,
          colorIndex: FV.int(f, 'colorIndex') ?? 0,
          style: style === 'color' || style === 'photo' ? style : 'auto',
          cover: FV.data(f, 'cover'),
          preview: decodeTracks(FV.string(f, 'preview'))
        } as SharedPlaylist,
        position: FV.int(f, 'position') ?? 0
      }
    })
    .filter((x): x is { p: SharedPlaylist; position: number } => !!x)
    .sort((a, b) => a.position - b.position)
    .map((x) => x.p)
}

export async function sharedPlaylistTracks(ownerId: string, id: string): Promise<Track[]> {
  const doc = await need().db.get(`users/${ownerId}/playlists/${id}`)
  return decodeTracks(FV.string(doc?.fields, 'tracks'))
}

// MARK: Editing your profile (same rules as the phone)

export function usernameProblem(name: string): string | null {
  if (name.length < 3) return 'At least 3 characters'
  if (name.length > 20) return 'At most 20 characters'
  if (!/^[a-z0-9_.]+$/.test(name)) return 'Only letters, numbers, . and _'
  if (name.startsWith('.') || name.endsWith('.')) return 'Can’t start or end with a dot'
  return null
}

/** true = free (or already yours), false = taken, null = couldn't check. */
export async function usernameAvailable(name: string): Promise<boolean | null> {
  const { db, uid } = need()
  try {
    const doc = await db.get(`usernames/${name}`)
    if (!doc) return true
    return FV.string(doc.fields, 'uid') === uid
  } catch {
    return null
  }
}

export async function updateProfile(change: { username?: string; avatar?: string | null }): Promise<UserProfile | null> {
  const { db, uid } = need()
  const mine = await me()
  if (!mine) throw new Error('No profile found.')
  if (change.username !== undefined && change.username !== mine.username) {
    const name = change.username
    const problem = usernameProblem(name)
    if (problem) throw new Error(problem)
    try {
      await db.patch(`usernames/${name}`, { uid: FV.s(uid) }, { mustNotExist: true })
    } catch (e) {
      if (e instanceof FirebaseError && (e.status === 400 || e.status === 409)) throw new Error('That username was just taken.')
      throw e
    }
    await db.patch(`users/${uid}`, { username: FV.s(name), usernameLower: FV.s(name) }, { mask: ['username', 'usernameLower'] })
    await db.delete(`usernames/${mine.username}`).catch(() => undefined)
  }
  if (change.avatar !== undefined) {
    await db.patch(`users/${uid}`, { avatar: change.avatar ? FV.bytes(change.avatar) : FV.null() }, { mask: ['avatar'] })
  }
  await loadProfile()
  return me()
}
