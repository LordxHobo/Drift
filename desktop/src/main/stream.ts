// Finding a playable audio link for a song, and passing the audio to the window (drift://stream/<id>).
import { app, net } from 'electron'
import { join } from 'node:path'
import { readFileSync, writeFileSync } from 'node:fs'
import vm from 'node:vm'
import { Innertube, Platform, UniversalCache } from 'youtubei.js'
import type { Types } from 'youtubei.js'
import type { StreamInfo, Track } from '@shared/types'
import { albumVersion } from './ytmusic'
import { getSettings } from './store'

// YouTube scrambles part of each audio link; the code that unscrambles it comes from YouTube's own
// player. It runs in a separate context with only a few web basics (no require, process or files).
// youtubei.js adds the call itself (it ends with "return process(…)"), so the code runs as a function body.
Platform.shim.eval = (data) => {
  const context = { URL, URLSearchParams, TextEncoder, TextDecoder, atob, btoa }
  return vm.runInNewContext(`(function () {\n${data.output}\n})()`, context, { timeout: 5000 })
}

let yt: Promise<Innertube> | undefined

function innertube(): Promise<Innertube> {
  yt ??= Innertube.create({
    retrieve_player: true,
    generate_session_locally: true,
    cache: new UniversalCache(true, join(app.getPath('userData'), 'youtube-cache'))
  }).catch((e) => {
    yt = undefined
    throw e
  })
  return yt
}

interface Resolved {
  url: string
  mime: string
  bitrate: number
  size?: number
  duration?: number
  client: string
  expires: number
}

/** Clients tried in order (the same quick path the phone uses comes first). */
const clients: Types.InnerTubeClient[] = ['VISIONOS', 'TV', 'WEB_EMBEDDED', 'ANDROID_VR']

const resolved = new Map<string, Resolved>()
const resolving = new Map<string, Promise<Resolved>>()

async function resolveFresh(id: string): Promise<Resolved> {
  const tube = await innertube()
  let lastError = 'YouTube didn’t offer audio for this song'
  for (const client of clients) {
    try {
      const info = await tube.getBasicInfo(id, { client })
      const status = info.playability_status?.status
      if (status && status !== 'OK') {
        lastError = info.playability_status?.reason || `Not playable (${status})`
        continue
      }
      const audio = (info.streaming_data?.adaptive_formats ?? [])
        .filter((f) => f.has_audio && !f.has_video)
        .sort((a, b) => (b.bitrate ?? 0) - (a.bitrate ?? 0))
      const format = audio[0]
      if (!format) continue
      const url = await format.decipher(tube.session.player)
      if (!url) continue
      const expire = Number(new URL(url).searchParams.get('expire') ?? 0) * 1000
      return {
        url,
        mime: format.mime_type.split(';')[0] || 'audio/mp4',
        bitrate: format.bitrate,
        size: format.content_length || undefined,
        duration: format.approx_duration_ms ? format.approx_duration_ms / 1000 : undefined,
        client,
        expires: Math.min(expire || Infinity, Date.now() + 5 * 3600_000) - 60_000
      }
    } catch (e) {
      lastError = e instanceof Error ? e.message : String(e)
    }
  }
  throw new Error(lastError)
}

export async function resolve(id: string, force = false): Promise<Resolved> {
  const known = resolved.get(id)
  if (!force && known && known.expires > Date.now()) return known
  let task = resolving.get(id)
  if (!task) {
    task = resolveFresh(id).finally(() => resolving.delete(id))
    resolving.set(id, task)
  }
  const r = await task
  resolved.set(id, r)
  return r
}

// MARK: Album versions (remembered on this computer)

const versionFile = (): string => join(app.getPath('userData'), 'album-versions.json')
let versions: Record<string, string> | undefined
const notes = new Map<string, string>()

function loadVersions(): Record<string, string> {
  if (!versions) {
    try {
      versions = JSON.parse(readFileSync(versionFile(), 'utf8'))
    } catch {
      versions = {}
    }
  }
  return versions!
}

async function preferredId(track: Track): Promise<string> {
  const id = track.id
  if (track.upload) {
    notes.set(id, 'YouTube upload (not on YouTube Music)')
    return id
  }
  if (!getSettings().preferOfficialAudio || track.podcast) {
    notes.set(id, 'Off (Prefer album versions is off)')
    return id
  }
  const map = loadVersions()
  if (id in map) {
    if (!notes.has(id)) notes.set(id, map[id] ? 'Remembered: album version' : 'Remembered: keep this video')
    return map[id] || id
  }
  try {
    const [play, note] = await Promise.race([
      albumVersion(track),
      new Promise<never>((_, reject) => setTimeout(() => reject(new Error('timeout')), 4000))
    ])
    notes.set(id, note)
    map[id] = play === id ? '' : play
    if (Object.keys(map).length > 5000) versions = {}
    writeFileSync(versionFile(), JSON.stringify(versions))
    return play
  } catch {
    notes.set(id, 'Lookup failed or timed out')
    return id
  }
}

/** Gets a song ready to play and says what will actually play. */
export async function prepare(track: Track): Promise<StreamInfo> {
  const playId = await preferredId(track)
  const r = await resolve(playId)
  return {
    playId,
    mime: r.mime,
    bitrate: r.bitrate,
    size: r.size,
    duration: r.duration,
    client: r.client,
    note: notes.get(track.id) ?? ''
  }
}

// MARK: drift://stream/<id>

/** YouTube sends audio at full speed only in pieces this size, so longer reads are split up. */
const chunk = 4 * 1024 * 1024

function parseRange(h: string | null): [number, number | undefined] {
  const m = h && /bytes=(\d*)-(\d*)/.exec(h)
  if (!m) return [0, undefined]
  return [Number(m[1] || 0), m[2] ? Number(m[2]) : undefined]
}

async function fetchPiece(id: string, start: number, end: number): Promise<Response> {
  for (let attempt = 0; attempt < 2; attempt++) {
    const r = await resolve(id, attempt > 0)
    const res = await net.fetch(r.url, { headers: { Range: `bytes=${start}-${end}` } }).catch(() => undefined)
    if (res && (res.status === 206 || res.status === 200)) return res
    // The link expired or was refused: get a fresh one and try once more.
    resolved.delete(id)
  }
  throw new Error('YouTube refused the audio')
}

export async function handleStream(request: Request): Promise<Response> {
  const id = new URL(request.url).pathname.replace(/^\/+/, '')
  if (process.env.DRIFT_DEBUG) console.log('[stream]', id, request.headers.get('range'))
  if (!/^[\w-]{6,20}$/.test(id)) return new Response('Bad song', { status: 400 })
  const [start, askedEnd] = parseRange(request.headers.get('range'))

  let r: Resolved
  try {
    r = await resolve(id)
  } catch (e) {
    return new Response(e instanceof Error ? e.message : 'Unavailable', { status: 502 })
  }
  const headers = new Headers({
    'Access-Control-Allow-Origin': '*',
    'Content-Type': r.mime,
    'Accept-Ranges': 'bytes',
    'Cache-Control': 'no-store'
  })

  // Size unknown: pass YouTube's answer through as it is.
  if (!r.size) {
    try {
      const res = await fetchPiece(id, start, askedEnd ?? start + chunk - 1)
      for (const h of ['content-length', 'content-range']) {
        const v = res.headers.get(h)
        if (v) headers.set(h, v)
      }
      return new Response(res.body, { status: res.status, headers })
    } catch (e) {
      return new Response(e instanceof Error ? e.message : 'Unavailable', { status: 502 })
    }
  }

  const size = r.size
  if (start >= size) return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${size}` } })
  const last = Math.min(askedEnd ?? size - 1, size - 1)

  // The first piece is fetched before answering, so a refusal still shows up as an error.
  let first: Response
  try {
    first = await fetchPiece(id, start, Math.min(start + chunk - 1, last))
  } catch (e) {
    return new Response(e instanceof Error ? e.message : 'Unavailable', { status: 502 })
  }

  let position = start
  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined = first.body?.getReader()
  let cancelled = false
  const body = new ReadableStream<Uint8Array>({
    async pull(controller) {
      try {
        while (!cancelled) {
          if (!reader) {
            if (position > last) {
              controller.close()
              return
            }
            const piece = await fetchPiece(id, position, Math.min(position + chunk - 1, last))
            reader = piece.body?.getReader()
            if (!reader) throw new Error('No audio')
          }
          const { done, value } = await reader.read()
          if (done) {
            reader = undefined
            continue
          }
          position += value.byteLength
          controller.enqueue(value)
          return
        }
      } catch (e) {
        controller.error(e)
      }
    },
    cancel() {
      cancelled = true
      void reader?.cancel().catch(() => undefined)
    }
  })

  headers.set('Content-Length', String(last - start + 1))
  headers.set('Content-Range', `bytes ${start}-${last}/${size}`)
  return new Response(body, { status: 206, headers })
}
