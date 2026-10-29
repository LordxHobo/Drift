import { app, BrowserWindow, ipcMain, nativeTheme, protocol, shell } from 'electron'
import { join } from 'node:path'
import type { DriftApi } from '@shared/types'
import { apiMethods } from '@shared/types'
import * as store from './store'
import * as yt from './ytmusic'
import * as account from './account'
import { handleStream, prefetch, prepare, videoQualities } from './stream'
import { lyrics } from './lyrics'
import { checkForUpdates, getUpdateState, installUpdate, startUpdates } from './updater'
import * as spotify from './spotify'
import * as downloads from './downloads'
import * as notices from './notifications'
import { applyIcon, iconPath } from './appicon'
import * as collab from './collab'
import * as jam from './jam'
import * as social from './social'
import * as podcasts from './podcasts'
import * as presence from './presence'
import { setToken, testOrbit } from './orbit'
import { createTray } from './tray'
import { chapters, searchPodcasts, searchYouTube, videoFromLink } from './youtube'

protocol.registerSchemesAsPrivileged([
  { scheme: 'drift', privileges: { standard: true, secure: true, stream: true, supportFetchAPI: true, corsEnabled: true } }
])

// One Drift at a time: opening it again brings the first window forward.
if (!app.requestSingleInstanceLock()) app.quit()
// Windows shows Drift's notifications only for the app ID it was installed with.
if (process.platform === 'win32') app.setAppUserModelId('com.lordxhobo.drift.desktop')

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
    icon: iconPath(),
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
  // Closing the window keeps Drift playing in the tray (Windows and Linux), unless turned off.
  win.on('close', (e) => {
    if (!quitting && process.platform !== 'darwin' && store.getSettings().closeToTray) {
      e.preventDefault()
      win?.hide()
    }
  })

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
  album: async (id, exact) => {
    const page = await yt.albumPage(id)
    // A clean album opens as its explicit edition (when that setting is on and there is one).
    if (!exact && store.getSettings().preferExplicit && !page.explicit) {
      const edition = await yt.explicitEdition(page).catch(() => undefined)
      if (edition) return { ...edition, cleanId: page.id }
    }
    return page
  },
  findAlbum: async (title, artist) => {
    const list = await yt.searchAlbums(`${title} ${yt.mainArtist(artist)}`)
    const want = yt.normalize(title)
    return list.find((a) => yt.normalize(a.title) === want) ?? null
  },
  discography: (ref) => yt.discography(ref),
  radio: (id) => yt.radio(id),
  prepare: (t) => prepare(t),
  prefetch: (list) => prefetch(list),
  jamStart: () => jam.startJam(),
  jamJoin: (code) => jam.joinJam(code),
  jamLeave: () => jam.leaveJam(),
  jamPublish: (change) => jam.publish(change),
  jamState: async () => jam.getJam(),
  collabShare: (id, people) => collab.share(id, people),
  collabLeave: (id) => collab.leave(id),
  collabStop: (id) => collab.stop(id),
  collabSync: () => collab.syncNow(),
  searchYouTube: (q, more) => searchYouTube(q, more),
  versions: (q) => yt.versions(q),
  replaceTrack: async (place, index, oldId, track) => {
    const wasDownloaded = downloads.getDownloads().done.includes(oldId)
    if (store.replaceTrack(place, index, oldId, track) && wasDownloaded) downloads.download([track])
  },
  lyrics: (t) => lyrics(t),
  chapters: (id) => chapters(id),
  videoQualities: (id) => videoQualities(id),

  library: async () => store.getLibrary(),
  setLiked: async (t, liked) => store.setLiked(t, liked),
  createPlaylist: async (name, tracks) => store.createPlaylist(name, tracks),
  addToPlaylist: async (id, tracks) => store.addToPlaylist(id, tracks),
  removeFromPlaylist: async (id, indexes) => store.removeFromPlaylist(id, indexes),
  movePlaylistTrack: async (id, from, to) => store.movePlaylistTrack(id, from, to),
  renamePlaylist: async (id, name) => store.renamePlaylist(id, name),
  updatePlaylist: async (id, change) => store.updatePlaylist(id, change),
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
    if ('style' in change || 'musicIcon' in change) applyIcon()
    if (Object.keys(change).some((k) => k.startsWith('orbit') || k.startsWith('discord'))) presence.settingsChanged()
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
  notifications: async () => notices.getNotifications(),
  markNotificationsRead: async () => notices.markAllRead(),
  removeNotification: async (id) => notices.remove(id),
  retryReport: (id) => spotify.retryReport(id),
  clearImport: async () => spotify.clearImport(),

  downloads: async () => downloads.getDownloads(),
  downloadedTracks: async () => downloads.downloadedTracks(),
  download: async (tracks) => downloads.download(tracks),
  removeDownloads: async (ids) => downloads.removeDownloads(ids),
  keepDownloaded: async (collection, keep) => downloads.keepDownloaded(collection, keep),
  removeAllDownloads: async () => downloads.removeAllDownloads(),
  openDownloadsFolder: async () => downloads.openFolder(),
  retryFailedDownloads: async () => downloads.retryFailed(),

  me: () => social.me(),
  friends: () => social.friends(),
  followers: (id) => social.followers(id),
  user: (id) => social.user(id),
  searchUsers: (text) => social.searchUsers(text),
  followUser: (id, follow) => social.followUser(id, follow),
  sharedPlaylists: (u) => social.sharedPlaylists(u),
  sharedPlaylistTracks: (owner, id) => social.sharedPlaylistTracks(owner, id),
  setShareActivity: (on) => social.setShareActivity(on),
  usernameAvailable: (name) => social.usernameAvailable(name),
  updateProfile: (change) => social.updateProfile(change),
  setPrivateSession: async (on) => presence.setPrivateSession(on),
  playerState: async (p) => presence.playerState(p),
  connections: async () => presence.connections(),
  setOrbitToken: async (t) => {
    setToken(t)
    presence.settingsChanged()
  },
  testOrbit: () => testOrbit(),

  podcasts: async () => podcasts.getPodcasts(),
  searchPodcasts: (q) => searchPodcasts(q),
  channelEpisodes: (c) => podcasts.episodes(c),
  followChannel: async (c, follow) => podcasts.followChannel(c, follow),
  refreshPodcasts: (force) => podcasts.refresh(force),
  episodeProgress: async (t, position, duration) => podcasts.updateProgress(t, position, duration),
  markPlayed: async (t, played) => podcasts.markPlayed(t, played),
  videoFromLink: (link) => videoFromLink(link),
  skipSegments: (id, podcast) => podcasts.skipSegments(id, podcast),

  updateState: async () => getUpdateState(),
  checkForUpdates: () => checkForUpdates(),
  installUpdate: async () => installUpdate()
}

for (const name of apiMethods) {
  ipcMain.handle(`drift:${name}`, (_e, ...args: unknown[]) => (api[name] as (...a: unknown[]) => unknown)(...args))
}

function showWindow(): void {
  if (!win || win.isDestroyed()) return createWindow()
  if (win.isMinimized()) win.restore()
  win.show()
  win.focus()
}

app.on('second-instance', showWindow)
notices.setShowWindow(showWindow)

app.whenReady().then(() => {
  protocol.handle('drift', (request) => {
    const host = new URL(request.url).host
    if (host === 'stream') return handleStream(request)
    return new Response('Not found', { status: 404 })
  })
  nativeTheme.on('updated', updateTitleBar)
  createWindow()
  createTray(showWindow)
  applyIcon()
  account.start()
  collab.startCollab()
  startUpdates()
  downloads.startDownloads()
  podcasts.startPodcasts()
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

let quitting = false
app.on('before-quit', () => {
  void jam.leaveJam()
  quitting = true
  void presence.stopPresence()
  store.flush()
  downloads.flushDownloads()
  podcasts.flushPodcasts()
})
app.on('window-all-closed', () => {
  store.flush()
  if (process.platform !== 'darwin') app.quit()
})
