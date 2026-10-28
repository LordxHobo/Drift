// Tells friends what you're listening to (a couple of seconds after each change, like the phone).
import { accountStore, drift } from './state'
import { playerStore } from './player'

let timer: number | undefined
let last = ''

export function startActivity(): void {
  playerStore.subscribe(() => {
    const s = playerStore.get()
    const signature = `${s.current?.id ?? '-'}|${s.playing}`
    if (signature === last) return
    last = signature
    clearTimeout(timer)
    timer = window.setTimeout(() => {
      if (!accountStore.get().linked) return
      const p = playerStore.get()
      void drift.publishActivity(p.current ?? null, p.playing).catch(() => undefined)
    }, 2000)
  })
}
