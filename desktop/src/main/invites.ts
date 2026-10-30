// Listen Together invites: sending them (from a song's menu) and noticing ones sent to you.
// Each invite is a small document at users/{them}/invites/{you}; the server only accepts it when you
// follow each other and they allow invites. Same documents as the phone's JamInvites.
import type { JamInvite, Track } from '@shared/types'
import { nameOf } from '@shared/types'
import { BrowserWindow, Notification } from 'electron'
import * as account from './account'
import { FV } from './firebase'
import { emit } from './store'
import { cachedMe, me } from './social'

/** Invites older than this are cleared without asking. */
const maxAge = 15 * 60_000

const asked = new Set<string>()
let timer: NodeJS.Timeout | undefined
let checking = false

const inviteKey = (i: JamInvite): string => `${i.from}|${i.code}|${i.at}`

/** Invites these friends (profile ids) to the session `code`. Returns the ones it couldn't invite. */
export async function sendInvites(friendIds: string[], code: string, track: Track): Promise<string[]> {
  const l = account.linked()
  if (!l) throw new Error('Link your phone first (Settings), so friends can find you.')
  const mine = cachedMe() ?? (await me())
  const failed: string[] = []
  for (const id of friendIds) {
    try {
      await l.db.patch(`users/${id}/invites/${l.uid}`, {
        from: FV.s(l.uid),
        fromName: FV.s(mine ? nameOf(mine) : 'A friend'),
        code: FV.s(code),
        title: FV.s(track.title),
        artist: FV.s(track.artist),
        at: FV.i(Date.now())
      })
    } catch {
      failed.push(id)
    }
  }
  return failed
}

async function check(): Promise<void> {
  const l = account.linked()
  if (checking || !l) return
  checking = true
  try {
    const mine = cachedMe() ?? (await me().catch(() => null))
    if (!mine || mine.allowInvites === false) return
    const docs = await l.db.list(`users/${l.uid}/invites`)
    for (const d of docs) {
      const f = d?.fields
      const from = FV.string(f, 'from')
      const code = FV.string(f, 'code')
      if (!from || !code) continue
      const invite: JamInvite = {
        from,
        fromName: FV.string(f, 'fromName') ?? 'A friend',
        code,
        title: FV.string(f, 'title') ?? '',
        artist: FV.string(f, 'artist') ?? '',
        at: FV.int(f, 'at') ?? 0
      }
      // Old or already asked about: cleared quietly.
      if (Date.now() - invite.at > maxAge || asked.has(inviteKey(invite))) {
        void l.db.delete(`users/${l.uid}/invites/${from}`).catch(() => undefined)
        continue
      }
      asked.add(inviteKey(invite))
      emit('jamInvite', invite)
      notify(invite)
    }
  } catch {
    // offline: try again next time
  } finally {
    checking = false
  }
}

/** The answer to an invite (the window joins the session itself when accepted). */
export async function answerInvite(invite: JamInvite): Promise<void> {
  const l = account.linked()
  if (l) await l.db.delete(`users/${l.uid}/invites/${invite.from}`).catch(() => undefined)
}

/** Drift isn't the window in front (minimised, behind others, or closed to the tray): a system notification. */
function notify(invite: JamInvite): void {
  const win = BrowserWindow.getAllWindows()[0]
  if ((win && win.isVisible() && win.isFocused()) || !Notification.isSupported()) return
  const n = new Notification({
    title: `${invite.fromName} invited you to listen together`,
    body: invite.title ? `“${invite.title}” by ${invite.artist}` : 'Open Drift to join.'
  })
  n.on('click', () => {
    const w = BrowserWindow.getAllWindows()[0]
    if (!w) return
    if (w.isMinimized()) w.restore()
    w.show()
    w.focus()
  })
  n.show()
}

/** Looks for invites every 10 s. */
export function startInvites(): void {
  if (timer) return
  timer = setInterval(() => void check(), 10_000)
  setTimeout(() => void check(), 5_000)
}
