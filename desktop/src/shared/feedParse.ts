// Reading a podcast feed (RSS 2.0 with Apple's itunes: tags, as every podcast host makes them).
// Kept free of Electron so it can be tested on its own. The phone does the same in PodcastFeeds.swift;
// both must give the same ids.
import type { PodcastChannel, Track } from './types'

/** 64-bit FNV-1a of the text (UTF-8), as 16 hex digits. */
export function fnv64(s: string): string {
  let h = 0xcbf29ce484222325n
  for (const b of new TextEncoder().encode(s)) {
    h ^= BigInt(b)
    h = (h * 0x100000001b3n) & 0xffffffffffffffffn
  }
  return h.toString(16).padStart(16, '0')
}

/** A show's or episode's id: "rss-" and 14 hex digits (fits where YouTube ids go). */
export const feedId = (key: string): string => 'rss-' + fnv64(key).slice(0, 14)

/** Seconds between 1970 and 2001 (Track dates count from 2001, like the phone's). */
const since2001 = 978_307_200

const entities: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' }

export function decodeText(s: string): string {
  const cdata = /^\s*<!\[CDATA\[([\s\S]*?)\]\]>\s*$/.exec(s)
  if (cdata) return cdata[1].trim()
  return s
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1')
    .replace(/&(#x[0-9a-f]+|#\d+|\w+);/gi, (m, e: string) => {
      if (e[0] === '#') {
        const n = e[1] === 'x' || e[1] === 'X' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10)
        return Number.isFinite(n) && n > 0 ? String.fromCodePoint(n) : m
      }
      return entities[e.toLowerCase()] ?? m
    })
    .trim()
}

const esc = (tag: string): string => tag.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

/** The text inside the first <tag>…</tag>. */
function tagText(xml: string, tag: string): string | undefined {
  const m = new RegExp(`<${esc(tag)}(?:\\s[^>]*)?>([\\s\\S]*?)</${esc(tag)}>`, 'i').exec(xml)
  return m ? decodeText(m[1]) : undefined
}

/** An attribute of the first <tag …>. */
function tagAttr(xml: string, tag: string, attr: string): string | undefined {
  const re = new RegExp(`<${esc(tag)}\\s[^>]*>`, 'gi')
  for (const m of xml.matchAll(re)) {
    const a = new RegExp(`\\s${esc(attr)}\\s*=\\s*("([^"]*)"|'([^']*)')`, 'i').exec(m[0])
    if (a) return decodeText(a[2] ?? a[3] ?? '')
  }
  return undefined
}

/** "1:02:03", "62:03", "3723" or "3723.5" → seconds. */
export function parseDuration(s: string | undefined): number | undefined {
  if (!s) return undefined
  const parts = s.trim().split(':').map(Number)
  if (!parts.length || parts.some((n) => !Number.isFinite(n))) return undefined
  const secs = parts.reduce((acc, n) => acc * 60 + n, 0)
  return secs > 0 ? Math.round(secs) : undefined
}

/** RFC 822 date ("Tue, 27 Oct 2026 21:00:00 GMT") → seconds since 2001. */
function parseDate(s: string | undefined): number | undefined {
  if (!s) return undefined
  const ms = Date.parse(s.trim().replace(/\s+/g, ' '))
  return Number.isFinite(ms) ? ms / 1000 - since2001 : undefined
}

const httpsImage = (u: string | undefined): string | null => (u ? u.trim().replace(/^http:\/\//i, 'https://') : null)

export interface ParsedFeed {
  title: string
  channel: PodcastChannel
  episodes: Track[]
}

/** Shows can have many hundreds of episodes; the newest this many are kept. */
export const maxEpisodes = 500

export function parseFeed(xml: string, c: PodcastChannel): ParsedFeed {
  const firstItem = xml.search(/<item[\s>]/i)
  const head = firstItem >= 0 ? xml.slice(0, firstItem) : xml
  // <image> has its own <title>, so it's set aside before reading the show's.
  const imageBlock = /<image[\s>][\s\S]*?<\/image>/i.exec(head)?.[0]
  const title = tagText(imageBlock ? head.replace(imageBlock, '') : head, 'title') ?? ''
  const image = httpsImage(tagAttr(head, 'itunes:image', 'href') ?? (imageBlock ? tagText(imageBlock, 'url') : undefined))
  const author = tagText(head, 'itunes:author')
  const channel: PodcastChannel = {
    id: c.id,
    name: c.name || title || 'Podcast',
    avatarURL: c.avatarURL || image,
    subtitle: c.subtitle ?? (author || null),
    feedURL: c.feedURL
  }

  const episodes: Track[] = []
  const seen = new Set<string>()
  for (const m of xml.matchAll(/<item[\s>][\s\S]*?<\/item>/gi)) {
    const item = m[0]
    const audio = tagAttr(item, 'enclosure', 'url') ?? tagAttr(item, 'media:content', 'url')
    if (!audio) continue
    const guid = tagText(item, 'guid') || audio
    const id = feedId(`${c.id}|${guid}`)
    if (seen.has(id)) continue
    seen.add(id)
    const t: Track = {
      id,
      title: tagText(item, 'title') || tagText(item, 'itunes:title') || 'Episode',
      artist: channel.name,
      artworkURL: httpsImage(tagAttr(item, 'itunes:image', 'href')) ?? channel.avatarURL ?? null,
      duration: parseDuration(tagText(item, 'itunes:duration')) ?? null,
      podcast: true,
      channelID: c.id,
      channelAvatar: channel.avatarURL ?? null,
      published: parseDate(tagText(item, 'pubDate')) ?? null,
      audioURL: audio.trim(),
      feedURL: c.feedURL ?? null
    }
    episodes.push(t)
  }
  // Newest first (most feeds already are, a few list oldest first).
  episodes.sort((a, b) => (b.published ?? -Infinity) - (a.published ?? -Infinity))
  return { title, channel, episodes: episodes.slice(0, maxEpisodes) }
}
