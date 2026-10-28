// Importing a public Spotify playlist or album (the same approach as the phone's importer).
import { app, BrowserWindow, net, session } from 'electron'
import { writeFileSync } from 'node:fs'
import { join } from 'node:path'
import type { ImportState, MissingSong, Track } from '@shared/types'
import { appleEpoch } from '@shared/types'
import * as store from './store'
import * as notices from './notifications'
import { mainArtist, normalize, searchSongs } from './ytmusic'
import { searchVideos } from './youtube'

interface SpotifyTrack {
  title: string
  artist: string
  duration?: number
  /** When it was added on Spotify (seconds since 2001, like the phone). */
  added?: number
}

interface SpotifyList {
  name: string
  tracks: SpotifyTrack[]
}

const chromeUA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'

/** Spotify's embed page lists only the first 100 songs. */
const embedLimit = 100

class ImportError extends Error {}

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms))

// MARK: Reading the list

async function read(link: string): Promise<SpotifyList & { total?: number; limited?: boolean }> {
  let text = link.trim()
  // Share menus sometimes add text around the link.
  const url = /https?:\/\/\S+/.exec(text)
  if (url) text = url[0]

  // Short links (spotify.link / spoti.fi) redirect to open.spotify.com.
  if (/spotify\.link|spoti\.fi/.test(text)) {
    const res = await net.fetch(text, { headers: { 'User-Agent': chromeUA } }).catch(() => undefined)
    if (res?.url) text = res.url
  }

  const m = /(playlist|album)[/:]([A-Za-z0-9]{10,})/.exec(text)
  if (!m) throw new ImportError('That doesn’t look like a Spotify playlist or album link.')
  const [, kind, id] = m

  // Playlists: read the whole thing through Spotify's own page; the embed below stops at 100.
  if (kind === 'playlist') {
    const full = await readFullPlaylist(id).catch(() => undefined)
    if (full?.tracks.length) return full
  }
  const embed = await readEmbed(kind, id)
  return { ...embed, limited: embed.tracks.length >= embedLimit - 5 }
}

/** Public playlists and albums from Spotify's embed page (no account needed). */
async function readEmbed(kind: string, id: string): Promise<SpotifyList> {
  const res = await net.fetch(`https://open.spotify.com/embed/${kind}/${id}`, {
    headers: { 'User-Agent': chromeUA, 'Accept-Language': 'en' }
  })
  if (res.status !== 200) throw new ImportError('Couldn’t open that playlist. Make sure it’s public, then try again.')
  const entity = findEntity(await res.text())
  if (!entity) throw new ImportError('Spotify’s page couldn’t be read. Try again in a moment.')
  const name = entity.name ?? entity.title ?? 'Spotify import'
  const tracks: SpotifyTrack[] = []
  for (const t of entity.trackList ?? []) {
    if (!t?.title) continue
    let artist: string = t.subtitle ?? ''
    if (!artist && Array.isArray(t.artists)) artist = t.artists.map((a: any) => a?.name).filter(Boolean).join(', ')
    tracks.push({ title: t.title, artist: artist.replace(/ /g, ' '), duration: typeof t.duration === 'number' ? t.duration / 1000 : undefined })
  }
  if (!tracks.length) throw new ImportError('Couldn’t open that playlist. Make sure it’s public, then try again.')
  return { name, tracks }
}

/** The page keeps its data as JSON in a <script>; Spotify has used three formats for it. */
function findEntity(html: string): any {
  const re = /<script([^>]*)>([\s\S]*?)<\/script>/g
  let m: RegExpExecArray | null
  const json = (s: string): any => {
    try {
      return JSON.parse(s)
    } catch {
      return undefined
    }
  }
  const b64 = (s: string): any => json(Buffer.from(s, 'base64').toString('utf8'))
  while ((m = re.exec(html))) {
    const attrs = m[1]
    const body = m[2].trim()
    if (attrs.includes('__NEXT_DATA__')) {
      const e = json(body)?.props?.pageProps?.state?.data?.entity
      if (e) return e
    } else if (attrs.includes('initial-state')) {
      const e = b64(body)?.data?.entity
      if (e) return e
    } else if (attrs.includes('"resource"') || attrs.includes('id=resource')) {
      const e = b64(body)
      if (e) return e
    }
  }
  return undefined
}

/** What Spotify's page answers for a playlist (any of its playlist requests). */
interface Page {
  name?: string
  total?: number
  /** Songs from `offset` on; null for things that aren't songs (episodes, local files). */
  items: (SpotifyTrack | null)[]
}

function parsePage(json: any): Page | undefined {
  const pl = json?.data?.playlistV2 ?? json?.data?.playlist
  if (!pl?.content || !Array.isArray(pl.content.items)) return undefined
  const items = pl.content.items.map((it: any): SpotifyTrack | null => {
    const d = it?.itemV2?.data ?? it?.item?.data
    if (!d?.name || (d.__typename && d.__typename !== 'Track')) return null
    const artists = (d.artists?.items ?? []).map((a: any) => a?.profile?.name).filter(Boolean)
    const ms = d.trackDuration?.totalMilliseconds ?? d.duration?.totalMilliseconds ?? 0
    const when = Date.parse(it?.addedAt?.isoString ?? '')
    return { title: d.name, artist: artists[0] ?? '', duration: ms > 0 ? ms / 1000 : undefined, added: Number.isFinite(when) ? when / 1000 - appleEpoch : undefined }
  })
  return { name: pl.name ?? undefined, total: typeof pl.content.totalCount === 'number' ? pl.content.totalCount : undefined, items }
}

interface SpotifyRequest {
  url: string
  body?: string
  headers: Record<string, string>
  op: string
}

function operation(url: string, body?: string): string {
  try {
    if (body) return String(JSON.parse(body).operationName ?? '')
  } catch {
    // not JSON
  }
  try {
    return new URL(url).searchParams.get('operationName') ?? ''
  } catch {
    return ''
  }
}

function offsetOf(r: { url: string; body?: string }): number {
  try {
    const v = r.body ? JSON.parse(r.body).variables : JSON.parse(new URL(r.url).searchParams.get('variables') ?? '{}')
    return Number(v?.offset) || 0
  } catch {
    return 0
  }
}

/** A short record of the last import's reading, for finding out what went wrong. */
const log: string[] = []
const note = (line: string): void => {
  log.push(`${new Date().toISOString().slice(11, 19)} ${line}`)
}
function saveLog(): void {
  try {
    writeFileSync(join(app.getPath('userData'), 'spotify-import.log'), log.join('\n') + '\n')
  } catch {
    // not important
  }
}

/**
 * A whole playlist of any length. Spotify's page is opened in a hidden window and everything it
 * loads about the playlist is read. Missing songs are then asked for with the page's own request
 * (page by page), and if that still leaves gaps, the page is scrolled so it loads the rest itself.
 * No account or developer keys needed.
 */
export async function readFullPlaylist(id: string): Promise<SpotifyList & { total?: number }> {
  const partition = `spotify-import-${Date.now()}` // in memory only, gone afterwards
  const ses = session.fromPartition(partition)
  ses.setUserAgent(chromeUA)
  const win = new BrowserWindow({
    show: false,
    width: 1280,
    height: 900,
    webPreferences: { partition, sandbox: true, contextIsolation: true, backgroundThrottling: false }
  })
  win.webContents.setAudioMuted(true)
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))

  let name: string | undefined
  let total: number | undefined
  const songs = new Map<number, SpotifyTrack | null>()
  const requests: SpotifyRequest[] = []
  const watched = new Map<string, SpotifyRequest>()
  let changed = 0
  let firstPage: () => void = () => {}
  const gotFirst = new Promise<void>((r) => (firstPage = r))

  const add = (page: Page, offset: number, from: string): number => {
    name ??= page.name
    if (page.total != null) total = page.total
    let fresh = 0
    page.items.forEach((t, i) => {
      if (!songs.has(offset + i)) fresh++
      songs.set(offset + i, t)
    })
    if (fresh) changed = Date.now()
    note(`${from}: offset ${offset}, ${page.items.length} items (${fresh} new), total ${page.total ?? '?'}`)
    return fresh
  }
  const missingFrom = (): number => {
    for (let i = 0; i < (total ?? 0); i++) if (!songs.has(i)) return i
    return -1
  }

  // Watch the page's own requests and answers (Chrome's developer tools protocol, inside Drift).
  const dbg = win.webContents.debugger
  log.length = 0
  try {
    // The window needs a page before the tools answer (asking earlier never returns).
    await win.loadURL('about:blank')
    dbg.attach('1.3')
    await Promise.race([
      dbg.sendCommand('Network.enable', { maxPostDataSize: 65536 }),
      sleep(5000).then(() => {
        throw new Error('no answer')
      })
    ])
  } catch (e) {
    note(`debugger unavailable: ${e instanceof Error ? e.message : e}`)
  }
  dbg.on('message', (_e, method, params: any) => {
    if (method === 'Network.requestWillBeSent') {
      const r = params.request
      if (!String(r?.url ?? '').includes('pathfinder')) return
      const body: string | undefined = r.postData ?? (Array.isArray(r.postDataEntries) ? r.postDataEntries.map((e: any) => (e.bytes ? Buffer.from(e.bytes, 'base64').toString('utf8') : '')).join('') : undefined)
      const op = operation(r.url, body)
      if (!/playlist/i.test(op)) return
      const req = { url: r.url, body, headers: r.headers ?? {}, op }
      watched.set(params.requestId, req)
      requests.push(req)
      note(`page asked: ${op}`)
    } else if (method === 'Network.loadingFinished') {
      const req = watched.get(params.requestId)
      if (!req) return
      watched.delete(params.requestId)
      dbg
        .sendCommand('Network.getResponseBody', { requestId: params.requestId })
        .then((res: any) => {
          const text = res.base64Encoded ? Buffer.from(res.body, 'base64').toString('utf8') : res.body
          const page = parsePage(JSON.parse(text))
          if (page) {
            add(page, offsetOf(req), `page got ${req.op}`)
            firstPage()
          } else {
            note(`page got ${req.op}: no song list`)
          }
        })
        .catch((e: unknown) => note(`couldn't read answer to ${req.op}: ${e instanceof Error ? e.message : e}`))
    }
  })

  try {
    void win.loadURL(`https://open.spotify.com/playlist/${id}`)
    await Promise.race([gotFirst, new Promise((_, reject) => setTimeout(() => reject(new Error('Spotify’s page didn’t load the playlist')), 25_000))])
    await sleep(1500) // let the page finish its first few requests

    // 1. Ask for the missing parts with the page's own request (the one that returned songs).
    const usable = requests.filter((r) => !/metadata/i.test(r.op))
    const best = usable.find((r) => /contents/i.test(r.op)) ?? usable.find((r) => r.op === 'fetchPlaylist') ?? usable[0]
    if (best) {
      let failures = 0
      const sizes = [100, 50, 25]
      let size = 0
      while (total != null && failures < 6) {
        const at = missingFrom()
        if (at < 0) break
        const limit = sizes[Math.min(size, sizes.length - 1)]
        const answer = await win.webContents.executeJavaScript(pageScript(best, at, limit), true).catch((e: unknown) => ({ error: String(e) }))
        const page = answer?.json ? parsePage(answer.json) : undefined
        if (page && page.items.length) {
          add(page, at, `asked ${best.op} (limit ${limit})`)
          failures = 0
        } else {
          note(`asked ${best.op} at ${at} (limit ${limit}): ${answer?.status ?? ''} ${answer?.error ?? JSON.stringify(answer?.json)?.slice(0, 300) ?? 'no songs'}`)
          failures++
          size++ // try smaller pages
          await sleep(800)
        }
      }
    } else {
      note('no usable request seen')
    }

    // 2. Still gaps: scroll the page so it loads the rest on its own.
    if (total != null && missingFrom() >= 0) {
      note(`scrolling for the rest (${songs.size} of ${total})`)
      const until = Date.now() + 60_000
      changed = Date.now()
      while (missingFrom() >= 0 && Date.now() < until && Date.now() - changed < 8000) {
        await win.webContents.executeJavaScript(scrollScript, true).catch(() => undefined)
        await sleep(700)
      }
    }

    const tracks = [...songs.entries()].sort((a, b) => a[0] - b[0]).map(([, t]) => t).filter((t): t is SpotifyTrack => !!t)
    note(`done: ${songs.size} of ${total ?? '?'} places, ${tracks.length} songs`)
    return { name: name ?? 'Spotify import', tracks, total: total == null ? undefined : songs.size < total ? total : undefined }
  } catch (e) {
    note(`failed: ${e instanceof Error ? e.message : e}`)
    throw e
  } finally {
    saveLog()
    try {
      dbg.detach()
    } catch {
      // already gone
    }
    win.destroy()
    void ses.clearStorageData().catch(() => undefined)
  }
}

/** One page of the playlist with the page's own request (runs inside Spotify's page). */
function pageScript(req: SpotifyRequest, offset: number, limit: number): string {
  // Headers the page isn't allowed to set itself are left out (the browser adds them).
  const headers: Record<string, string> = {}
  for (const [k, v] of Object.entries(req.headers)) {
    if (!/^(host|origin|referer|cookie|connection|content-length|accept-encoding|user-agent|sec-|proxy-|:)/i.test(k)) headers[k] = v
  }
  const r = { url: req.url, body: req.body ?? null, headers }
  return `(async () => {
    const r = ${JSON.stringify(r)};
    let url = r.url, init;
    if (r.body) {
      const b = JSON.parse(r.body);
      b.variables = Object.assign({}, b.variables, { offset: ${offset}, limit: ${limit} });
      init = { method: 'POST', headers: r.headers, body: JSON.stringify(b) };
    } else {
      const u = new URL(r.url);
      const v = JSON.parse(u.searchParams.get('variables') || '{}');
      v.offset = ${offset}; v.limit = ${limit};
      u.searchParams.set('variables', JSON.stringify(v));
      url = u.toString();
      init = { method: 'GET', headers: r.headers };
    }
    try {
      const res = await fetch(url, init);
      const text = await res.text();
      let json = null;
      try { json = JSON.parse(text); } catch (e) {}
      return { status: res.status, json, error: json ? undefined : text.slice(0, 200) };
    } catch (e) {
      return { error: String(e) };
    }
  })()`
}

/** Scrolls whatever scrolls on Spotify's page to the bottom (it loads more songs as you go). */
const scrollScript = `(() => {
  const all = [document.scrollingElement, ...document.querySelectorAll('*')];
  for (const el of all) {
    if (el && el.scrollHeight > el.clientHeight + 200 && el.clientHeight > 200) el.scrollTop = el.scrollTop + el.clientHeight * 0.9;
  }
  return true;
})()`

// MARK: Finding each song (same rules as the phone's SongMatcher)

/** Lowercase letters and digits only, keeping words in brackets (for whole video titles). */
function normalizeLoose(s: string): string {
  return s.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase().replace(/[^\p{L}\p{N}]/gu, '')
}

async function matchOfficial(s: SpotifyTrack): Promise<Track | undefined> {
  const artist = mainArtist(s.artist)
  const query = `${s.title} ${artist}`
  let results = await searchSongs(query).catch(() => undefined)
  if (!results) {
    // Big imports can hit YouTube's limit: wait and try once more.
    await sleep(2000)
    results = await searchSongs(query).catch(() => undefined)
  }
  if (!results?.length) return undefined
  const wantTitle = normalize(s.title)
  const wantArtist = normalize(artist)
  let best: [Track, number] | undefined
  results.slice(0, 6).forEach((t, i) => {
    let score = -0.2 * i
    const title = normalize(t.title)
    if (wantTitle && title === wantTitle) score += 3
    else if (wantTitle && (title.includes(wantTitle) || wantTitle.includes(title))) score += 2
    if (wantArtist && normalize(t.artist).includes(wantArtist)) score += 2
    if (s.duration != null && t.duration != null) {
      const diff = Math.abs(s.duration - t.duration)
      if (diff <= 3) score += 2
      else if (diff <= 10) score += 1
      else if (diff > 30) score -= 3
    }
    if (!best || score > best[1]) best = [t, score]
  })
  return best && best[1] >= 1 ? best[0] : undefined
}

/** Words that mean a different version, unless the song title itself has them. */
const otherVersions = ['live', 'cover', 'remix', 'reaction', 'karaoke', 'instrumental', 'slowed', 'spedup', 'nightcore', '8d', '1hour', 'tutorial', 'lesson']

/** Not on YouTube Music: a regular YouTube upload, preferably from the artist's own channel. */
async function matchUpload(s: SpotifyTrack): Promise<Track | undefined> {
  const artist = mainArtist(s.artist)
  const query = `${artist} ${s.title}`
  let results = await searchVideos(query).catch(() => undefined)
  if (!results) {
    await sleep(2000)
    results = await searchVideos(query).catch(() => undefined)
  }
  if (!results?.length) return undefined
  const wantTitle = normalize(s.title)
  const wantArtist = normalize(artist)
  if (!wantTitle) return undefined
  const songWords = normalizeLoose(s.title)
  let best: [(typeof results)[number], number] | undefined
  results.slice(0, 8).forEach((v, i) => {
    const title = normalizeLoose(v.title)
    if (!title.includes(wantTitle)) return
    let score = 3 - 0.2 * i
    // The artist's own channel, its "- Topic" channel or VEVO.
    const channel = normalizeLoose(v.channel).replace('topic', '').replace('vevo', '').replace('official', '')
    if (wantArtist && channel && (channel.includes(wantArtist) || wantArtist.includes(channel))) score += 3
    else if (wantArtist && title.includes(wantArtist)) score += 1
    else score -= 1
    if (s.duration != null && v.duration != null) {
      const diff = Math.abs(s.duration - v.duration)
      if (diff > 60) return
      if (diff <= 3) score += 3
      else if (diff <= 10) score += 1
      else if (diff > 30) score -= 3
    }
    for (const w of otherVersions) if (title.includes(w) && !songWords.includes(w)) score -= 3
    if (!best || score > best[1]) best = [v, score]
  })
  if (!best || best[1] < 4) return undefined
  const v = best[0]
  return { id: v.id, title: s.title, artist: s.artist, duration: v.duration ?? null, artworkURL: `https://i.ytimg.com/vi/${v.id}/hqdefault.jpg`, upload: true }
}

async function match(s: SpotifyTrack): Promise<Track | undefined> {
  return (await matchOfficial(s)) ?? (await matchUpload(s))
}

// MARK: Songs you already have

const key = (title: string, artist: string): string => `${normalize(title)}|${normalize(mainArtist(artist))}`

function localIndex(): Map<string, Track[]> {
  const lib = store.getLibrary()
  const index = new Map<string, Track[]>()
  const seen = new Set<string>()
  for (const t of [...lib.liked, ...lib.playlists.flatMap((p) => p.tracks)]) {
    if (t.podcast || seen.has(t.id)) continue
    seen.add(t.id)
    const k = key(t.title, t.artist)
    index.set(k, [...(index.get(k) ?? []), t])
  }
  return index
}

function lookup(s: SpotifyTrack, index: Map<string, Track[]>): Track | undefined {
  return index.get(key(s.title, s.artist))?.find((t) => s.duration == null || t.duration == null || Math.abs(s.duration - t.duration) <= 10)
}

// MARK: Running an import

let state: ImportState = { phase: 'idle', total: 0, processed: 0, missing: [] }
let lastEmit = 0

function set(change: Partial<ImportState>, force = true): void {
  state = { ...state, ...change }
  // Progress is sent at most a few times a second.
  if (force || Date.now() - lastEmit > 250) {
    lastEmit = Date.now()
    store.emit('import', state)
  }
}

export function getImportState(): ImportState {
  return state
}

export function clearImport(): void {
  if (state.phase === 'reading' || state.phase === 'matching') return
  set({ phase: 'idle', total: 0, processed: 0, missing: [], listName: undefined, playlistId: undefined, error: undefined, hitLimit: false, spotifyTotal: undefined, foundAgain: undefined })
}

/** Matches in parallel (6 at a time) and keeps the original order. */
async function matchAll(tracks: SpotifyTrack[], onEach: () => void): Promise<(Track | undefined)[]> {
  const results: (Track | undefined)[] = new Array(tracks.length)
  let next = 0
  const worker = async (): Promise<void> => {
    while (next < tracks.length) {
      const i = next++
      results[i] = await match(tracks[i]).catch(() => undefined)
      onEach()
    }
  }
  await Promise.all(Array.from({ length: Math.min(6, tracks.length) }, worker))
  return results
}

export async function startImport(link: string): Promise<void> {
  if (state.phase === 'reading' || state.phase === 'matching') return
  set({ phase: 'reading', total: 0, processed: 0, missing: [], listName: undefined, playlistId: undefined, error: undefined, hitLimit: false, spotifyTotal: undefined, startedAt: Date.now(), foundAgain: undefined })
  try {
    const list = await read(link)
    const local = localIndex()
    const id = store.createPlaylist(list.name, [])
    set({ phase: 'matching', listName: list.name, total: list.tracks.length, hitLimit: !!list.limited, spotifyTotal: list.total, playlistId: id, matchStart: Date.now() })

    // Saved in batches of 30, so a big import keeps what it found if Drift is closed.
    const missing: MissingSong[] = []
    for (let start = 0; start < list.tracks.length; start += 30) {
      const slice = list.tracks.slice(start, start + 30)
      const matched: (Track | undefined)[] = new Array(slice.length)
      const toSearch: number[] = []
      slice.forEach((s, i) => {
        const mine = lookup(s, local)
        if (mine) {
          matched[i] = mine
          set({ processed: state.processed + 1 }, false)
        } else {
          toSearch.push(i)
        }
      })
      const searched = await matchAll(toSearch.map((i) => slice[i]), () => set({ processed: state.processed + 1 }, false))
      toSearch.forEach((i, k) => (matched[i] = searched[k]))
      const found: Track[] = []
      matched.forEach((t, i) => {
        if (t) found.push({ ...t, added: slice[i].added ?? null })
        else missing.push({ title: slice[i].title, artist: slice[i].artist, duration: slice[i].duration ?? null })
      })
      if (store.getLibrary().playlists.some((p) => p.id === id)) store.addToPlaylist(id, found, true)
    }
    set({ phase: 'done', missing, processed: list.tracks.length })
    const total = list.tracks.length
    const plural = (n: number): string => `${n} ${n === 1 ? 'song' : 'songs'}`
    if (missing.length) {
      // Kept under the bell, like the phone's import report.
      const report = notices.post({
        kind: 'importReport',
        title: `${plural(missing.length)} not found in “${list.name}”`,
        detail: `${total - missing.length} of ${total} songs imported. Open to see, copy or look for the missing ones.`,
        playlistId: id,
        listName: list.name,
        missing
      })
      notices.system(`Import finished: ${plural(missing.length)} not found`, `${total - missing.length} of ${total} songs from “${list.name}” are in Drift. Click to see the missing ones.`, report.id)
    } else {
      notices.system('Import finished', `All ${plural(total)} from “${list.name}” are in Drift.`)
    }
  } catch (e) {
    set({ phase: 'failed', error: e instanceof ImportError ? e.message : e instanceof Error ? `Couldn’t import: ${e.message}` : 'Couldn’t import.' })
  }
}

/** Looks for the songs that weren't found once more, and adds what turns up. */
export async function retryMissing(): Promise<void> {
  if (state.phase !== 'done' || !state.missing.length || state.retrying || !state.playlistId) return
  set({ retrying: true })
  const songs = state.missing.map((m) => ({ title: m.title, artist: m.artist, duration: m.duration ?? undefined }))
  const results = await matchAll(songs, () => {})
  const found = results.filter((t): t is Track => !!t)
  const still = state.missing.filter((_, i) => !results[i])
  if (found.length && store.getLibrary().playlists.some((p) => p.id === state.playlistId)) store.addToPlaylist(state.playlistId, found)
  set({ retrying: false, missing: still, foundAgain: found.length })
  // Keep the report under the bell the same.
  const report = notices.getNotifications().find((n) => n.kind === 'importReport' && n.playlistId === state.playlistId)
  if (report) notices.updateMissing(report.id, still, found.length)
}

/** Looks for an import report's missing songs again, adds what turns up, and updates the report. */
export async function retryReport(id: string): Promise<void> {
  const n = notices.getNotifications().find((x) => x.id === id)
  if (!n || !n.missing.length || n.retrying) return
  n.retrying = true
  store.emit('notifications', notices.getNotifications())
  try {
    const songs = n.missing.map((m) => ({ title: m.title, artist: m.artist, duration: m.duration ?? undefined }))
    const results = await matchAll(songs, () => {})
    const found = results.filter((t): t is Track => !!t)
    const still = n.missing.filter((_, i) => !results[i])
    if (found.length && n.playlistId && store.getLibrary().playlists.some((p) => p.id === n.playlistId)) store.addToPlaylist(n.playlistId, found)
    notices.updateMissing(id, still, found.length)
    // The import window shows the same list while it's open.
    if (state.phase === 'done' && state.playlistId === n.playlistId) set({ missing: still, foundAgain: (state.foundAgain ?? 0) + found.length })
  } finally {
    n.retrying = false
    store.emit('notifications', notices.getNotifications())
  }
}
