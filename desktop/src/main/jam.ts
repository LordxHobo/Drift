// Listen Together: one shared document per session (jams/{code}) with what plays, where and whether.
// Everyone's own Drift plays the music; this keeps them in step. Changes are sent as they happen and
// the session is checked every 2 seconds. Friends see the code on your profile and can join.
import type { JamChange, JamState, Track } from '@shared/types'
import { FirebaseError, FV } from './firebase'
import * as account from './account'
import * as store from './store'

let code: string | undefined
let state: JamState | undefined
let timer: NodeJS.Timeout | undefined
/** This computer's clock minus the server's (ms), from the quickest round trip so far. */
let offset = 0
let bestTrip = Infinity

const letters = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
const newCode = (): string => Array.from({ length: 6 }, () => letters[Math.floor(Math.random() * letters.length)]).join('')
const path = (c: string): string => `jams/${c}`

function link(): NonNullable<ReturnType<typeof account.linked>> {
  const l = account.linked()
  if (!l) throw new Error('Link your phone first (Settings), so friends can find you.')
  return l
}

/** Learns how far this clock is from the server's, from a write's own time stamp. */
async function timed<T extends string | undefined>(write: () => Promise<T>): Promise<T> {
  const sent = Date.now()
  const updateTime = await write()
  const back = Date.now()
  const server = updateTime ? Date.parse(updateTime) : NaN
  if (Number.isFinite(server) && back - sent < bestTrip) {
    bestTrip = back - sent
    offset = (sent + back) / 2 - server
  }
  return updateTime
}

const serverNow = (): number => Date.now() - offset

function parse(c: string, doc: any, me: string): JamState | undefined {
  const f = doc?.fields
  const host = FV.string(f, 'host')
  if (!host) return undefined
  const names: Record<string, string> = {}
  for (const [k, v] of Object.entries(FV.mapFields(f, 'names') ?? {})) {
    const s = (v as any)?.stringValue
    if (typeof s === 'string') names[k] = s
  }
  const json = <T>(k: string, fallback: T): T => {
    try {
      return JSON.parse(FV.string(f, k) ?? '') as T
    } catch {
      return fallback
    }
  }
  return {
    code: c,
    host,
    members: FV.stringArray(f, 'members'),
    names,
    track: json<Track | null>('track', null),
    queue: json<Track[]>('queue', []),
    playing: FV.bool(f, 'playing') ?? false,
    position: Number(f?.position?.doubleValue ?? f?.position?.integerValue ?? 0),
    at: FV.int(f, 'at') ?? 0,
    version: FV.int(f, 'version') ?? 0,
    updatedBy: FV.string(f, 'updatedBy') ?? host,
    offset,
    me
  }
}

function emit(): void {
  if (state) store.emit('jam', { ...state, offset })
}

function namesFields(names: Record<string, string>): unknown {
  const out: Record<string, unknown> = {}
  for (const [k, v] of Object.entries(names)) out[k] = FV.s(v)
  return FV.map(out)
}

/** Shows the code on your profile, so friends can join from their Friends list. */
async function showOnProfile(c: string | null): Promise<void> {
  const l = account.linked()
  if (!l) return
  await l.db.patch(`users/${l.uid}`, { jam: c ? FV.s(c) : FV.null() }, { mask: ['jam'] }).catch(() => undefined)
}

function startPolling(): void {
  clearInterval(timer)
  timer = setInterval(() => void poll(), 2000)
}

async function poll(): Promise<void> {
  const l = account.linked()
  if (!l || !code) return
  try {
    const doc = await l.db.get(path(code))
    const s = doc ? parse(code, doc, l.uid) : undefined
    if (!s || !s.members.includes(l.uid)) return end()
    state = s
    emit()
  } catch {
    // try again in a moment
  }
}

function end(): void {
  const was = code
  clearInterval(timer)
  code = undefined
  state = undefined
  if (was) {
    store.emit('jamEnded', was)
    void showOnProfile(null)
  }
}

export async function startJam(): Promise<JamState> {
  const l = link()
  if (code) await leaveJam()
  const me = account.getAccount().username ?? 'Someone'
  for (let attempt = 0; attempt < 5; attempt++) {
    const c = newCode()
    try {
      await timed(() =>
        l.db.patch(
          path(c),
          {
            host: FV.s(l.uid), members: FV.strings([l.uid]), names: namesFields({ [l.uid]: me }),
            track: FV.s('null'), queue: FV.s('[]'), playing: FV.b(false), position: { doubleValue: 0 },
            at: FV.i(Date.now() - offset), version: FV.i(1), updatedBy: FV.s(l.uid), createdAt: FV.i(Date.now())
          },
          { mustNotExist: true }
        )
      )
    } catch (e) {
      if (e instanceof FirebaseError && (e.status === 409 || e.status === 400)) continue // code taken
      throw e
    }
    code = c
    await poll()
    await showOnProfile(c)
    startPolling()
    return state!
  }
  throw new Error('Couldn’t start a session. Try again.')
}

export async function joinJam(raw: string): Promise<JamState> {
  const l = link()
  const c = raw.trim().toUpperCase().replace(/[^A-Z0-9]/g, '')
  if (c === code && state) return state
  if (code) await leaveJam()
  for (let attempt = 0; attempt < 3; attempt++) {
    const doc = await l.db.get(path(c)).catch((e) => {
      throw e instanceof FirebaseError && e.status === 403 ? new Error('No session with that code.') : e
    })
    if (!doc) throw new Error('No session with that code. It may have ended.')
    const s = parse(c, doc, l.uid)
    if (!s) throw new Error('No session with that code.')
    if (!s.members.includes(l.uid)) {
      const names = { ...s.names, [l.uid]: account.getAccount().username ?? 'Someone' }
      try {
        await timed(() =>
          l.db.patch(path(c), { members: FV.strings([...s.members, l.uid]), names: namesFields(names) }, { mask: ['members', 'names'], updateTime: doc.updateTime })
        )
      } catch (e) {
        if (e instanceof FirebaseError && (e.status === 400 || e.status === 409)) continue // someone else joined at the same moment
        throw e
      }
    }
    code = c
    await poll()
    await showOnProfile(c)
    startPolling()
    if (!state) throw new Error('Couldn’t join. Try again.')
    return state
  }
  throw new Error('Couldn’t join. Try again.')
}

/** Leaving: the host ends it for everyone; anyone else just leaves. */
export async function leaveJam(): Promise<void> {
  const l = account.linked()
  const c = code
  if (!l || !c) return end()
  try {
    if (state?.host === l.uid) {
      await l.db.delete(path(c))
    } else {
      for (let attempt = 0; attempt < 3; attempt++) {
        const doc = await l.db.get(path(c))
        const s: JamState | undefined = doc ? parse(c, doc, l.uid) : undefined
        if (!s) break
        try {
          await l.db.patch(path(c), { members: FV.strings(s.members.filter((m) => m !== l.uid)) }, { mask: ['members'], updateTime: doc.updateTime })
          break
        } catch {
          // someone changed it at the same moment: try again
        }
      }
    }
  } finally {
    end()
  }
}

/** Someone here changed what's playing: send it to everyone. */
export async function publish(change: JamChange): Promise<void> {
  const l = account.linked()
  if (!l || !code || !state) return
  const version = state.version + 1
  const at = serverNow()
  const fields = {
    track: FV.s(JSON.stringify(change.track)),
    queue: FV.s(JSON.stringify(change.queue.slice(0, 30))),
    playing: FV.b(change.playing),
    position: { doubleValue: change.position },
    at: FV.i(at),
    version: FV.i(version),
    updatedBy: FV.s(l.uid)
  }
  state = { ...state, ...change, queue: change.queue.slice(0, 30), at, version, updatedBy: l.uid }
  await timed(() => l.db.patch(path(code!), fields, { mask: Object.keys(fields) })).catch(() => undefined)
}

export function getJam(): JamState | null {
  return state ? { ...state, offset } : null
}
