// "Listening to" on Discord, through the Discord app running on this computer (its local
// Rich Presence connection). Needs a Discord application ID (Settings → Connections).
import { connect, type Socket } from 'node:net'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import type { ConnectionState, PlayerPresence } from '@shared/types'
import { getSettings } from './store'

let socket: Socket | undefined
let ready = false
let connecting = false
let connectedId = ''
let buffer = Buffer.alloc(0)
let status: ConnectionState = { state: 'off' }
let onStatus: (s: ConnectionState) => void = () => {}
let pending: PlayerPresence | undefined
let lastKey = ''
let retry: NodeJS.Timeout | undefined

export function discordStatus(): ConnectionState {
  return status
}

export function onDiscordStatus(f: (s: ConnectionState) => void): void {
  onStatus = f
}

function setStatus(s: ConnectionState): void {
  status = s
  onStatus(s)
}

function pipes(): string[] {
  const out: string[] = []
  for (let i = 0; i < 10; i++) {
    if (process.platform === 'win32') {
      out.push(`\\\\?\\pipe\\discord-ipc-${i}`)
    } else {
      const base = process.env.XDG_RUNTIME_DIR || process.env.TMPDIR || process.env.TMP || process.env.TEMP || '/tmp'
      // Normal, Flatpak and Snap installs of Discord.
      for (const dir of [base, join(base, 'app/com.discordapp.Discord'), join(base, 'snap.discord')]) out.push(join(dir, `discord-ipc-${i}`))
    }
  }
  return out
}

function frame(op: number, data: unknown): Buffer {
  const json = Buffer.from(JSON.stringify(data))
  const head = Buffer.alloc(8)
  head.writeInt32LE(op, 0)
  head.writeInt32LE(json.length, 4)
  return Buffer.concat([head, json])
}

function disconnect(): void {
  socket?.destroy()
  socket = undefined
  ready = false
  connecting = false
  lastKey = ''
}

function tryPipe(paths: string[], i: number, appId: string): void {
  if (i >= paths.length) {
    connecting = false
    setStatus({ state: 'error', message: 'Discord isn’t running on this computer (or Rich Presence is off in Discord).' })
    clearTimeout(retry)
    retry = setTimeout(() => pending && updateDiscord(pending), 30_000)
    return
  }
  const s = connect(paths[i])
  s.once('error', () => {
    s.destroy()
    tryPipe(paths, i + 1, appId)
  })
  s.once('connect', () => {
    socket = s
    connectedId = appId
    buffer = Buffer.alloc(0)
    s.write(frame(0, { v: 1, client_id: appId }))
    s.on('data', (chunk: Buffer) => {
      buffer = Buffer.concat([buffer, chunk])
      while (buffer.length >= 8) {
        const op = buffer.readInt32LE(0)
        const len = buffer.readInt32LE(4)
        if (buffer.length < 8 + len) break
        let msg: any
        try {
          msg = JSON.parse(buffer.subarray(8, 8 + len).toString())
        } catch {
          msg = undefined
        }
        buffer = buffer.subarray(8 + len)
        if (op === 1 && msg?.evt === 'READY') {
          ready = true
          connecting = false
          setStatus({ state: 'ok', message: `Connected to Discord${msg.data?.user?.username ? ` as ${msg.data.user.username}` : ''}` })
          if (pending) updateDiscord(pending)
        } else if (op === 1 && msg?.evt === 'ERROR') {
          setStatus({ state: 'error', message: `Discord: ${msg.data?.message ?? 'error'}` })
        } else if (op === 2) {
          setStatus({ state: 'error', message: `Discord closed the connection${msg?.message ? `: ${msg.message}` : ''}. Check the application ID.` })
          disconnect()
        } else if (op === 3) {
          s.write(frame(4, msg)) // ping → pong
        }
      }
    })
    s.on('close', () => {
      if (socket === s) {
        disconnect()
        if (status.state === 'ok') setStatus({ state: 'error', message: 'Discord was closed.' })
      }
    })
  })
}

function setActivity(activity: Record<string, unknown> | null): void {
  if (!socket || !ready) return
  socket.write(frame(1, { cmd: 'SET_ACTIVITY', args: { pid: process.pid, activity }, nonce: randomUUID() }))
}

export function updateDiscord(p: PlayerPresence, privateSession = false): void {
  pending = p
  const s = getSettings()
  const appId = s.discordAppId.trim()
  if (!s.discordEnabled || !/^\d{15,22}$/.test(appId)) {
    if (socket) {
      setActivity(null)
      disconnect()
    }
    setStatus(s.discordEnabled ? { state: 'error', message: 'Add your Discord application ID.' } : { state: 'off' })
    return
  }
  if (socket && connectedId !== appId) disconnect()
  if (!socket) {
    if (!connecting) {
      connecting = true
      setStatus({ state: 'waiting', message: 'Connecting to Discord…' })
      tryPipe(pipes(), 0, appId)
    }
    return
  }
  if (!ready) return

  const t = p.track
  if (!t || !p.playing || privateSession) {
    if (lastKey !== 'none') setActivity(null)
    lastKey = 'none'
    return
  }
  // Only resend on a new song, play/pause or a jump (the timestamps keep the bar moving).
  const start = Math.round(Date.now() / 1000 - p.position)
  const key = `${t.id}|${Math.round(start / 3)}`
  if (key === lastKey) return
  lastKey = key
  const url = t.upload || t.podcast ? `https://www.youtube.com/watch?v=${t.id}` : `https://music.youtube.com/watch?v=${t.id}`
  setActivity({
    type: 2, // Listening
    status_display_type: 1, // "Listening to <song>" in the member list
    details: t.title.slice(0, 128),
    state: (t.artist || 'Drift').slice(0, 128),
    timestamps: p.duration > 0 ? { start, end: Math.round(start + p.duration) } : { start },
    assets: {
      large_image: t.artworkURL ?? `https://i.ytimg.com/vi/${t.id}/hqdefault.jpg`,
      large_text: (t.album || t.title).slice(0, 128)
    },
    buttons: [{ label: t.podcast ? 'Watch on YouTube' : 'Open on YouTube Music', url }],
    instance: false
  })
}

export function clearDiscord(): void {
  if (socket && ready) setActivity(null)
}

