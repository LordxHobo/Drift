// Sharing what's playing with an Orbit server (the user's own Discord-like app).
//
// Drift sends a small JSON "activity" to the Orbit server whenever something changes, plus a
// heartbeat every 60 seconds while playing. Orbit clears it by itself if heartbeats stop.
// The full contract is described in ORBIT.md next to this app's source.
import { app, net, safeStorage } from 'electron'
import { join } from 'node:path'
import { existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import type { ConnectionState, PlayerPresence } from '@shared/types'
import { getSettings } from './store'

const tokenFile = (): string => join(app.getPath('userData'), 'orbit-token.bin')
let token: string | undefined
let tokenLoaded = false

export function getToken(): string | undefined {
  if (!tokenLoaded) {
    tokenLoaded = true
    try {
      const raw = readFileSync(tokenFile())
      token = raw.subarray(0, 5).toString() === 'PLAIN' ? raw.subarray(5).toString() : safeStorage.decryptString(raw)
    } catch {
      token = undefined
    }
  }
  return token || undefined
}

export function setToken(t: string): void {
  token = t.trim() || undefined
  tokenLoaded = true
  if (!token) {
    if (existsSync(tokenFile())) rmSync(tokenFile())
  } else {
    writeFileSync(tokenFile(), safeStorage.isEncryptionAvailable() ? safeStorage.encryptString(token) : Buffer.from('PLAIN' + token), { mode: 0o600 })
  }
  sentState = undefined
}

let status: ConnectionState = { state: 'off' }
let onStatus: (s: ConnectionState) => void = () => {}

export function orbitStatus(): ConnectionState {
  return status
}

export function onOrbitStatus(f: (s: ConnectionState) => void): void {
  onStatus = f
}

function setStatus(s: ConnectionState): void {
  status = s
  onStatus(s)
}

/** How long Orbit should keep showing the activity without hearing from Drift. */
const expiresInMs = 180_000
const heartbeatMs = 60_000

/** What Orbit was last told (to send only real changes). */
let sentState: { id: string; playing: boolean; position: number; at: number } | undefined
let cleared = true
let heartbeat: NodeJS.Timeout | undefined
let current: PlayerPresence | undefined
let hidden = false

function endpoint(): string | undefined {
  const base = getSettings().orbitUrl.trim().replace(/\/+$/, '')
  if (!/^https?:\/\//i.test(base)) return undefined
  return `${base}/api/integrations/drift/activity`
}

/** The activity Orbit shows ("Listening to Drift"). */
function body(p: PlayerPresence): Record<string, unknown> {
  const t = p.track!
  const now = Date.now()
  return {
    app: 'Drift',
    type: t.podcast ? 'podcast' : 'listening',
    state: p.playing ? 'playing' : 'paused',
    track: {
      id: t.id,
      title: t.title,
      artist: t.artist,
      album: t.album ?? null,
      artworkUrl: t.artworkURL ?? `https://i.ytimg.com/vi/${t.id}/hqdefault.jpg`,
      durationMs: p.duration > 0 ? Math.round(p.duration * 1000) : null,
      url: t.upload || t.podcast ? `https://www.youtube.com/watch?v=${t.id}` : `https://music.youtube.com/watch?v=${t.id}`
    },
    positionMs: Math.round(p.position * 1000),
    // When the song would have started, for a live progress bar (only while playing).
    startedAt: p.playing ? Math.round(now - p.position * 1000) : null,
    sentAt: now,
    expiresInMs
  }
}

async function send(method: 'PUT' | 'DELETE', payload?: Record<string, unknown>): Promise<void> {
  const url = endpoint()
  const t = getToken()
  if (!url || !t) {
    setStatus({ state: 'error', message: !url ? 'Add the Orbit server address.' : 'Add your Orbit token.' })
    return
  }
  try {
    const res = await net.fetch(url, {
      method,
      headers: {
        Authorization: `Bearer ${t}`,
        'Content-Type': 'application/json',
        'User-Agent': `Drift/${app.getVersion()}`,
        'X-Drift-Activity-Version': '1'
      },
      body: payload ? JSON.stringify(payload) : undefined
    })
    if (res.status === 401 || res.status === 403) return setStatus({ state: 'error', message: 'Orbit didn’t accept the token. Make a new one in Orbit and paste it here.' })
    if (res.status === 404) return setStatus({ state: 'error', message: 'This Orbit server doesn’t support Drift yet (404).' })
    if (res.status === 429) return setStatus({ state: 'error', message: 'Orbit asked Drift to slow down; it tries again shortly.' })
    if (res.status >= 400) return setStatus({ state: 'error', message: `Orbit answered ${res.status}.` })
    setStatus({ state: 'ok', message: method === 'DELETE' ? 'Connected · nothing playing' : 'Connected · sharing what’s playing' })
  } catch (e) {
    setStatus({ state: 'error', message: `Couldn’t reach Orbit: ${e instanceof Error ? e.message : e}` })
  }
}

function stopHeartbeat(): void {
  clearInterval(heartbeat)
  heartbeat = undefined
}

function clear(): void {
  if (!cleared) void send('DELETE')
  cleared = true
  sentState = undefined
}

function share(p: PlayerPresence): void {
  sentState = { id: p.track!.id, playing: p.playing, position: p.position, at: Date.now() }
  cleared = false
  void send('PUT', body(p))
}

/** A new song, play/pause, or a jump of more than a few seconds. */
function changed(p: PlayerPresence): boolean {
  if (!sentState) return true
  if (sentState.id !== p.track!.id || sentState.playing !== p.playing) return true
  const expected = sentState.position + (sentState.playing ? (Date.now() - sentState.at) / 1000 : 0)
  return Math.abs(expected - p.position) > 3
}

/** Called on every player change (and every 30 s while playing). */
export function updateOrbit(p: PlayerPresence, privateSession: boolean): void {
  current = p
  hidden = privateSession
  if (!getSettings().orbitEnabled) {
    // Turned off: clear what Orbit shows.
    if (status.state !== 'off') {
      clear()
      setStatus({ state: 'off' })
    }
    stopHeartbeat()
    return
  }
  if (!p.track || hidden) {
    clear()
    stopHeartbeat()
    return
  }
  if (changed(p)) share(p)
  if (p.playing && !heartbeat) {
    heartbeat = setInterval(() => {
      if (current?.track && current.playing && !hidden && getSettings().orbitEnabled) share(current)
    }, heartbeatMs)
  } else if (!p.playing) {
    stopHeartbeat()
  }
}

/** Settings → Test: sends what's playing now (or clears it). */
export async function testOrbit(): Promise<void> {
  setStatus({ state: 'waiting', message: 'Connecting…' })
  if (current?.track && !hidden) {
    sentState = { id: current.track.id, playing: current.playing, position: current.position, at: Date.now() }
    cleared = false
    await send('PUT', body(current))
  } else {
    cleared = true
    await send('DELETE')
  }
}

/** Drift is closing: clear what Orbit shows. */
export async function clearOrbit(): Promise<void> {
  if (getSettings().orbitEnabled && !cleared) await send('DELETE').catch(() => undefined)
}
