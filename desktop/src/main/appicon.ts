// Drift's icon follows the style: green for Drift, pink or white (picked in Settings) for the
// Apple Music style. Changes the window, taskbar and tray icon (the Dock on a Mac) while Drift runs, and
// on Windows also Drift's shortcuts (desktop, Start menu, pinned to the taskbar), so it sticks.
import { app, BrowserWindow, nativeImage, shell } from 'electron'
import { existsSync } from 'node:fs'
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
  if (process.platform === 'win32') updateShortcuts(file.replace(/\.png$/, '.ico'))
}

/**
 * Points Drift's Windows shortcuts at the icon for the style. A pinned taskbar button shows its
 * shortcut's icon even while Drift runs, so the window's own icon alone isn't enough.
 */
function updateShortcuts(ico: string): void {
  if (!app.isPackaged) return
  const icon = join(process.resourcesPath, 'icons', ico)
  if (!existsSync(icon)) return
  const appData = process.env.APPDATA ?? ''
  const places = [
    join(app.getPath('desktop'), 'Drift.lnk'),
    join(appData, 'Microsoft', 'Windows', 'Start Menu', 'Programs', 'Drift.lnk'),
    join(appData, 'Microsoft', 'Internet Explorer', 'Quick Launch', 'User Pinned', 'TaskBar', 'Drift.lnk'),
    join(appData, 'Microsoft', 'Internet Explorer', 'Quick Launch', 'User Pinned', 'StartMenu', 'Drift.lnk')
  ]
  const exe = process.execPath.toLowerCase()
  for (const p of places) {
    try {
      if (!existsSync(p)) continue
      const link = shell.readShortcutLink(p)
      // Only Drift's own shortcuts (to this copy of Drift), and only when they need it.
      if (link.target.toLowerCase() !== exe || link.icon === icon) continue
      shell.writeShortcutLink(p, 'update', { ...link, icon, iconIndex: 0 })
    } catch {
      // can't read or change this one: leave it
    }
  }
}
