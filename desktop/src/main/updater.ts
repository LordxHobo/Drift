// Keeping Drift up to date: new versions come from the public drift-releases repository on GitHub.
import { app, net } from 'electron'
import { autoUpdater } from 'electron-updater'
import type { UpdateState } from '@shared/types'
import { emit } from './store'

export const releasesRepo = { owner: 'LordxHobo', repo: 'drift-releases' }
const releasesPage = `https://github.com/${releasesRepo.owner}/${releasesRepo.repo}/releases/latest`

let state: UpdateState = { phase: 'idle' }

function set(s: UpdateState): void {
  state = s
  emit('update', s)
}

export function getUpdateState(): UpdateState {
  return state
}

/** Macs only install signed updates, so there Drift just says a new version is out. */
const installsItself = (): boolean => process.platform === 'win32' || (process.platform === 'linux' && !!process.env.APPIMAGE)

function newer(a: string, b: string): boolean {
  const pa = a.replace(/^v/, '').split('.').map(Number)
  const pb = b.replace(/^v/, '').split('.').map(Number)
  for (let i = 0; i < 3; i++) {
    if ((pa[i] ?? 0) !== (pb[i] ?? 0)) return (pa[i] ?? 0) > (pb[i] ?? 0)
  }
  return false
}

let started = false

export function startUpdates(): void {
  if (started) return
  started = true
  if (!app.isPackaged) {
    set({ phase: 'dev', message: 'Updates are off while developing.' })
    return
  }
  if (installsItself()) {
    autoUpdater.autoDownload = true
    autoUpdater.autoInstallOnAppQuit = true
    autoUpdater.on('checking-for-update', () => {
      if (state.phase !== 'downloading' && state.phase !== 'ready') set({ phase: 'checking' })
    })
    autoUpdater.on('update-not-available', () => set({ phase: 'none' }))
    autoUpdater.on('update-available', (info) => set({ phase: 'downloading', version: info.version, percent: 0 }))
    autoUpdater.on('download-progress', (p) => set({ ...state, phase: 'downloading', percent: Math.round(p.percent) }))
    autoUpdater.on('update-downloaded', (info) => set({ phase: 'ready', version: info.version }))
    autoUpdater.on('error', (e) => {
      if (state.phase === 'ready') return
      const message = (e?.message ?? String(e)).split('\n')[0]
      // Nothing published yet counts as up to date.
      if (/404|latest\.yml|Unable to find latest version/i.test(message)) return set({ phase: 'none' })
      set({ phase: 'error', message })
    })
  }
  setTimeout(() => void checkForUpdates(), 10_000)
  setInterval(() => void checkForUpdates(), 4 * 3600_000)
}

export async function checkForUpdates(): Promise<void> {
  if (!app.isPackaged || state.phase === 'downloading' || state.phase === 'ready') return
  if (installsItself()) {
    await autoUpdater.checkForUpdates().catch(() => undefined)
    return
  }
  // Mac: look at the latest release and offer the download.
  set({ phase: 'checking' })
  try {
    const res = await net.fetch(`https://api.github.com/repos/${releasesRepo.owner}/${releasesRepo.repo}/releases/latest`, {
      headers: { Accept: 'application/vnd.github+json' }
    })
    if (res.status === 404) return set({ phase: 'none' }) // nothing published yet
    if (res.status !== 200) throw new Error(`GitHub answered ${res.status}`)
    const release = (await res.json()) as { tag_name?: string; html_url?: string }
    const latest = release.tag_name ?? ''
    if (latest && newer(latest, app.getVersion())) {
      set({ phase: 'available', version: latest.replace(/^v/, ''), url: release.html_url ?? releasesPage })
    } else {
      set({ phase: 'none' })
    }
  } catch (e) {
    set({ phase: 'error', message: e instanceof Error ? e.message : 'Couldn’t check for updates.' })
  }
}

export function installUpdate(): void {
  // Silent: no installer window; Drift opens again by itself when it's done.
  if (state.phase === 'ready') autoUpdater.quitAndInstall(true, true)
}
