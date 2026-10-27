import { app, BrowserWindow, ipcMain, nativeTheme, protocol, shell } from 'electron'
import { join } from 'node:path'
import type { DriftApi } from '@shared/types'
import { apiMethods } from '@shared/types'
import * as store from './store'
import * as yt from './ytmusic'
import * as account from './account'
import { handleStream, prepare } from './stream'
import { lyrics } from './lyrics'
import { checkForUpdates, getUpdateState, installUpdate, startUpdates } from './updater'
import * as spotify from './spotify'
import * as downloads from './downloads'

protocol.registerSchemesAsPrivileged([
  { scheme: 'drift', privileges: { standard: true, secure: true, stream: true, supportFetchAPI: true, corsEnabled: true } }
])

// One Drift at a time: opening it again brings the first window forward.
if (!app.requestSingleInstanceLock()) app.quit()

let win: BrowserWindow | undefined

function createWindow(): void {
  const isMac = process.platform === 'darwin'
  const bar = titleBarColors()
  win = new BrowserWindow({
    width: 1280,
    height: 820,
    minWidth: 900,
    minHeight: 600,
    show: false,
    title: 'Drift',
    backgroundColor: bar.color,
    icon: join(__dirname, '../../build/icon.png'),
    titleBarStyle: 'hidden',
    ...(isMac
      ? { trafficLightPosition: { x: 14, y: 12 } }
      : { titleBarOverlay: { ...bar, height: 32 } }),
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
      autoplayPolicy: 'no-user-gesture-required'
    }
  })
  win.once('ready-to-show', () => win?.show())

  // Links open in the browser, never inside Drift.
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https:\/\//.test(url)) void shell.openExternal(url)
    return { action: 'deny' }
  })
  win.webContents.on('will-navigate', (e, url) => {
    if (!url.startsWith(process.env.ELECTRON_RENDERER_URL ?? 'file://')) e.preventDefault()
  })

  if (process.env.ELECTRON_RENDERER_URL) void win.loadURL(process.env.ELECTRON_RENDERER_URL)
  else void win.loadFile(join(__dirname, '../renderer/index.html'))
}

/** The strip behind the window buttons matches the top of the page in each look. */
function titleBarColors(): { color: string; symbolColor: string } {
  const s = store.getSettings()
  const dark = s.appearance === 'dark' || (s.appearance === 'device' && nativeTheme.shouldUseDarkColors)
  if (s.style === 'music') return dark ? { color: '#161618', symbolColor: '#8E8E93' } : { color: '#FAFAFA', symbolColor: '#3C3C43' }
  return dark ? { color: '#000000', symbolColor: '#A1A1AA' } : { color: '#F1F1F3', symbolColor: '#3F3F46' }
}

function updateTitleBar(): void {
  if (!win || process.platform === 'darwin') return
  const bar = titleBarColors()
  try {
    win.setTitleBarOverlay({ ...bar, height: 32 })
    win.setBackgroundColor(bar.color)
  } catch {
    // not supported on this system
  }
}

const api: DriftApi = {
  appInfo: async () => ({ version: app.getVersion(), platform: process.platform }),
  search: (q) => yt.searchAll(q),
  suggestions: (q) => yt.suggestions(q).catch(() => []),
  artist: (id, name) => yt.artistPage(id, name),
  findArtist: async (name) => yt.bestArtist(await yt.searchArtists(yt.mainArtist(name)), yt.mainArtist(name)),
  album: (id) => yt.albumPage(id),
  findAlbum: async (title, artist) => {
    const list = await yt.searchAlbums(`${title} ${yt.mainArtist(artist)}`)
    const want = yt.normalize(title)
    return list.find((a) => yt.normalize(a.title) === want) ?? null
  },
  discography: (ref) => yt.discography(ref),
  radio: (id) => yt.radio(id),
  prepare: (t) => prepare(t),
  lyrics: (t) => lyrics(t),

  library: async () => store.getLibrary(),
  setLiked: async (t, liked) => store.setLiked(t, liked),
  createPlaylist: async (name, tracks) => store.createPlaylist(name, tracks),
  addToPlaylist: async (id, tracks) => store.addToPlaylist(id, tracks),
  removeFromPlaylist: async (id, indexes) => store.removeFromPlaylist(id, indexes),
  movePlaylistTrack: async (id, from, to) => store.movePlaylistTrack(id, from, to),
  renamePlaylist: async (id, name) => store.renamePlaylist(id, name),
  deletePlaylist: async (id) => store.deletePlaylist(id),
  saveAlbum: async (page) => store.saveAlbum(page),
  follow: async (artist, page) => store.follow(artist, page),
  unfollow: async (id) => store.unfollow(id),
  played: async (t) => store.played(t),
  checkNewReleases: () => account.checkNewReleases(true),

  settings: async () => store.getSettings(),
  setSettings: async (change) => {
    const s = store.setSettings(change)
    updateTitleBar()
    return s
  },

  account: async () => account.getAccount(),
  syncNow: () => account.syncNow(),
  startPairing: async () => void account.startPairing(),
  cancelPairing: async () => account.cancelPairing(),
  pairing: async () => account.getPairing(),
  unlink: async () => account.unlink(),

  openExternal: async (url) => {
    if (/^https:\/\//.test(url)) await shell.openExternal(url)
  },

  startImport: async (link) => void spotify.startImport(link),
  importState: async () => spotify.getImportState(),
  retryMissing: async () => void spotify.retryMissing(),
  clearImport: async () => spotify.clearImport(),

  downloads: async () => downloads.getDownloads(),
  downloadedTracks: async () => downloads.downloadedTracks(),
  download: async (tracks) => downloads.download(tracks),
  removeDownloads: async (ids) => downloads.removeDownloads(ids),
  keepDownloaded: async (collection, keep) => downloads.keepDownloaded(collection, keep),
  removeAllDownloads: async () => downloads.removeAllDownloads(),
  openDownloadsFolder: async () => downloads.openFolder(),
  retryFailedDownloads: async () => downloads.retryFailed(),

  updateState: async () => getUpdateState(),
  checkForUpdates: () => checkForUpdates(),
  installUpdate: async () => installUpdate()
}

for (const name of apiMethods) {
  ipcMain.handle(`drift:${name}`, (_e, ...args: unknown[]) => (api[name] as (...a: unknown[]) => unknown)(...args))
}

app.on('second-instance', () => {
  if (!win) return
  if (win.isMinimized()) win.restore()
  win.focus()
})

app.whenReady().then(() => {
  protocol.handle('drift', (request) => {
    const host = new URL(request.url).host
    if (host === 'stream') return handleStream(request)
    return new Response('Not found', { status: 404 })
  })
  nativeTheme.on('updated', updateTitleBar)
  createWindow()
  account.start()
  startUpdates()
  downloads.startDownloads()
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('before-quit', () => {
  store.flush()
  downloads.flushDownloads()
})
app.on('window-all-closed', () => {
  store.flush()
  if (process.platform !== 'darwin') app.quit()
})
