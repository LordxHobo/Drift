// Control other device (see shared/remote.ts): tells your other devices what this computer plays, runs
// the commands they send, and sends commands to the one you control from here.
import { hostname } from 'node:os'
import type { RemoteCommand, RemoteDevice, RemoteState } from '@shared/remote'
import * as account from './account'
import { FV } from './firebase'
import { deviceId } from './plays'
import { emit } from './store'

let state: RemoteState | undefined
let changedAt = 0
let lastPublish = 0
let lastPoll = 0
let lastWake = 0
let awakeUntil = 0
let lastCommand: number | undefined
let target: string | null = null
let timer: NodeJS.Timeout | undefined
let busy = false

const name = (): string => {
  const h = hostname().replace(/\.local$/, '')
  return h && h !== 'localhost' ? h : process.platform === 'darwin' ? 'Mac' : process.platform === 'win32' ? 'Windows PC' : 'Computer'
}

/** What plays here now (from the window, whenever it changes). */
export function setState(s: RemoteState): void {
  state = s
  if (!changedAt) changedAt = Date.now()
}

/** The device this computer controls (it's kept checking often), or null. */
export function setTarget(id: string | null): void {
  target = id
  lastWake = 0
}

export function start(): void {
  if (timer) return
  timer = setInterval(() => void step(), 500)
}

async function step(): Promise<void> {
  if (busy || !account.linked()) return
  busy = true
  try {
    const now = Date.now()
    if (now - lastPoll >= (now < awakeUntil ? 1000 : 6000)) {
      lastPoll = now
      await poll()
    }
    if ((changedAt && now - changedAt >= 400) || now - lastPublish >= 30_000) {
      changedAt = 0
      await publish()
    }
    if (target && now - lastWake >= 20_000) {
      lastWake = now
      await wake(target)
    }
  } catch {
    // offline: next time
  } finally {
    busy = false
  }
}

const finite = (n: number): number => (Number.isFinite(n) ? n : 0)

async function publish(): Promise<void> {
  const l = account.linked()
  if (!l || !state) return
  lastPublish = Date.now()
  const d: RemoteDevice = {
    ...state,
    id: deviceId(),
    name: name(),
    kind: 'computer',
    at: Date.now(),
    position: finite(state.position),
    duration: finite(state.duration),
    volume: finite(state.volume)
  }
  const field = `d_${d.id}`
  await l.db.patch(`users/${l.uid}/library/devices`, { [field]: FV.s(JSON.stringify(d)) }, { mask: [field] })
}

async function poll(): Promise<void> {
  const l = account.linked()
  if (!l) return
  let doc: any
  try {
    doc = await l.db.get(`users/${l.uid}/library/remote-${deviceId()}`)
  } catch {
    return
  }
  const f = doc?.fields
  awakeUntil = FV.int(f, 'awakeUntil') ?? 0
  const list = parseCommands(FV.string(f, 'cmds'))
  // First look: what was sent before Drift opened doesn't count.
  if (lastCommand === undefined) {
    lastCommand = Math.max(0, ...list.map((c) => c.id))
    return
  }
  const last = lastCommand
  const fresh = list.filter((c) => c.id > last).sort((a, b) => a.id - b.id)
  if (!fresh.length) return
  lastCommand = fresh[fresh.length - 1].id
  const now = Date.now()
  for (const c of fresh) if (now - c.id / 1000 < 60_000) emit('remoteCommand', c)
  awakeUntil = Math.max(awakeUntil, now + 90_000)
}

function parseCommands(s: string | undefined): RemoteCommand[] {
  try {
    const list = JSON.parse(s ?? '[]')
    return Array.isArray(list) ? list.filter((c) => typeof c?.id === 'number' && typeof c?.type === 'string') : []
  } catch {
    return []
  }
}

/** Your other devices (not this computer), newest first. */
export async function devices(): Promise<RemoteDevice[]> {
  const l = account.linked()
  if (!l) return []
  const doc = await l.db.get(`users/${l.uid}/library/devices`)
  const f = doc?.fields ?? {}
  const me = `d_${deviceId()}`
  const out: RemoteDevice[] = []
  for (const key of Object.keys(f)) {
    if (!key.startsWith('d_') || key === me) continue
    try {
      const d = JSON.parse(FV.string(f, key) ?? '')
      if (typeof d?.id !== 'string') continue
      out.push({ ...d, track: d.track ?? null, queue: Array.isArray(d.queue) ? d.queue : [], repeat: d.repeat ?? 'off' })
    } catch {
      // skip
    }
  }
  return out.sort((a, b) => b.at - a.at)
}

/** Sends a command to another device. */
export async function send(id: string, command: Omit<RemoteCommand, 'id' | 'from'>): Promise<void> {
  const l = account.linked()
  if (!l) throw new Error('Link your phone first (Settings).')
  const c: RemoteCommand = { ...command, id: Date.now() * 1000 + Math.floor(Math.random() * 1000), from: deviceId() }
  const path = `users/${l.uid}/library/remote-${id}`
  let list: RemoteCommand[] = []
  try {
    list = parseCommands(FV.string((await l.db.get(path))?.fields, 'cmds'))
  } catch {
    // a new document
  }
  list = [...list, c].slice(-20)
  await l.db.patch(path, { cmds: FV.s(JSON.stringify(list)), awakeUntil: FV.i(Date.now() + 90_000) }, { mask: ['cmds', 'awakeUntil'] })
}

async function wake(id: string): Promise<void> {
  const l = account.linked()
  if (!l) return
  await l.db.patch(`users/${l.uid}/library/remote-${id}`, { awakeUntil: FV.i(Date.now() + 90_000) }, { mask: ['awakeUntil'] })
}
