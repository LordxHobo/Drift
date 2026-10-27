// Importing a public Spotify playlist or album (the same approach as the phone's importer).
import { BrowserWindow, net, session } from 'electron'
import type { ImportState, MissingSong, Track } from '@shared/types'
import * as store from './store'
import { mainArtist, normalize, searchSongs } from './ytmusic'
import { searchVideos } from './youtube'

interface SpotifyTrack {
  title: string
  artist: string
  duration?: number
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

// MARK: Reading the list

async function read(link: string): Promise<SpotifyList> {
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
  return readEmbed(kind, id)
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

/**
 * A whole playlist of any length: Spotify's page is opened in a hidden window, its own request for
 * the song list is noted, then repeated inside the page for each next page of songs. No account or
 * developer keys needed.
 */
async function readFullPlaylist(id: string): Promise<SpotifyList> {
  const partition = `spotify-import-${Date.now()}` // in memory only, gone afterwards
  const ses = session.fromPartition(partition)
  ses.setUserAgent(chromeUA)
  const pending = new Map<number, { url: string; body?: string }>()
  let captured: { url: string; body?: string; headers: Record<string, string> } | undefined
  let ready: () => void = () => {}
  const gotRequest = new Promise<void>((r) => (ready = r))
  const filter = { urls: ['https://*.spotify.com/*'] }

  ses.webRequest.onBeforeRequest(filter, (d, cb) => {
    if (!captured && d.url.includes('pathfinder')) {
      const body = d.uploadData?.map((u) => (u.bytes ? Buffer.from(u.bytes).toString('utf8') : '')).join('') || undefined
      if (/fetchPlaylist/.test(`${body ?? ''} ${d.url}`)) pending.set(d.id, { url: d.url, body })
    }
    cb({})
  })
  ses.webRequest.onBeforeSendHeaders(filter, (d, cb) => {
    const p = pending.get(d.id)
    if (p && !captured) {
      captured = { ...p, headers: d.requestHeaders }
      ready()
    }
    cb({ requestHeaders: d.requestHeaders })
  })

  const win = new BrowserWindow({
    show: false,
    width: 1280,
    height: 900,
    webPreferences: { partition, sandbox: true, contextIsolation: true, backgroundThrottling: false }
  })
  win.webContents.setAudioMuted(true)
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))
  try {
    void win.loadURL(`https://open.spotify.com/playlist/${id}`)
    await Promise.race([gotRequest, new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), 25_000))])
    const result = await win.webContents.executeJavaScript(fetchAllScript(captured!), true)
    const parsed = JSON.parse(result) as { name?: string; tracks?: { t: string; a: string; ms: number }[] }
    const tracks = (parsed.tracks ?? []).map((t) => ({ title: t.t, artist: t.a, duration: t.ms > 0 ? t.ms / 1000 : undefined }))
    return { name: parsed.name ?? 'Spotify import', tracks }
  } finally {
    win.destroy()
    void ses.clearStorageData().catch(() => undefined)
  }
}

/** Pages through the playlist with the captured request (runs inside Spotify's page). */
function fetchAllScript(req: { url: string; body?: string; headers: Record<string, string> }): string {
  // Headers the page isn't allowed to set itself are left out (the browser adds them).
  const headers: Record<string, string> = {}
  for (const [k, v] of Object.entries(req.headers)) {
    if (!/^(host|origin|referer|cookie|connection|content-length|accept-encoding|user-agent|sec-|proxy-)/i.test(k)) headers[k] = v
  }
  const r = { url: req.url, body: req.body ?? null, headers }
  return `(async () => {
    const r = ${JSON.stringify(r)};
    const build = (offset, limit) => {
      if (r.body) {
        const b = JSON.parse(r.body);
        b.variables = Object.assign({}, b.variables, { offset, limit });
        return [r.url, { method: 'POST', headers: r.headers, body: JSON.stringify(b) }];
      }
      const u = new URL(r.url);
      const v = JSON.parse(u.searchParams.get('variables') || '{}');
      v.offset = offset; v.limit = limit;
      u.searchParams.set('variables', JSON.stringify(v));
      return [u.toString(), { method: 'GET', headers: r.headers }];
    };
    let name = null, total = null, offset = 0, limit = 100;
    const tracks = [];
    for (let guard = 0; guard < 200; guard++) {
      let j = null;
      try {
        const [url, init] = build(offset, limit);
        const res = await fetch(url, init);
        j = await res.json();
      } catch (e) { j = null; }
      const pl = j && j.data && (j.data.playlistV2 || j.data.playlist);
      if (!pl || !pl.content) {
        if (limit !== 25 && offset === 0) { limit = 25; continue; }
        break;
      }
      if (!name && pl.name) name = pl.name;
      total = pl.content.totalCount;
      const items = pl.content.items || [];
      for (const it of items) {
        const d = it && it.itemV2 && it.itemV2.data;
        if (!d || !d.name || (d.__typename && d.__typename !== 'Track')) continue;
        const artists = ((d.artists && d.artists.items) || []).map(a => a && a.profile && a.profile.name).filter(Boolean);
        tracks.push({ t: d.name, a: artists[0] || '', ms: (d.trackDuration && d.trackDuration.totalMilliseconds) || 0 });
      }
      offset += items.length;
      if (items.length === 0 || (total != null && offset >= total)) break;
    }
    return JSON.stringify({ name, total, tracks });
  })()`
}

// MARK: Finding each song (same rules as the phone's SongMatcher)

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms))

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
  set({ phase: 'idle', total: 0, processed: 0, missing: [], listName: undefined, playlistId: undefined, error: undefined, hitLimit: false, foundAgain: undefined })
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
  set({ phase: 'reading', total: 0, processed: 0, missing: [], listName: undefined, playlistId: undefined, error: undefined, hitLimit: false, startedAt: Date.now(), foundAgain: undefined })
  try {
    const list = await read(link)
    const local = localIndex()
    const id = store.createPlaylist(list.name, [])
    set({ phase: 'matching', listName: list.name, total: list.tracks.length, hitLimit: list.tracks.length === embedLimit, playlistId: id, matchStart: Date.now() })

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
        if (t) found.push(t)
        else missing.push({ title: slice[i].title, artist: slice[i].artist, duration: slice[i].duration ?? null })
      })
      if (store.getLibrary().playlists.some((p) => p.id === id)) store.addToPlaylist(id, found)
    }
    set({ phase: 'done', missing, processed: list.tracks.length })
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
}
