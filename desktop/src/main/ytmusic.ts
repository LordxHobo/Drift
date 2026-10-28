// YouTube Music's own web API (the one music.youtube.com uses), the same calls the phone app makes.
import type { AlbumPage, AlbumRef, ArtistPage, ArtistRef, BrowseRef, SearchResults, Track } from '@shared/types'
import { getSettings } from './store'

type J = any // raw InnerTube JSON

const userAgent =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'

const params = {
  songs: 'EgWKAQIIAWoMEA4QChADEAQQCRAF',
  videos: 'EgWKAQIQAWoMEA4QChADEAQQCRAF',
  artists: 'EgWKAQIgAWoMEA4QChADEAQQCRAF',
  albums: 'EgWKAQIYAWoMEA4QChADEAQQCRAF'
}

/** Same scheme music.youtube.com uses: "1.<today's date>.01.00". */
function clientVersion(): string {
  const d = new Date()
  const p = (n: number): string => String(n).padStart(2, '0')
  return `1.${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}.01.00`
}

export async function post(endpoint: string, fields: Record<string, unknown>): Promise<J> {
  // Node's own fetch: it sends Origin and Referer exactly as given.
  const res = await fetch(`https://music.youtube.com/youtubei/v1/${endpoint}?prettyPrint=false`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Origin: 'https://music.youtube.com',
      Referer: 'https://music.youtube.com/',
      'User-Agent': userAgent
    },
    body: JSON.stringify({
      ...fields,
      context: { client: { clientName: 'WEB_REMIX', clientVersion: clientVersion(), hl: 'en' } }
    })
  })
  if (res.status !== 200) throw new Error(`YouTube Music answered ${res.status}`)
  return res.json()
}

// MARK: JSON walking

function sortedKeys(d: Record<string, unknown>): string[] {
  return Object.keys(d).sort()
}

/** Every musicResponsiveListItemRenderer, in document order. */
export function collect(node: J, found: (r: J) => void): void {
  if (Array.isArray(node)) {
    for (const v of node) collect(v, found)
  } else if (node && typeof node === 'object') {
    const r = node.musicResponsiveListItemRenderer
    if (r && typeof r === 'object') {
      found(r)
      return
    }
    for (const k of sortedKeys(node)) collect(node[k], found)
  }
}

/** Every value under `key`, anywhere. */
export function walk(node: J, key: string, found: (r: J) => void): void {
  if (Array.isArray(node)) {
    for (const v of node) walk(v, key, found)
  } else if (node && typeof node === 'object') {
    for (const k of sortedKeys(node)) {
      if (k === key && node[k] && typeof node[k] === 'object') found(node[k])
      else walk(node[k], key, found)
    }
  }
}

export function firstValue(node: J, key: string): J {
  if (Array.isArray(node)) {
    for (const v of node) {
      const f = firstValue(v, key)
      if (f !== undefined) return f
    }
  } else if (node && typeof node === 'object') {
    if (key in node) return node[key]
    for (const k of sortedKeys(node)) {
      const f = firstValue(node[k], key)
      if (f !== undefined) return f
    }
  }
  return undefined
}

export function dig(node: J, path: (string | number)[]): J {
  let cur = node
  for (const k of path) {
    if (cur == null) return undefined
    cur = cur[k]
  }
  return cur
}

export function text(node: J): string | undefined {
  if (!node || typeof node !== 'object') return undefined
  if (typeof node.simpleText === 'string') return node.simpleText
  if (Array.isArray(node.runs)) {
    const s = node.runs.map((r: J) => r?.text ?? '').join('')
    return s || undefined
  }
  return undefined
}

function columnTexts(column: J, renderer: string): string[] {
  const runs = column?.[renderer]?.text?.runs
  return Array.isArray(runs) ? runs.map((r: J) => r?.text).filter((t: J) => typeof t === 'string') : []
}

export function parseDuration(s: string): number | undefined {
  const parts = s.split(':')
  if (parts.length < 2 || parts.length > 3) return undefined
  let total = 0
  for (const p of parts) {
    if (!/^\d+$/.test(p)) return undefined
    total = total * 60 + Number(p)
  }
  return total
}

function thumbnail(node: J): string | undefined {
  const paths = [
    ['thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails'],
    ['thumbnail', 'croppedSquareThumbnailRenderer', 'thumbnail', 'thumbnails'],
    ['thumbnailRenderer', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails']
  ]
  for (const p of paths) {
    const list = dig(node, p)
    if (Array.isArray(list) && list.length) {
      const url = list[list.length - 1]?.url
      if (typeof url === 'string') return url.startsWith('//') ? 'https:' + url : url
    }
  }
  return undefined
}

/** A playable song or video from a list row. `requireDuration: false` for artist and album pages. */
export function parseTrack(r: J, requireDuration = true): Track | undefined {
  const cols = r?.flexColumns
  if (!Array.isArray(cols) || !cols.length) return undefined
  const id: string | undefined = r.playlistItemData?.videoId ?? firstValue(cols[0], 'videoId')
  if (typeof id !== 'string') return undefined
  const title = columnTexts(cols[0], 'musicResponsiveListItemFlexColumnRenderer').join('')
  if (!title) return undefined

  const meta = cols.length > 1 ? columnTexts(cols[1], 'musicResponsiveListItemFlexColumnRenderer').join('') : ''
  const parts = meta.split('•').map((s) => s.trim()).filter(Boolean)
  if (parts.length && ['Song', 'Video', 'Episode'].includes(parts[0])) parts.shift()

  let duration: number | undefined
  if (parts.length) {
    const d = parseDuration(parts[parts.length - 1])
    if (d !== undefined) {
      duration = d
      parts.pop()
    }
  }
  if (duration === undefined && Array.isArray(r.fixedColumns) && r.fixedColumns.length) {
    duration = parseDuration(columnTexts(r.fixedColumns[0], 'musicResponsiveListItemFixedColumnRenderer').join(''))
  }
  if (duration === undefined && requireDuration) return undefined

  const artist = parts[0] ?? ''
  const second = parts[1]?.toLowerCase() ?? ''
  const album = parts.length > 1 && !second.includes('view') && !second.includes('play') ? parts[1] : undefined
  const t: Track = { id, title, artist, album: album ?? null, duration: duration ?? null, artworkURL: thumbnail(r) ?? null }
  if (isExplicit(r)) t.explicit = true
  return t
}

/** YouTube Music's "E" (explicit) badge somewhere on a row. */
export function isExplicit(r: J): boolean {
  let found = false
  const visit = (n: J): void => {
    if (found || !n || typeof n !== 'object') return
    if (Array.isArray(n)) return n.forEach(visit)
    if (n.iconType === 'MUSIC_EXPLICIT_BADGE') {
      found = true
      return
    }
    for (const k of Object.keys(n)) if (k !== 'menu') visit(n[k])
  }
  visit(r)
  return found
}

function albumRef(r: J): AlbumRef | undefined {
  const id = dig(r, ['navigationEndpoint', 'browseEndpoint', 'browseId'])
  const title = text(r.title)
  if (typeof id !== 'string' || !id.startsWith('MPRE') || !title) return undefined
  return { id, title, subtitle: text(r.subtitle) ?? '', thumbnail: thumbnail(r) ?? null }
}

// MARK: Search

export function searchSongs(query: string, songsOnly = true): Promise<Track[]> {
  return search(query, songsOnly ? params.songs : undefined)
}

async function search(query: string, filter?: string): Promise<Track[]> {
  const json = await post('search', filter ? { query, params: filter } : { query })
  const out: Track[] = []
  const seen = new Set<string>()
  collect(json, (r) => {
    const t = parseTrack(r)
    if (t && !seen.has(t.id)) {
      seen.add(t.id)
      out.push(t)
    }
  })
  return getSettings().preferExplicit ? withoutCleanTwins(out) : out
}

// MARK: Explicit versions

/** Words that make a different recording (a remix isn't the explicit version of the original). */
const variantWords = /\b(remix|mix|live|acoustic|instrumental|sped up|slowed|karaoke|cover|demo|a ?cappella|nightcore|8d|reverb|unplugged|orchestral|piano version)\b/gi

function variants(title: string): string {
  return [...new Set((title.toLowerCase().match(variantWords) ?? []).map((w) => w.replace(/\s+/g, ' ')))].sort().join('|')
}

/** Same song and same recording type: only the clean/explicit edit may differ. */
export function sameSong(a: Track, b: Track, maxDiff = 10): boolean {
  if (normalize(a.title) !== normalize(b.title) || variants(a.title) !== variants(b.title)) return false
  const artist = normalize(mainArtist(a.artist))
  if (artist && !normalize(b.artist).includes(artist) && !normalize(a.artist).includes(normalize(mainArtist(b.artist)))) return false
  return a.duration == null || b.duration == null || Math.abs(a.duration - b.duration) <= maxDiff
}

/** "Song (Clean)", "Song - Radio Edit" → "Song", for searching. */
export function withoutCleanTag(title: string): string {
  return title
    .replace(/\s*[([]\s*(clean|clean version|edited|edited version|radio edit|censored|super clean)\s*[)\]]/gi, '')
    .replace(/\s+-\s+(clean|clean version|edited|radio edit|censored)\s*$/i, '')
    .trim()
}

/** Drops a clean song from results when its explicit twin is also there. */
function withoutCleanTwins(list: Track[]): Track[] {
  const explicit = list.filter((t) => t.explicit)
  if (!explicit.length) return list
  return list.filter((t) => t.explicit || !explicit.some((e) => sameSong(t, e)))
}

/**
 * The explicit version of a song when the one about to play is clean. `known` holds what's already
 * known about which IDs are explicit. `onlySongs`: leave music videos alone (album versions are off).
 */
export async function explicitVersion(track: Track, playId: string, known: Map<string, boolean>, onlySongs: boolean): Promise<string | undefined> {
  if (known.get(playId) || track.explicit) return undefined
  const title = withoutCleanTag(track.title)
  if (!title) return undefined
  const json = await post('search', { query: `${title} ${mainArtist(track.artist)}`, params: params.songs })
  const rows: { t: Track; song: boolean }[] = []
  collect(json, (r) => {
    const t = parseTrack(r, false)
    if (!t) return
    known.set(t.id, !!t.explicit)
    rows.push({ t, song: firstValue(r, 'musicVideoType') === atv })
  })
  if (known.get(playId)) return undefined
  if (onlySongs && !rows.some((r) => r.t.id === track.id && r.song)) return undefined
  // Compare lengths with what was going to play (the album version can be shorter than a music video).
  const playing = rows.find((r) => r.t.id === playId)?.t
  const ref: Track = { ...track, title, duration: playing?.duration ?? (playId === track.id ? track.duration : null) }
  let best: { id: string; diff: number } | undefined
  for (const { t, song } of rows) {
    if (!song || !t.explicit || t.id === playId || !sameSong(ref, t)) continue
    const diff = ref.duration != null && t.duration != null ? Math.abs(ref.duration - t.duration) : 5
    if (!best || diff < best.diff) best = { id: t.id, diff }
  }
  return best?.id
}

export async function searchArtists(query: string): Promise<ArtistRef[]> {
  const json = await post('search', { query, params: params.artists })
  const out: ArtistRef[] = []
  collect(json, (r) => {
    const id = dig(r, ['navigationEndpoint', 'browseEndpoint', 'browseId'])
    const cols = r.flexColumns
    if (typeof id !== 'string' || !id.startsWith('UC') || !Array.isArray(cols)) return
    const name = columnTexts(cols[0], 'musicResponsiveListItemFlexColumnRenderer').join('')
    if (!name || out.some((a) => a.id === id)) return
    out.push({ id, name, thumbnail: thumbnail(r) ?? null })
  })
  return out
}

export async function searchAlbums(query: string): Promise<AlbumRef[]> {
  const json = await post('search', { query, params: params.albums })
  const out: AlbumRef[] = []
  collect(json, (r) => {
    const id = dig(r, ['navigationEndpoint', 'browseEndpoint', 'browseId'])
    const cols = r.flexColumns
    if (typeof id !== 'string' || !id.startsWith('MPRE') || !Array.isArray(cols)) return
    const title = columnTexts(cols[0], 'musicResponsiveListItemFlexColumnRenderer').join('')
    const subtitle = cols.length > 1 ? columnTexts(cols[1], 'musicResponsiveListItemFlexColumnRenderer').join('') : ''
    if (!title || out.some((a) => a.id === id)) return
    out.push({ id, title, subtitle, thumbnail: thumbnail(r) ?? null })
  })
  return out
}

export async function searchAll(query: string): Promise<SearchResults> {
  const [songs, videos, artists, albums] = await Promise.all([
    search(query, params.songs).catch(() => []),
    search(query, params.videos).catch(() => []),
    searchArtists(query).catch(() => []),
    searchAlbums(query).catch(() => [])
  ])
  if (!songs.length && !videos.length && !artists.length && !albums.length) {
    // Every request failed or found nothing: try once without filters so a real error shows.
    const any = await search(query)
    return { songs: any, videos: [], artists: [], albums: [] }
  }
  return { songs, videos, artists, albums }
}

export async function suggestions(input: string): Promise<string[]> {
  const json = await post('music/get_search_suggestions', { input })
  const out: string[] = []
  walk(json, 'searchSuggestionRenderer', (r) => {
    const s = text(r.suggestion)
    if (s && !out.includes(s)) out.push(s)
  })
  return out.slice(0, 8)
}

// MARK: Normalising (same rules as the phone)

export function normalize(s: string): string {
  let t = s.replace(/\s*[([][^)\]]*[)\]]/g, '')
  t = t.replace(/\s+-\s+.*$/, '')
  return t
    .normalize('NFD')
    .replace(/\p{M}/gu, '')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]/gu, '')
}

export function mainArtist(a: string): string {
  let s = a
  for (const sep of [', ', ' & ', ' x ', ' feat. ', ' ft. ']) {
    const i = s.toLowerCase().indexOf(sep)
    if (i >= 0) s = s.slice(0, i)
  }
  return s.trim()
}

/** The artist the search is most likely about (name matches what was typed). */
export function bestArtist(artists: ArtistRef[], query: string): ArtistRef | null {
  const q = normalize(query)
  if (!q) return null
  return (
    artists.slice(0, 3).find((a) => {
      const n = normalize(a.name)
      return n === q || (q.length >= 3 && (n.startsWith(q) || q.startsWith(n)))
    }) ?? null
  )
}

// MARK: Artist and album pages

export async function artistPage(id: string, fallbackName = ''): Promise<ArtistPage> {
  const json = await post('browse', { browseId: id })
  const header = dig(json, ['header', 'musicImmersiveHeaderRenderer']) ?? dig(json, ['header', 'musicVisualHeaderRenderer'])
  const name = text(header?.title) ?? fallbackName
  const page: ArtistPage = {
    id,
    name,
    thumbnail: thumbnail(header) ?? null,
    subtitle: null,
    topSongs: [],
    albums: [],
    singles: []
  }
  const subs = text(dig(header, ['subscriptionButton', 'subscribeButtonRenderer', 'subscriberCountText']))
  if (subs) page.subtitle = `${subs} subscribers`
  const monthly = text(header?.monthlyListenerCount)
  if (monthly) page.subtitle = monthly.replace(' monthly audience', ' monthly listeners')

  const sections: J[] =
    dig(json, ['contents', 'singleColumnBrowseResultsRenderer', 'tabs', 0, 'tabRenderer', 'content', 'sectionListRenderer', 'contents']) ??
    dig(json, ['contents', 'twoColumnBrowseResultsRenderer', 'tabs', 0, 'tabRenderer', 'content', 'sectionListRenderer', 'contents']) ??
    []
  for (const section of sections) {
    const shelf = section?.musicShelfRenderer
    if (shelf && !page.topSongs.length) {
      for (const item of shelf.contents ?? []) {
        const t = item?.musicResponsiveListItemRenderer && parseTrack(item.musicResponsiveListItemRenderer, false)
        if (t) {
          if (!t.artist) t.artist = name
          page.topSongs.push(t)
        }
      }
    }
    const carousel = section?.musicCarouselShelfRenderer
    if (!carousel) continue
    const titleNode = dig(carousel, ['header', 'musicCarouselShelfBasicHeaderRenderer', 'title'])
    const title = (text(titleNode) ?? '').toLowerCase()
    const items: AlbumRef[] = (carousel.contents ?? [])
      .map((i: J) => i?.musicTwoRowItemRenderer && albumRef(i.musicTwoRowItemRenderer))
      .filter(Boolean)
    const browse = dig(titleNode, ['runs', 0, 'navigationEndpoint', 'browseEndpoint'])
    const more: BrowseRef | null = typeof browse?.browseId === 'string' ? { id: browse.browseId, params: browse.params ?? null } : null
    if (title.includes('single') || title.includes(' ep')) {
      page.singles = items
      page.singlesMore = more
    } else if (title.includes('album')) {
      page.albums = items
      page.albumsMore = more
    }
  }
  return page
}

export async function discography(ref: BrowseRef): Promise<AlbumRef[]> {
  const json = await post('browse', ref.params ? { browseId: ref.id, params: ref.params } : { browseId: ref.id })
  const out: AlbumRef[] = []
  walk(json, 'musicTwoRowItemRenderer', (r) => {
    const a = albumRef(r)
    if (a && !out.some((x) => x.id === a.id)) out.push(a)
  })
  return out
}

export async function albumPage(id: string): Promise<AlbumPage> {
  const json = await post('browse', { browseId: id })
  let header: J
  walk(json, 'musicResponsiveHeaderRenderer', (r) => (header ??= r))
  if (!header) walk(json, 'musicDetailHeaderRenderer', (r) => (header ??= r))
  const title = text(header?.title) ?? ''
  const subtitle = text(header?.subtitle) ?? ''
  const artist = text(header?.straplineTextOne) ?? ''
  const art = thumbnail(header) ?? null
  const tracks: Track[] = []
  const seen = new Set<string>()
  collect(json, (r) => {
    const t = parseTrack(r, false)
    if (!t || seen.has(t.id)) return
    seen.add(t.id)
    if (!t.artist) t.artist = artist
    t.album = title
    if (!t.artworkURL) t.artworkURL = art
    tracks.push(t)
  })
  return { id, title, subtitle, artist, thumbnail: art, tracks }
}

// MARK: Radio (what plays after the queue ends) and album versions

function panelTracks(json: J): J[] {
  const out: J[] = []
  walk(json, 'playlistPanelVideoRenderer', (r) => out.push(r))
  return out
}

function videoType(r: J): string | undefined {
  return dig(r, ['navigationEndpoint', 'watchEndpoint', 'watchEndpointMusicSupportedConfigs', 'watchEndpointMusicConfig', 'musicVideoType'])
}

export async function radio(id: string): Promise<Track[]> {
  const json = await post('next', {
    videoId: id,
    playlistId: `RDAMVM${id}`,
    isAudioOnly: true,
    enablePersistentPlaylistPanel: true
  })
  const out: Track[] = []
  for (const r of panelTracks(json)) {
    const vid = r.videoId
    const title = text(r.title)
    if (typeof vid !== 'string' || !title || vid === id || out.some((t) => t.id === vid)) continue
    const byline = (text(r.longBylineText) ?? text(r.shortBylineText) ?? '').split('•').map((s) => s.trim())
    out.push({
      id: vid,
      title,
      artist: byline[0] ?? '',
      album: byline.length > 2 ? byline[1] : null,
      duration: parseDuration(text(r.lengthText) ?? '') ?? null,
      artworkURL: thumbnail(r) ?? (Array.isArray(r.thumbnail?.thumbnails) ? r.thumbnail.thumbnails.at(-1)?.url : null) ?? null,
      ...(isExplicit(r) ? { explicit: true } : {})
    })
  }
  return out
}

const atv = 'MUSIC_VIDEO_TYPE_ATV'

/**
 * The album version of a music video, when YouTube Music has one: first its own link between the two,
 * then a "songs" search for the same title and artist. Returns [id to play, what was found].
 */
export async function albumVersion(track: Track, known: Map<string, boolean> = new Map()): Promise<[string, string]> {
  const id = track.id
  let linkNote = 'YouTube Music link: no answer'
  try {
    const json = await post('next', {
      videoId: id,
      playlistId: `RDAMVM${id}`,
      isAudioOnly: true,
      enablePersistentPlaylistPanel: true,
      watchEndpointMusicSupportedConfigs: {
        watchEndpointMusicConfig: { hasPersistentPlaylistPanel: true, musicVideoType: atv }
      }
    })
    let first: J
    walk(json, 'playlistPanelRenderer', (p) => {
      if (first === undefined && Array.isArray(p.contents)) first = p.contents[0]
    })
    if (first) {
      const candidates = panelTracks(first)
      for (const c of candidates) if (typeof c.videoId === 'string') known.set(c.videoId, isExplicit(c))
      const types = candidates.map((c) => [c.videoId as string | undefined, videoType(c)] as const)
      const own = types.find((t) => t[0] === id)?.[1]
      const short = (own ?? 'unknown').replace('MUSIC_VIDEO_TYPE_', '')
      if (own === atv) return [id, 'Already album audio (ATV)']
      const other = types.find((t) => t[1] === atv && t[0] && t[0] !== id)?.[0]
      if (other) return [other, `Album version via YouTube Music link (this video: ${short})`]
      linkNote = `YouTube Music link: none (this video: ${short})`
    }
  } catch {
    // fall through to search
  }

  const artist = mainArtist(track.artist)
  if (!track.title) return [id, linkNote]
  const json = await post('search', { query: `${track.title} ${artist}`, params: params.songs })
  const wantTitle = normalize(track.title)
  const wantArtist = normalize(artist)
  let best: { id: string; diff: number } | undefined
  collect(json, (r) => {
    const t = parseTrack(r, false)
    if (t) known.set(t.id, !!t.explicit)
    if (!t || firstValue(r, 'musicVideoType') !== atv) return
    if (normalize(t.title) !== wantTitle) return
    if (wantArtist && !normalize(t.artist).includes(wantArtist)) return
    if (t.id === id) {
      best = { id, diff: -1 }
      return
    }
    const diff = track.duration != null && t.duration != null ? Math.abs(track.duration - t.duration) : 5
    if (diff > 6) return
    if (!best || diff < best.diff) best = { id: t.id, diff }
  })
  if (best) {
    return best.id === id
      ? [id, `${linkNote}; search: this is the album version`]
      : [best.id, `${linkNote}; album version found by search`]
  }
  return [id, `${linkNote}; search: no album version matched`]
}
