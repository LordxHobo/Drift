// Control other device, in the window: play on your phone from here (and let it play here), like Spotify
// Connect. The main process does the syncing (main/remote.ts); this tells it what plays here, runs the
// commands that arrive, and sends what you do to the device you control.
import type { RemoteCommand, RemoteDevice, RemoteState } from '@shared/remote'
import { devicePosition } from '@shared/remote'
import { accountStore, drift, Store, toast } from './state'
import {
  addToQueue, audioElement, currentTime, next, pauseHere, playerStore, playList, playNext, positionStore, previous, remoteHook,
  resumeHere, seek, setRepeat, setShuffle, setVolume, toggle, transferIn
} from './player'

export interface RemoteView {
  /** The device controlled from here, or null (playing here). */
  target: string | null
  devices: RemoteDevice[]
  /** The device menu is open (devices are refreshed more often). */
  picking: boolean
  error?: string
}

export const remoteStore = new Store<RemoteView>({ target: null, devices: [], picking: false })

export const targetDevice = (v = remoteStore.get()): RemoteDevice | undefined => v.devices.find((d) => d.id === v.target)

let refreshing = false

export async function refreshDevices(): Promise<void> {
  if (refreshing || !accountStore.get().linked) return
  refreshing = true
  try {
    const devices = await drift.remoteDevices()
    remoteStore.update((v) => ({ ...v, devices, error: undefined }))
  } catch {
    remoteStore.update((v) => ({ ...v, error: 'Couldn’t reach Drift’s server. Check your connection.' }))
  } finally {
    refreshing = false
  }
}

/** Sends a command to the device being controlled (or `to`). Shows the change right away. */
export function send(c: Omit<RemoteCommand, 'id' | 'from'>, to?: string): boolean {
  const id = to ?? remoteStore.get().target
  if (!id) return false
  drift.remoteSend(id, c).then(
    () => setTimeout(() => void refreshDevices(), 700),
    () => remoteStore.update((v) => ({ ...v, error: 'Couldn’t reach your other device. Check your connection.' }))
  )
  remoteStore.update((v) => ({ ...v, devices: v.devices.map((d) => (d.id === id ? optimistic(d, c) : d)) }))
  return true
}

function optimistic(d: RemoteDevice, c: Omit<RemoteCommand, 'id' | 'from'>): RemoteDevice {
  const now = Date.now()
  switch (c.type) {
    case 'toggle':
    case 'resume':
    case 'pause':
      return { ...d, position: devicePosition(d, now), positionAt: now, playing: c.type === 'toggle' ? !d.playing : c.type === 'resume' }
    case 'seek':
      return { ...d, position: c.position ?? d.position, positionAt: now }
    case 'volume':
      return { ...d, volume: c.value ?? d.volume }
    case 'shuffle':
      return { ...d, shuffle: c.on ?? d.shuffle }
    case 'repeat':
      return { ...d, repeat: c.mode ?? d.repeat }
    default:
      return d
  }
}

/** Plays on another device: what plays here moves there (and stops here). */
export function connect(id: string): void {
  const v = remoteStore.get()
  if (v.target === id) return
  stopControlling()
  const s = playerStore.get()
  if (s.current) {
    send({
      type: 'transfer',
      track: s.current,
      queue: s.queue.slice(s.index + 1, s.index + 51),
      position: currentTime(),
      playing: !audioElement.paused,
      source: s.context?.name
    }, id)
    pauseHere()
  }
  remoteStore.update((x) => ({ ...x, target: id }))
  remoteHook.send = (c) => send(c)
  void drift.remoteTarget(id)
  void refreshDevices()
  const d = remoteStore.get().devices.find((x) => x.id === id)
  toast(`Playing on ${d?.name ?? 'your other device'}`)
}

/** Back to playing on this computer: picks up where the other device is, and pauses it. */
export function playHere(): void {
  const d = targetDevice()
  if (d?.playing) send({ type: 'pause' })
  stopControlling()
  if (d?.track) transferIn(d.track, d.queue ?? [], devicePosition(d), d.playing, d.source ?? '')
}

/** Stops controlling the other device (it keeps playing). */
export function stopControlling(): void {
  remoteHook.send = undefined
  if (remoteStore.get().target) {
    remoteStore.update((v) => ({ ...v, target: null }))
    void drift.remoteTarget(null)
  }
}

export function setPicking(on: boolean): void {
  remoteStore.update((v) => ({ ...v, picking: on }))
  if (on) void refreshDevices()
}

/** Does what another device asked. */
function run(c: RemoteCommand): void {
  if (c.type === 'transfer' || c.type === 'play') stopControlling()
  const saved = remoteHook.send
  remoteHook.send = undefined
  try {
    switch (c.type) {
      case 'transfer':
        if (c.track) transferIn(c.track, c.queue ?? [], c.position ?? 0, c.playing ?? true, c.source ?? '')
        break
      case 'play':
        if (c.tracks?.length) playList(c.tracks, c.start ?? 0, { kind: 'queue', name: c.source || 'Another device' }, { shuffle: false })
        break
      case 'toggle':
        toggle()
        break
      case 'resume':
        resumeHere()
        break
      case 'pause':
        pauseHere()
        break
      case 'next':
        next()
        break
      case 'previous':
        previous()
        break
      case 'seek':
        if (typeof c.position === 'number') seek(c.position)
        break
      case 'volume':
        if (typeof c.value === 'number') setVolume(Math.sqrt(Math.max(0, Math.min(1, c.value))))
        break
      case 'shuffle':
        if (typeof c.on === 'boolean') setShuffle(c.on)
        break
      case 'repeat':
        if (c.mode) setRepeat(c.mode)
        break
      case 'playNext':
        if (c.track) playNext([c.track])
        break
      case 'addToQueue':
        if (c.track) addToQueue([c.track])
        break
    }
  } finally {
    remoteHook.send = saved
  }
}

/** What plays here, for your other devices. The volume is the sound's real level (0–1), like the phone's. */
function localState(): RemoteState {
  const s = playerStore.get()
  return {
    track: s.current ?? null,
    queue: s.current ? s.queue.slice(s.index + 1, s.index + 31) : [],
    playing: !!s.current && !audioElement.paused,
    position: currentTime(),
    positionAt: Date.now(),
    duration: s.duration || 0,
    volume: s.muted ? 0 : s.volume * s.volume,
    shuffle: s.shuffle,
    repeat: s.repeat,
    source: s.context?.name
  }
}

let lastSig = ''
let lastPos = 0
let lastPosAt = 0

/** Tells the main process when what plays here changes (song, play/pause, a jump, queue, volume…). */
function watch(): void {
  const s = localState()
  const sig = [s.track?.id, s.playing, s.shuffle, s.repeat, s.volume.toFixed(2), s.queue.map((t) => t.id).join(',')].join('|')
  // A jump: the position isn't where it would be by now.
  const expected = lastPos + (s.playing ? (Date.now() - lastPosAt) / 1000 : 0)
  const jumped = Math.abs(s.position - expected) > 2
  lastPos = s.position
  lastPosAt = Date.now()
  if (sig === lastSig && !jumped) return
  lastSig = sig
  void drift.remoteState(s)
}

export function startRemote(): void {
  drift.on('remoteCommand', (c) => run(c as RemoteCommand))
  playerStore.subscribe(watch)
  positionStore.subscribe(watch)
  watch()
  // Controlling (or choosing) a device: its state every 1.5 s.
  window.setInterval(() => {
    const v = remoteStore.get()
    if (v.target || v.picking) void refreshDevices()
  }, 1500)
}
