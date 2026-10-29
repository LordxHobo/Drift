// Drift's icon follows the style: green for Drift, pink or white (picked in Settings) for the
// Apple Music style. Changes the window, taskbar and tray icon (the Dock on a Mac) while Drift runs.
import { app, BrowserWindow, nativeImage } from 'electron'
import { join } from 'node:path'
import { getSettings } from './store'
import { setTrayIcon } from './tray'

let applied = ''

function iconFile(): string {
  const s = getSettings()
  if (s.style !== 'music') return 'icon.png'
  return s.musicIcon === 'white' ? 'icon-music-white.png' : 'icon-music.png'
}

/** The icon file for the current style. */
export function iconPath(): string {
  return join(app.getAppPath(), 'build', iconFile())
}

/** Shows the right icon everywhere (does nothing when it's already showing). */
export function applyIcon(): void {
  const file = iconFile()
  if (file === applied) return
  const img = nativeImage.createFromPath(iconPath())
  if (img.isEmpty()) return
  applied = file
  if (process.platform === 'darwin') {
    app.dock?.setIcon(img)
  } else {
    for (const w of BrowserWindow.getAllWindows()) if (!w.isDestroyed()) w.setIcon(img)
  }
  setTrayIcon(img)
}
