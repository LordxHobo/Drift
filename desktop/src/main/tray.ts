// The tray icon (Windows and Linux): what's playing, play/pause, next, previous, show and quit.
import { app, Menu, nativeImage, Tray } from 'electron'
import { join } from 'node:path'
import type { PlayerPresence } from '@shared/types'
import { emit } from './store'

let tray: Tray | undefined
let show: () => void = () => {}
let last: PlayerPresence | undefined

const traySize = (): number => (process.platform === 'win32' ? 16 : 22)

function icon(): Electron.NativeImage {
  const img = nativeImage.createFromPath(join(app.getAppPath(), 'build/icon.png'))
  return img.isEmpty() ? img : img.resize({ width: traySize() })
}

/** The tray shows the same icon as the window (it follows the style). */
export function setTrayIcon(img: Electron.NativeImage): void {
  if (tray && !img.isEmpty()) tray.setImage(img.resize({ width: traySize() }))
}

function media(action: 'toggle' | 'next' | 'previous'): void {
  emit('media', { action })
}

function rebuild(): void {
  if (!tray) return
  const t = last?.track
  const playing = !!last?.playing
  tray.setToolTip(t ? `${t.title} · ${t.artist}`.slice(0, 120) : 'Drift')
  tray.setContextMenu(
    Menu.buildFromTemplate([
      ...(t ? [{ label: `${t.title} · ${t.artist}`.slice(0, 60), enabled: false }, { type: 'separator' as const }] : []),
      { label: playing ? 'Pause' : 'Play', enabled: !!t, click: () => media('toggle') },
      { label: 'Next', enabled: !!t, click: () => media('next') },
      { label: 'Previous', enabled: !!t, click: () => media('previous') },
      { type: 'separator' },
      { label: 'Show Drift', click: show },
      { label: 'Quit Drift', click: () => app.quit() }
    ])
  )
}

export function createTray(onShow: () => void): void {
  if (tray || process.platform === 'darwin') return
  show = onShow
  tray = new Tray(icon())
  tray.on('click', onShow)
  rebuild()
}

export function updateTray(p: PlayerPresence): void {
  const changed = p.track?.id !== last?.track?.id || p.playing !== last?.playing
  last = p
  if (changed) rebuild()
}
