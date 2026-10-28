// Regular YouTube search (not YouTube Music), used to find songs that aren't on YouTube Music.
import type { Chapter, PodcastChannel, Track } from '@shared/types'
import { appleEpoch } from '@shared/types'
import { dig, parseDuration, text } from './ytmusic'

type J = any

export interface Video {
  id: string
  title: string
  channel: string
  duration?: number
}

const userAgent =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'

/** Same scheme youtube.com uses: "2.<yesterday's date>.00.00". */
function clientVersion(): string {
  const d = new Date(Date.now() - 86400_000)
  const p = (n: number): string => String(n).padStart(2, '0')
  return `2.${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}.00.00`
}

async function post(path: string, body: Record<string, unknown>): Promise<J> {
  const version = clientVersion()
  const res = await fetch(`https://www.youtube.com/youtubei/v1/${path}?prettyPrint=false`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'User-Agent': userAgent,
      Origin: 'https://www.youtube.com',
      'X-YouTube-Client-Name': '1',
      'X-YouTube-Client-Version': version
    },
    body: JSON.stringify({ ...body, context: { client: { clientName: 'WEB', clientVersion: version, hl: 'en', gl: 'US' } } })
  })
  if (res.status !== 200) throw new Error(`YouTube answered ${res.status}`)
  return res.json()
}

function viewText(node: J): string | undefined {
  if (node && typeof node.content === 'string') return node.content
  return text(node)
}

function strings(node: J): string[] {
  if (typeof node === 'string') return [node]
  if (Array.isArray(node)) return node.flatMap(strings)
  if (node && typeof node === 'object') return Object.keys(node).sort().flatMap((k) => strings(node[k]))
  return []
}

function parseVideo(r: J): Video | undefined {
  const id = r?.videoId
  const title = viewText(r?.title)
  if (typeof id !== 'string' || !title) return undefined
  const duration = parseDuration(viewText(r.lengthText) ?? '')
  // Live streams have no length; shorts are under a minute.
  if (duration === undefined || duration < 60) return undefined
  return { id, title, channel: dig(r, ['ownerText', 'runs', 0, 'text']) ?? '', duration }
}

function parseLockup(v: J): Video | undefined {
  const id = v?.contentId
  if (typeof id !== 'string' || id.length !== 11 || v.contentType !== 'LOCKUP_CONTENT_TYPE_VIDEO') return undefined
  const meta = dig(v, ['metadata', 'lockupMetadataViewModel'])
  const title = viewText(meta?.title)
  if (!title) return undefined
  const duration = strings(dig(v, ['contentImage', 'thumbnailViewModel', 'overlays']))
    .map(parseDuration)
    .find((d) => d !== undefined)
  if (duration === undefined || duration < 60) return undefined
  let channel = ''
  for (const row of dig(meta, ['metadata', 'contentMetadataViewModel', 'metadataRows']) ?? []) {
    for (const part of row?.metadataParts ?? []) {
      const browse = dig(part, ['text', 'commandRuns', 0, 'onTap', 'innertubeCommand', 'browseEndpoint', 'browseId'])
      if (typeof browse === 'string' && browse.startsWith('UC')) channel = viewText(part.text) ?? channel
    }
  }
  return { id, title, channel, duration }
}

export async function searchVideos(query: string): Promise<Video[]> {
  const json = await post('search', { query })
  const out: Video[] = []
  const visit = (node: J): void => {
    if (Array.isArray(node)) return node.forEach(visit)
    if (!node || typeof node !== 'object') return
    for (const k of Object.keys(node).sort()) {
      const v = node[k]
      if (k === 'videoRenderer' || k === 'lockupViewModel') {
        const video = k === 'videoRenderer' ? parseVideo(v) : parseLockup(v)
        if (video && !out.some((x) => x.id === video.id)) out.push(video)
      } else {
        visit(v)
      }
    }
  }
  visit(json)
  return out
}

// MARK: Podcasts (any YouTube channel or video, played as an episode)


const fixURL = (s: string | undefined): string | null => (s ? (s.startsWith('//') ? 'https:' + s : s) : null)

/** "3 days ago" → seconds since 2001 (how the phone stores dates). */
function relativeDate(s: string | undefined): number | null {
  const m = s && /(\d+)\s+(second|minute|hour|day|week|month|year)/.exec(s)
  if (!m) return null
  const unit = { second: 1, minute: 60, hour: 3600, day: 86400, week: 7 * 86400, month: 30 * 86400, year: 365 * 86400 }[m[2] as 'day']
  return Date.now() / 1000 - Number(m[1]) * unit - appleEpoch
}

function episodeFromVideo(r: J): Track | undefined {
  const v = parseVideo(r)
  if (!v) return undefined
  const owner = dig(r, ['ownerText', 'runs', 0])
  const thumbs = dig(r, ['thumbnail', 'thumbnails'])
  return {
    id: v.id,
    title: v.title,
    artist: v.channel,
    duration: v.duration ?? null,
    artworkURL: fixURL(Array.isArray(thumbs) ? thumbs.at(-1)?.url : undefined) ?? `https://i.ytimg.com/vi/${v.id}/mqdefault.jpg`,
    podcast: true,
    channelID: dig(owner, ['navigationEndpoint', 'browseEndpoint', 'browseId']) ?? null,
    channelAvatar: fixURL(dig(r, ['channelThumbnailSupportedRenderers', 'channelThumbnailWithLinkRenderer', 'thumbnail', 'thumbnails', 0, 'url'])),
    published: relativeDate(viewText(r.publishedTimeText))
  }
}

function episodeFromLockup(v: J): Track | undefined {
  const base = parseLockup(v)
  if (!base) return undefined
  const meta = dig(v, ['metadata', 'lockupMetadataViewModel'])
  let channelID: string | null = null
  for (const row of dig(meta, ['metadata', 'contentMetadataViewModel', 'metadataRows']) ?? []) {
    for (const part of row?.metadataParts ?? []) {
      const browse = dig(part, ['text', 'commandRuns', 0, 'onTap', 'innertubeCommand', 'browseEndpoint', 'browseId'])
      if (typeof browse === 'string' && browse.startsWith('UC')) channelID = browse
    }
  }
  const rows = dig(meta, ['metadata', 'contentMetadataViewModel', 'metadataRows'])
  const sources = dig(v, ['contentImage', 'thumbnailViewModel', 'image', 'sources'])
  const avatar = strings(meta?.image).find((s) => s.startsWith('https://yt3') || s.startsWith('//yt3'))
  return {
    id: base.id,
    title: base.title,
    artist: base.channel,
    duration: base.duration ?? null,
    artworkURL: fixURL(Array.isArray(sources) ? sources.at(-1)?.url : undefined) ?? `https://i.ytimg.com/vi/${base.id}/mqdefault.jpg`,
    podcast: true,
    channelID,
    channelAvatar: fixURL(avatar),
    published: relativeDate(strings(rows).find((s) => s.endsWith(' ago')))
  }
}

function parseChannel(r: J): PodcastChannel | undefined {
  const id = r?.channelId
  const name = viewText(r?.title)
  if (typeof id !== 'string' || !name) return undefined
  const thumbs = dig(r, ['thumbnail', 'thumbnails'])
  const candidates = [viewText(r.videoCountText), viewText(r.subscriberCountText)].filter((s): s is string => !!s)
  return {
    id,
    name,
    avatarURL: fixURL(Array.isArray(thumbs) ? thumbs.at(-1)?.url : undefined),
    subtitle: candidates.find((s) => s.includes('subscriber')) ?? candidates[0] ?? null
  }
}

function collectEpisodes(json: J, channels?: PodcastChannel[]): Track[] {
  const out: Track[] = []
  const visit = (node: J): void => {
    if (Array.isArray(node)) return node.forEach(visit)
    if (!node || typeof node !== 'object') return
    for (const k of Object.keys(node).sort()) {
      const v = node[k]
      if (k === 'videoRenderer' || k === 'lockupViewModel') {
        const t = k === 'videoRenderer' ? episodeFromVideo(v) : episodeFromLockup(v)
        if (t && !out.some((x) => x.id === t.id)) out.push(t)
      } else if (k === 'channelRenderer' && channels) {
        const c = parseChannel(v)
        if (c && !channels.some((x) => x.id === c.id)) channels.push(c)
      } else {
        visit(v)
      }
    }
  }
  visit(json)
  return out
}

export async function searchPodcasts(query: string): Promise<{ channels: PodcastChannel[]; episodes: Track[] }> {
  const json = await post('search', { query })
  const channels: PodcastChannel[] = []
  const episodes = collectEpisodes(json, channels)
  return { channels, episodes }
}

/** Latest episodes of a channel: its RSS feed, or its Videos tab if the feed fails. */
export async function channelEpisodes(channel: PodcastChannel): Promise<Track[]> {
  try {
    const res = await fetch(`https://www.youtube.com/feeds/videos.xml?channel_id=${channel.id}`, { headers: { 'User-Agent': userAgent } })
    if (res.status === 200) {
      const xml = await res.text()
      const unescape = (s: string): string =>
        s.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'")
      const out: Track[] = []
      for (const entry of xml.split('<entry>').slice(1)) {
        const id = /<yt:videoId>([^<]+)<\/yt:videoId>/.exec(entry)?.[1]
        const title = /<title>([^<]*)<\/title>/.exec(entry)?.[1]
        const link = /<link[^>]*href="([^"]+)"/.exec(entry)?.[1] ?? ''
        const published = /<published>([^<]+)<\/published>/.exec(entry)?.[1]
        const author = /<author>\s*<name>([^<]*)<\/name>/.exec(entry)?.[1]
        if (!id || id.length !== 11 || !title || link.includes('/shorts/')) continue
        out.push({
          id,
          title: unescape(title),
          artist: author ? unescape(author) : channel.name,
          duration: null,
          artworkURL: `https://i.ytimg.com/vi/${id}/mqdefault.jpg`,
          podcast: true,
          channelID: channel.id,
          channelAvatar: channel.avatarURL ?? null,
          published: published ? Date.parse(published) / 1000 - appleEpoch : null
        })
      }
      if (out.length) return out
    }
  } catch {
    // fall back to the Videos tab
  }
  const json = await post('browse', { browseId: channel.id, params: 'EgZ2aWRlb3PyBgQKAjoA' })
  return collectEpisodes(json).map((t) => ({
    ...t,
    channelID: channel.id,
    artist: !t.artist || t.artist === 'YouTube' ? channel.name : t.artist,
    channelAvatar: t.channelAvatar ?? channel.avatarURL ?? null
  }))
}

/** A YouTube link (watch, youtu.be, shorts, live, embed, music.youtube) → video ID. */
export function videoId(text: string): string | undefined {
  const s = text.trim()
  if (!s.includes('youtu')) return undefined
  for (const p of [/[?&]v=([A-Za-z0-9_-]{11})/, /youtu\.be\/([A-Za-z0-9_-]{11})/, /\/(?:shorts|live|embed)\/([A-Za-z0-9_-]{11})/]) {
    const m = p.exec(s)
    if (m) return m[1]
  }
  return undefined
}

/** One video from its link. */
export async function videoFromLink(link: string): Promise<Track | null> {
  const id = videoId(link)
  if (!id) return null
  const found = await searchPodcasts(id).then((r) => r.episodes.find((t) => t.id === id)).catch(() => undefined)
  if (found) return found
  const res = await fetch(`https://www.youtube.com/oembed?url=${encodeURIComponent(`https://www.youtube.com/watch?v=${id}`)}&format=json`)
  if (res.status !== 200) return null
  const o = (await res.json()) as { title: string; author_name?: string }
  return { id, title: o.title, artist: o.author_name ?? 'YouTube', duration: null, artworkURL: `https://i.ytimg.com/vi/${id}/mqdefault.jpg`, podcast: true }
}

// MARK: Chapters

/** "1:02:03" or "12:34" → seconds. */
function clock(s: string): number | undefined {
  const parts = s.split(':').map(Number)
  if (parts.length < 2 || parts.length > 3 || parts.some((n) => !Number.isFinite(n))) return undefined
  // Seconds (and minutes, when there are hours) stay under 60.
  if (parts.slice(1).some((n) => n >= 60)) return undefined
  return parts.reduce((total, n) => total * 60 + n, 0)
}

const thumbOf = (node: J): string | undefined => {
  const list = dig(node, ['thumbnail', 'thumbnails'])
  return Array.isArray(list) ? fixURL(list.at(-1)?.url) ?? undefined : undefined
}

/** The chapters YouTube shows on the progress bar (written by the creator, or made automatically). */
function playerBarChapters(json: J): Chapter[] {
  const found: Chapter[][] = []
  const visit = (node: J): void => {
    if (Array.isArray(node)) return node.forEach(visit)
    if (!node || typeof node !== 'object') return
    if (Array.isArray(node.chapters) && node.chapters.some((c: J) => c?.chapterRenderer)) {
      found.push(
        node.chapters
          .map((c: J) => c?.chapterRenderer)
          .filter(Boolean)
          .map((c: J) => ({ title: viewText(c.title) ?? '', start: Number(c.timeRangeStartMillis ?? 0) / 1000, thumbnail: thumbOf(c) }))
      )
      return
    }
    for (const v of Object.values(node)) visit(v)
  }
  visit(json)
  return found.sort((a, b) => b.length - a.length)[0] ?? []
}

/** The chapters list in the description panel ("In this video"). */
function panelChapters(json: J): Chapter[] {
  const out: Chapter[] = []
  for (const panel of json?.engagementPanels ?? []) {
    const p = panel?.engagementPanelSectionListRenderer
    const id = String(p?.targetId ?? p?.panelIdentifier ?? '')
    if (!/chapters/i.test(id) || /key-moments|auto/i.test(id)) continue
    const visit = (node: J): void => {
      if (Array.isArray(node)) return node.forEach(visit)
      if (!node || typeof node !== 'object') return
      const m = node.macroMarkersListItemRenderer
      if (m) {
        const start = clock(viewText(m.timeDescription) ?? '')
        if (start !== undefined) out.push({ title: viewText(m.title) ?? '', start, thumbnail: thumbOf(m) })
        return
      }
      for (const v of Object.values(node)) visit(v)
    }
    visit(p)
  }
  return out
}

/** Timestamps in the description ("0:00 Intro"), the way YouTube makes chapters from them. */
export function descriptionChapters(description: string): Chapter[] {
  const out: Chapter[] = []
  const stamp = /(?:^|[\s([])((?:\d{1,2}:)?\d{1,2}:\d{2})(?=$|[\s)\]:.,-])/
  for (const raw of description.split('\n')) {
    const line = raw.trim()
    const m = stamp.exec(line)
    if (!m) continue
    const start = clock(m[1])
    if (start === undefined) continue
    const title = (line.slice(0, m.index) + ' ' + line.slice(m.index + m[0].length))
      .replace(/^[\s\-–—:|•·.)\]]+|[\s\-–—:|•·.([]+$/g, '')
      .replace(/\s{2,}/g, ' ')
      .trim()
    out.push({ title: title || `Part ${out.length + 1}`, start })
  }
  // Like YouTube: starts at 0:00, at least three, in order.
  if (out.length < 3 || out[0].start !== 0) return []
  for (let i = 1; i < out.length; i++) if (out[i].start <= out[i - 1].start) return []
  return out
}

function descriptionOf(json: J): string {
  let best = ''
  const visit = (node: J): void => {
    if (Array.isArray(node)) return node.forEach(visit)
    if (!node || typeof node !== 'object') return
    const r = node.videoSecondaryInfoRenderer
    if (r) {
      const s = r.attributedDescription?.content ?? viewText(r.description) ?? ''
      if (s.length > best.length) best = s
      return
    }
    for (const v of Object.values(node)) visit(v)
  }
  visit(json)
  return best
}

const chapterCache = new Map<string, Chapter[]>()

/** An episode's chapters: from YouTube, or from the timestamps in its description. */
export async function chapters(id: string): Promise<Chapter[]> {
  const known = chapterCache.get(id)
  if (known) return known
  const json = await post('next', { videoId: id, contentCheckOk: true, racyCheckOk: true })
  let list = playerBarChapters(json)
  if (list.length < 2) list = panelChapters(json)
  if (list.length < 2) list = descriptionChapters(descriptionOf(json))
  list = list.filter((c, i) => i === 0 || c.start > list[i - 1].start).map((c, i) => ({ ...c, title: c.title || `Chapter ${i + 1}` }))
  chapterCache.set(id, list)
  return list
}
