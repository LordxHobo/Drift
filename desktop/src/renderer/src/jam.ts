// Listen Together, in the window: keeps this player and the session in step.
// What someone here does (pick a song, play/pause, skip, jump, change what's next) is sent to the
// session; what someone else does is played here. When a song ends by itself, only the host says
// what's next (everyone's player already goes on to the same song), so nobody talks over each other.
import type { JamState, Track } from '@shared/types'
import { drift, Store, toast } from './state'
import { currentTime, jamHooks, jamPlay, playerStore } from './player'

/** The session you're in (null when none). */
export const jamStore = new Store<JamState | null>(null)

/** What was last sent or played here: song | playing | what's next. */
let lastSignature = ''
/** The last session change seen (its server time), and when this computer last sent one. */
let lastSeenAt = 0
let lastPublishLocal = 0
let lastSeeks = 0
let applyingUntil = 0
let lastCorrection = 0
let wasLoading = false
let loadedSettleUntil = 0

function signature(track: Track | null | undefined, playing: boolean, queue: Track[]): string {
  return `${track?.id ?? ''}|${playing}|${queue.slice(0, 30).map((t) => t.id).join(',')}`
}

function localNow(): { track: Track | null; queue: Track[]; playing: boolean } {
  const p = playerStore.get()
  return { track: p.current ?? null, queue: p.queue.slice(p.index + 1, p.index + 31), playing: p.playing }
}

/** Where the session is now (seconds), from when its position was last set. */
function expected(s: JamState): number {
  if (!s.playing) return s.position
  const serverNow = Date.now() - s.offset
  return s.position + Math.max(0, serverNow - s.at) / 1000
}

function apply(s: JamState): void {
  lastSeenAt = s.at
  if (!s.track) return
  // A moment for the player to settle (its pause/play events), so it isn't mistaken for a change here.
  applyingUntil = Date.now() + 700
  jamPlay(s.track, s.queue, expected(s), s.playing)
  lastSignature = signature(s.track, s.playing, s.queue)
  lastSeeks = jamHooks.seeks
}

function publish(): void {
  const s = jamStore.get()
  if (!s) return
  const now = localNow()
  lastSignature = signature(now.track, now.playing, now.queue)
  lastSeeks = jamHooks.seeks
  lastPublishLocal = Date.now()
  void drift.jamPublish({ ...now, position: currentTime() })
}

/** Runs twice a second while in a session. */
function tick(): void {
  const s = jamStore.get()
  if (!s || Date.now() < applyingUntil) return
  // Still loading the song: nothing to tell the others yet (it looks paused at 0:00 meanwhile, which
  // would pull everyone back to the start).
  if (playerStore.get().loading) {
    wasLoading = true
    return
  }
  // …and a moment after, while it settles into playing.
  if (wasLoading) {
    wasLoading = false
    loadedSettleUntil = Date.now() + 800
  }
  if (Date.now() < loadedSettleUntil) return
  const now = localNow()
  const sig = signature(now.track, now.playing, now.queue)
  if (sig !== lastSignature) {
    // A song ended by itself and the next one started: the host announces it, everyone else waits.
    const natural = Date.now() - jamHooks.naturalEndAt < 4000
    if (natural && s.host !== s.me) {
      lastSignature = sig
      return
    }
    publish()
    return
  }
  if (jamHooks.seeks !== lastSeeks) {
    // Jumped in the song here.
    publish()
    return
  }
  // Drifted apart (a slow connection, a pause to load): catch up quietly, at most every 5 s.
  if (s.playing && now.playing && s.track?.id === now.track?.id && Date.now() - lastCorrection > 5000) {
    const gap = currentTime() - expected(s)
    if (Math.abs(gap) > 1.2) {
      lastCorrection = Date.now()
      apply(s)
    }
  }
}

let started = false

export function startJam(): void {
  if (started) return
  started = true
  drift.on('jam', (s) => {
    const was = jamStore.get()
    jamStore.set(s)
    if (!was) {
      // Just joined: play what the session plays (or, as host with nothing yet, share what's on here).
      if (s.track) apply(s)
      else if (s.host === s.me && playerStore.get().current) publish()
      return
    }
    if (s.at === lastSeenAt) return
    // Someone else's change, made after this computer's last one (older answers are ignored).
    if (s.updatedBy !== s.me && s.at + s.offset > lastPublishLocal - 300) apply(s)
    else lastSeenAt = s.at
  })
  drift.on('jamEnded', () => {
    if (jamStore.get()) toast('Listen Together ended')
    jamStore.set(null)
  })
  void drift.jamState().then((s) => s && jamStore.set(s))
  window.setInterval(tick, 500)
}

export async function startSession(): Promise<void> {
  const s = await drift.jamStart()
  jamStore.set(s)
  lastSeenAt = s.at
  if (playerStore.get().current) publish()
}

export async function joinSession(code: string): Promise<void> {
  const s = await drift.jamJoin(code)
  jamStore.set(s)
  if (s.track) apply(s)
}

export async function leaveSession(): Promise<void> {
  await drift.jamLeave()
  jamStore.set(null)
}
