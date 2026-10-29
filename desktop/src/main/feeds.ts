// Podcasts from their own feeds (RSS), like Apple Podcasts and Spotify have them: shows found in
// Apple's podcast directory, or any feed link pasted in. Episodes are plain audio files.
// The same ids as on the phone (rss-…, from the feed link and each episode's guid).
import { app, net } from 'electron'
import type { PodcastChannel, Track } from '@shared/types'
import { feedId, parseFeed } from '@shared/feedParse'

const UA = 'Drift/1.0 (podcast app)'

/** Shows in Apple's podcast directory (this country's, then the US one if that finds nothing). */
export async function searchShows(term: string): Promise<PodcastChannel[]> {
  const here = (app.getLocaleCountryCode() || 'US').toUpperCase()
  const found = await searchIn(term, here)
  return found.length || here === 'US' ? found : searchIn(term, 'US')
}

async function searchIn(term: string, country: string): Promise<PodcastChannel[]> {
  const url = new URL('https://itunes.apple.com/search')
  url.searchParams.set('media', 'podcast')
  url.searchParams.set('entity', 'podcast')
  url.searchParams.set('limit', '20')
  url.searchParams.set('country', country)
  url.searchParams.set('term', term)
  const res = await net.fetch(url.toString())
  if (!res.ok) throw new Error('Podcast search failed')
  const body = (await res.json()) as { results?: Record<string, unknown>[] }
  const out: PodcastChannel[] = []
  for (const r of body.results ?? []) {
    const feed = typeof r.feedUrl === 'string' ? r.feedUrl : ''
    if (!feed || out.some((c) => c.feedURL === feed)) continue
    const count = typeof r.trackCount === 'number' ? r.trackCount : 0
    const author = typeof r.artistName === 'string' ? r.artistName : ''
    out.push({
      id: feedId(feed),
      name: String(r.collectionName ?? r.trackName ?? 'Podcast'),
      avatarURL: (r.artworkUrl600 ?? r.artworkUrl100 ?? null) as string | null,
      subtitle: [author, count ? `${count} episodes` : ''].filter(Boolean).join(' · ') || null,
      feedURL: feed
    })
  }
  return out
}

async function fetchFeed(feedURL: string): Promise<string> {
  const res = await net.fetch(feedURL, { headers: { 'User-Agent': UA, Accept: 'application/rss+xml, application/xml, text/xml, */*' } })
  if (!res.ok) throw new Error(`The feed answered ${res.status}`)
  return res.text()
}

/** Where a pasted link's feed is: a feed link, a show's Apple Podcasts page, or a SoundCloud profile. */
async function feedFor(url: URL): Promise<string | undefined> {
  const host = url.hostname.toLowerCase()
  if (host.endsWith('podcasts.apple.com') || host.endsWith('itunes.apple.com')) {
    // …/podcast/desnorte/id1517400422 → Apple's directory knows its feed.
    const id = /id(\d+)/.exec(url.pathname)?.[1]
    if (!id) return undefined
    const res = await net.fetch(`https://itunes.apple.com/lookup?id=${id}&entity=podcast`)
    const body = (await res.json()) as { results?: { feedUrl?: string }[] }
    return body.results?.[0]?.feedUrl || undefined
  }
  if (host.endsWith('soundcloud.com') && !host.startsWith('feeds.')) {
    // The profile page names its account number, which SoundCloud's podcast feed link is made from.
    const page = await fetchFeed(url.toString())
    const n = /soundcloud(?::\/\/|:)users:(\d+)/.exec(page)?.[1]
    return n ? `https://feeds.soundcloud.com/users/soundcloud:users:${n}/sounds.rss` : undefined
  }
  return url.toString()
}

/** A show from a pasted link. */
export async function showFromLink(link: string): Promise<{ channel: PodcastChannel; episodes: Track[] } | undefined> {
  let url: URL
  try {
    url = new URL(link.trim())
  } catch {
    return undefined
  }
  if (!/^https?:$/.test(url.protocol)) return undefined
  const feed = await feedFor(url)
  if (!feed) return undefined
  const parsed = parseFeed(await fetchFeed(feed), { id: feedId(feed), name: '', feedURL: feed })
  if (!parsed.title && !parsed.episodes.length) return undefined
  return { channel: parsed.channel, episodes: parsed.episodes }
}

/** A followed show's episodes, newest first. */
export async function feedEpisodes(c: PodcastChannel): Promise<Track[]> {
  if (!c.feedURL) return []
  return parseFeed(await fetchFeed(c.feedURL), c).episodes
}
