// Control other device: play on your phone from the computer (and the other way round). Same JSON as the
// phone (Drift/Social/RemoteControl.swift). Everything goes through your synced library (only you can
// read it): library/devices has one field per device ("d_<device>") with what it plays, and
// library/remote-<device> the last commands sent to it ("cmds") and until when it should check often
// ("awakeUntil").
import type { Track } from './types'

export interface RemoteDevice {
  id: string
  name: string
  kind: 'phone' | 'computer'
  /** When it last said so (ms since 1970). */
  at: number
  track: Track | null
  /** What comes next (up to 30 songs). */
  queue: Track[]
  playing: boolean
  position: number
  /** When `position` was measured (ms since 1970). */
  positionAt: number
  duration: number
  volume: number
  shuffle: boolean
  repeat: 'off' | 'all' | 'one'
  source?: string
}

export interface RemoteCommand {
  id: number
  from: string
  type: 'transfer' | 'play' | 'toggle' | 'resume' | 'pause' | 'next' | 'previous' | 'seek' | 'volume' | 'shuffle' | 'repeat' | 'playNext' | 'addToQueue'
  track?: Track
  tracks?: Track[]
  queue?: Track[]
  start?: number
  position?: number
  playing?: boolean
  value?: number
  on?: boolean
  mode?: 'off' | 'all' | 'one'
  source?: string
}

/** What a device sends about itself (the rest is filled in). */
export type RemoteState = Omit<RemoteDevice, 'id' | 'name' | 'kind' | 'at'>

/** Heard from in the last 75 s. */
export const deviceOnline = (d: RemoteDevice, now = Date.now()): boolean => now - d.at < 75_000

/** Where it is now (moving on from the last report while it plays). */
export function devicePosition(d: RemoteDevice, now = Date.now()): number {
  if (!d.playing) return d.position
  const p = d.position + Math.max(0, now - d.positionAt) / 1000
  return d.duration > 0 ? Math.min(p, d.duration) : p
}
