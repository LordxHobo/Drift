// Installs a downloaded update by itself, but only while nothing is playing: once Drift has been
// quiet for a minute (and no Spotify import is running), it closes, updates silently and opens
// again on the same song, paused.
import { drift, importStore, updateStore } from './state'
import { playerStore } from './player'

const quietFor = 60_000
let timer: number | undefined

const busy = (): boolean => {
  const i = importStore.get().phase
  return playerStore.get().playing || i === 'reading' || i === 'matching' || !!importStore.get().retrying
}

function check(): void {
  if (updateStore.get().phase !== 'ready' || busy()) {
    clearTimeout(timer)
    timer = undefined
    return
  }
  timer ??= window.setTimeout(() => {
    timer = undefined
    if (updateStore.get().phase === 'ready' && !busy()) void drift.installUpdate()
  }, quietFor)
}

export function startAutoInstall(): void {
  updateStore.subscribe(check)
  playerStore.subscribe(check)
  importStore.subscribe(check)
  check()
}
