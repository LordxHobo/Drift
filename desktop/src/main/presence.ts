// What's playing goes to friends (Drift profiles), Orbit, Discord and the tray from one place.
import type { ConnectionsStatus, PlayerPresence } from '@shared/types'
import * as social from './social'
import { clearOrbit, getToken, onOrbitStatus, orbitStatus, updateOrbit } from './orbit'
import { clearDiscord, discordStatus, onDiscordStatus, updateDiscord } from './discord'
import { updateTray } from './tray'
import { emit } from './store'

let current: PlayerPresence = { track: null, playing: false, position: 0, duration: 0 }
let privateSession = false

export function connections(): ConnectionsStatus {
  return { orbit: { ...orbitStatus(), hasToken: !!getToken() }, discord: discordStatus() }
}

const sendStatus = (): void => emit('connections', connections())
onOrbitStatus(sendStatus)
onDiscordStatus(sendStatus)

export function playerState(p: PlayerPresence): void {
  current = p
  void social.publishActivity(p.track, p.playing)
  updateOrbit(p, privateSession)
  updateDiscord(p, privateSession)
  updateTray(p)
}

export function setPrivateSession(on: boolean): void {
  privateSession = on
  social.setPrivateSession(on)
  playerState(current)
}

/** Settings changed (Orbit or Discord turned on or off, a new address or ID). */
export function settingsChanged(): void {
  updateOrbit(current, privateSession)
  updateDiscord(current, privateSession)
  sendStatus()
}

/** Drift is closing. */
export async function stopPresence(): Promise<void> {
  clearDiscord()
  await Promise.race([
    Promise.all([social.publishActivity(null, false), clearOrbit()]),
    new Promise((r) => setTimeout(r, 1500))
  ])
}
