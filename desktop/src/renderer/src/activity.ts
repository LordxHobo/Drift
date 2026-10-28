// Tells the main process what's playing (for friends, Orbit, Discord and the tray): right after a
// song change, play/pause or a jump, and every 30 seconds while playing.
import { drift } from './state'
import { next, playerStore, positionStore, previous, toggle } from './player'

let timer: number | undefined
let last = ''
let lastPosition = 0
let lastAt = 0

function send(): void {
  const p = playerStore.get()
  lastPosition = positionStore.get()
  lastAt = Date.now()
  void drift
    .playerState({ track: p.current ?? null, playing: p.playing, position: positionStore.get(), duration: p.duration })
    .catch(() => undefined)
}

function soon(ms: number): void {
  clearTimeout(timer)
  timer = window.setTimeout(send, ms)
}

export function startActivity(): void {
  playerStore.subscribe(() => {
    const s = playerStore.get()
    const signature = `${s.current?.id ?? '-'}|${s.playing}|${Math.round(s.duration)}`
    if (signature === last) return
    last = signature
    // Friends get it a moment later (like the phone); a quick skip through songs sends only the last.
    soon(1500)
  })
  // A seek: the position jumps away from where it should be.
  positionStore.subscribe(() => {
    const s = playerStore.get()
    if (!s.current) return
    const expected = lastPosition + (s.playing ? (Date.now() - lastAt) / 1000 : 0)
    if (Math.abs(positionStore.get() - expected) > 3) soon(600)
  })
  window.setInterval(() => {
    if (playerStore.get().playing) send()
  }, 30_000)
  // Play/pause, next and previous from the tray.
  drift.on('media', (m: { action: 'toggle' | 'next' | 'previous' }) => {
    if (m.action === 'toggle') toggle()
    else if (m.action === 'next') next()
    else previous()
  })
}
