// Finding a playable audio link for a song, and passing the audio to the window (drift://stream/<id>).
import { app, net } from 'electron'
import { join } from 'node:path'
import { createReadStream, existsSync, openSync, closeSync, readFileSync, statSync, writeSync, writeFileSync } from 'node:fs'
import { Readable } from 'node:stream'
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

// MARK: YouTube visitor ID

// YouTube treats requests without a real visitor ID as likely bots ("Sign in to confirm you're not a
// bot"). Like the phone, Drift gets one from YouTube itself once and keeps reusing it.
const visitorFile = (): string => join(app.getPath('userData'), 'visitor.json')
let visitorData: string | undefined
let visitorLoaded = false
let warmUpTask: Promise<void> | undefined

function loadVisitor(): void {
  if (visitorLoaded) return
  visitorLoaded = true
  try {
    visitorData = JSON.parse(readFileSync(visitorFile(), 'utf8')).visitorData || undefined
  } catch {
    visitorData = undefined
  }
}

function setVisitor(v: string | undefined): void {
  if (!v || v === visitorData) return
  visitorData = v
  try {
    writeFileSync(visitorFile(), JSON.stringify({ visitorData: v }))
  } catch {
    // kept in memory only
  }
}

/** Gets a visitor ID before the first song (any public video works; this is YouTube's first upload). */
function warmUp(): Promise<void> {
  loadVisitor()
  if (visitorData) return Promise.resolve()
  warmUpTask ??= quickResolve('jNQXAC9IVRw')
    .then(() => undefined)
    .catch(() => undefined)
    .finally(() => (warmUpTask = undefined))
  return warmUpTask
}

// MARK: Quick path (the same request the phone makes)

const visionOS = {
  ua: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15',
  clientNumber: '101',
  version: '1.02'
}

class NotPlayable extends Error {}

/**
 * YouTube's visionOS app gets direct audio links in one request, without the web page or the
 * unscrambling step. This is the phone's quick path, unchanged.
 */
async function quickResolve(id: string): Promise<Resolved> {
  loadVisitor()
  const client: Record<string, unknown> = {
    clientName: 'VISIONOS',
    clientVersion: visionOS.version,
    deviceMake: 'Apple',
    deviceModel: 'RealityDevice17,1',
    osName: 'visionOS',
    osVersion: '26.5.23O471',
    userAgent: visionOS.ua,
    hl: 'en',
    gl: 'US'
  }
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    'User-Agent': visionOS.ua,
    'X-YouTube-Client-Name': visionOS.clientNumber,
    'X-YouTube-Client-Version': visionOS.version,
    Origin: 'https://www.youtube.com'
  }
  if (visitorData) {
    headers['X-Goog-Visitor-Id'] = visitorData
    client.visitorData = visitorData
  }
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 6000)
  let json: any
  try {
    const res = await fetch('https://www.youtube.com/youtubei/v1/player?prettyPrint=false', {
      method: 'POST',
      headers,
      body: JSON.stringify({ context: { client }, videoId: id, contentCheckOk: true, racyCheckOk: true }),
      signal: controller.signal
    })
    if (res.status !== 200) throw new Error(`YouTube answered ${res.status}`)
    json = await res.json()
  } finally {
    clearTimeout(timer)
  }
  setVisitor(json?.responseContext?.visitorData)

  const status = json?.playabilityStatus?.status
  if (status !== 'OK' || json?.videoDetails?.videoId !== id) {
    throw new NotPlayable(json?.playabilityStatus?.reason || `Not playable (${status ?? 'no answer'})`)
  }
  const formats: any[] = json?.streamingData?.adaptiveFormats ?? []
  const rate = (f: any): number => Number(f.averageBitrate ?? f.bitrate ?? 0)
  // Direct-link audio in the original language (no dubbed tracks); AAC first, like the phone.
  const audio = formats.filter(
    (f) => typeof f.url === 'string' && String(f.mimeType ?? '').startsWith('audio/') && f.audioTrack?.audioIsDefault !== false
  )
  const aac = audio.filter((f) => String(f.mimeType).startsWith('audio/mp4'))
  const pick = (aac.length ? aac : audio).sort((a, b) => rate(b) - rate(a))[0]
  if (!pick) throw new NotPlayable('YouTube didn’t offer audio for this song')
  const expire = Number(new URL(pick.url).searchParams.get('expire') ?? 0) * 1000
  const seconds = Number(json?.videoDetails?.lengthSeconds) || undefined
  return {
    url: pick.url,
    mime: String(pick.mimeType).split(';')[0],
    bitrate: rate(pick),
    size: Number(pick.contentLength) || undefined,
    duration: pick.approxDurationMs ? Number(pick.approxDurationMs) / 1000 : seconds,
    client: 'VISIONOS (quick)',
    expires: Math.min(expire || Infinity, Date.now() + 3 * 3600_000) - 60_000
  }
}

// MARK: Full extraction (fallback)

let yt: Promise<Innertube> | undefined

function innertube(): Promise<Innertube> {
  // A real visitor ID from YouTube (not one made up locally, which YouTube flags as a bot).
  yt ??= Innertube.create({
    retrieve_player: true,
    visitor_data: visitorData,
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

/** Fallback clients, tried in order after the quick path. */
const clients: Types.InnerTubeClient[] = ['TV', 'WEB_EMBEDDED', 'ANDROID_VR']

const resolved = new Map<string, Resolved>()
const resolving = new Map<string, Promise<Resolved>>()

function friendly(message: string): string {
  if (/not a bot|sign in to confirm/i.test(message)) {
    return 'YouTube asked to confirm this isn’t a bot. Wait a minute and try again.'
  }
  return message
}

async function resolveFresh(id: string): Promise<Resolved> {
  await warmUp()
  let firstError: string | undefined
  try {
    return await quickResolve(id)
  } catch (e) {
    firstError = e instanceof Error ? e.message : String(e)
    // Some songs really aren't playable; the other clients would say the same thing.
    if (e instanceof NotPlayable && /unavailable|private|removed|terminated|age/i.test(firstError)) throw new Error(firstError)
  }

  const tube = await innertube().catch(() => undefined)
  if (!tube) throw new Error(friendly(firstError))
  for (const client of clients) {
    try {
      const info = await tube.getBasicInfo(id, { client })
      const status = info.playability_status?.status
      if (status && status !== 'OK') continue
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
        expires: Math.min(expire || Infinity, Date.now() + 3 * 3600_000) - 60_000
      }
    } catch {
      // try the next one
    }
  }
  throw new Error(friendly(firstError))
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
// MARK: Downloaded songs

export interface LocalAudio {
  path: string
  mime: string
  size: number
}

/** Set by the downloads module: the file of a downloaded song, if there is one. */
let localLookup: (id: string) => LocalAudio | undefined = () => undefined

export function setLocalLookup(f: (id: string) => LocalAudio | undefined): void {
  localLookup = f
}

/**
 * Saves a song's audio to `path` (via `path`.part, so an interrupted download carries on where it
 * stopped). Returns what was saved.
 */
export async function downloadAudio(
  track: Track,
  path: string,
  onProgress: (received: number, total: number) => void,
  cancelled: () => boolean
): Promise<{ mime: string; size: number; playId: string }> {
  const playId = await preferredId(track)
  const r = await resolve(playId)
  const part = path + '.part'
  let position = existsSync(part) ? statSync(part).size : 0
  const total = r.size ?? 0
  if (total && position > total) position = 0
  const fd = openSync(part, position > 0 ? 'a' : 'w')
  try {
    while (!cancelled()) {
      if (total && position >= total) break
      const end = total ? Math.min(position + chunk - 1, total - 1) : position + chunk - 1
      const res = await fetchPiece(playId, position, end)
      if (!res.body) throw new Error('No audio')
      const reader = res.body.getReader()
      let got = 0
      for (;;) {
        const { done, value } = await reader.read()
        if (done) break
        writeSync(fd, value)
        got += value.byteLength
        position += value.byteLength
        onProgress(position, total)
        if (cancelled()) {
          await reader.cancel().catch(() => undefined)
          break
        }
      }
      // Size unknown: a short piece means the end of the file.
      if (!total && got < chunk) break
      if (got === 0) throw new Error('The download stopped')
    }
  } finally {
    closeSync(fd)
  }
  if (cancelled()) throw new Error('cancelled')
  return { mime: r.mime, size: position, playId }
}

function serveFile(local: LocalAudio, rangeHeader: string | null): Response {
  const [start, askedEnd] = parseRange(rangeHeader)
  if (start >= local.size) return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${local.size}` } })
  const end = Math.min(askedEnd ?? local.size - 1, local.size - 1)
  const body = Readable.toWeb(createReadStream(local.path, { start, end })) as ReadableStream<Uint8Array>
  return new Response(body, {
    status: 206,
    headers: {
      'Access-Control-Allow-Origin': '*',
      'Content-Type': local.mime,
      'Accept-Ranges': 'bytes',
      'Content-Length': String(end - start + 1),
      'Content-Range': `bytes ${start}-${end}/${local.size}`
    }
  })
}

export async function prepare(track: Track): Promise<StreamInfo> {
  // Downloaded: plays from the computer, no internet needed.
  const local = localLookup(track.id)
  if (local) {
    return { playId: track.id, mime: local.mime, bitrate: track.duration ? Math.round((local.size * 8) / track.duration) : 0, size: local.size, duration: track.duration ?? undefined, client: 'Downloaded', note: 'Downloaded on this computer' }
  }
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
  const local = localLookup(id)
  if (local) return serveFile(local, request.headers.get('range'))
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
