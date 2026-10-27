// Regular YouTube search (not YouTube Music), used to find songs that aren't on YouTube Music.
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
