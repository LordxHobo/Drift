// The YouTube viewer: signing in to YouTube (Google's own page in a Drift window, kept in its own
// session on this computer only), and reading the signed-in account's feeds: new videos from
// subscriptions, history, Watch later, liked videos, subscribed channels, search and a video's details.
// Videos themselves play through the normal player (as episodes with their picture).
import { BrowserWindow, session } from 'electron'
import type { Session } from 'electron'
import { Innertube } from 'youtubei.js'
import type { YTAccount, YTChannel, YTFeedName, YTVideo, YTVideoDetails } from '@shared/types'
import { emit } from './store'

const PARTITION = 'persist:youtube'
/** Google refuses sign-in in windows that say they're an app; this is a normal browser's. */
const BROWSER_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36'

const ytSession = (): Session => session.fromPartition(PARTITION)

let tube: Promise<Innertube> | undefined
let tubeCookie = ''
let account: YTAccount | null | undefined

/** The account's cookies for youtube.com ('' when signed out). */
async function cookieHeader(): Promise<string> {
  const list = await ytSession().cookies.get({ url: 'https://www.youtube.com' })
  if (!list.some((c) => c.name === 'SAPISID' || c.name === '__Secure-3PAPISID')) return ''
  return list.map((c) => `${c.name}=${c.value}`).join('; ')
}

/** For playback (stream.ts): the account's cookies, '' when not signed in. */
export const playbackCookie = (): Promise<string> => cookieHeader()

async function signedInTube(): Promise<Innertube> {
  const cookie = await cookieHeader()
  if (!cookie) throw new Error('Sign in to YouTube first.')
  if (!tube || cookie !== tubeCookie) {
    tubeCookie = cookie
    tube = Innertube.create({ cookie, retrieve_player: false, user_agent: BROWSER_UA }).catch((e) => {
      tube = undefined
      throw e
    })
  }
  return tube
}

async function raw(endpoint: string, args: Record<string, unknown>): Promise<any> {
  const t = await signedInTube()
  const res = await t.actions.execute(endpoint, { ...args, parse: false })
  return res.data
}

// MARK: Signing in

/** Opens Google's sign-in page; resolves true once signed in to YouTube, false if the window was closed. */
export function signIn(parent?: BrowserWindow): Promise<boolean> {
  return new Promise((resolve) => {
    const win = new BrowserWindow({
      parent,
      modal: !!parent,
      width: 480,
      height: 720,
      title: 'Sign in to YouTube',
      autoHideMenuBar: true,
      webPreferences: { partition: PARTITION, contextIsolation: true, nodeIntegration: false, sandbox: true }
    })
    win.webContents.setUserAgent(BROWSER_UA)
    let done = false
    const finish = (ok: boolean): void => {
      if (done) return
      done = true
      account = undefined
      if (ok) emit('youtube')
      resolve(ok)
      if (!win.isDestroyed()) win.close()
    }
    const check = async (): Promise<void> => {
      const url = win.webContents.getURL()
      if (!/^https:\/\/(www|m)\.youtube\.com\//.test(url)) return
      if (await cookieHeader()) finish(true)
    }
    win.webContents.on('did-navigate', () => void check())
    win.webContents.on('did-navigate-in-page', () => void check())
    win.on('closed', () => {
      void cookieHeader().then((c) => finish(!!c))
    })
    void hidePasskeys(win).finally(() => {
      if (!win.isDestroyed()) void win.loadURL('https://accounts.google.com/ServiceLogin?service=youtube&continue=' + encodeURIComponent('https://www.youtube.com/'))
    })
  })
}

/**
 * Google's sign-in page asks for a passkey the moment it opens, and with no passkey screen of its own
 * this window would get Windows' "insert your security key" box. Hiding passkey support makes Google
 * go straight to email and password (2-step verification still works as usual).
 */
async function hidePasskeys(win: BrowserWindow): Promise<void> {
  const source = `(() => {
    try { Object.defineProperty(window, 'PublicKeyCredential', { value: undefined, configurable: true }) } catch (e) {}
    try {
      const refuse = () => Promise.reject(new DOMException('Not supported here', 'NotSupportedError'))
      if (navigator.credentials) {
        Object.defineProperty(navigator.credentials, 'get', { value: refuse, configurable: true })
        Object.defineProperty(navigator.credentials, 'create', { value: refuse, configurable: true })
      }
    } catch (e) {}
  })()`
  try {
    win.webContents.debugger.attach('1.3')
    await win.webContents.debugger.sendCommand('Page.enable')
    await win.webContents.debugger.sendCommand('Page.addScriptToEvaluateOnNewDocument', { source })
  } catch {
    // couldn't: Google may still ask for a passkey (cancel it, then "Try another way")
  }
}

export async function signOut(): Promise<void> {
  await ytSession().clearStorageData()
  tube = undefined
  tubeCookie = ''
  account = null
  emit('youtube')
}

/** Who's signed in (null when nobody). */
export async function ytAccount(): Promise<YTAccount | null> {
  if (!(await cookieHeader())) return (account = null)
  if (account) return account
  try {
    const data = await raw('/account/account_menu', {})
    const header = find(data, 'activeAccountHeaderRenderer')
    account = {
      name: text(header?.accountName) || 'YouTube',
      handle: text(header?.channelHandle) || '',
      avatar: lastThumb(header?.accountPhoto) || null
    }
  } catch {
    account = { name: 'YouTube', handle: '', avatar: null }
  }
  return account
}

// MARK: Reading YouTube's answers

/** The first object under `key` anywhere in `node`. */
function find(node: any, key: string): any {
  if (!node || typeof node !== 'object') return undefined
  if (key in node) return node[key]
  for (const v of Object.values(node)) {
    const f = find(v, key)
    if (f !== undefined) return f
  }
  return undefined
}

function text(t: any): string {
  if (!t) return ''
  if (typeof t === 'string') return t
  if (typeof t.simpleText === 'string') return t.simpleText
  if (typeof t.content === 'string') return t.content
  if (Array.isArray(t.runs)) return t.runs.map((r: any) => r.text ?? '').join('')
  return ''
}

function lastThumb(t: any): string | undefined {
  const list = t?.thumbnails ?? t?.sources ?? t?.image?.sources
  if (!Array.isArray(list) || !list.length) return undefined
  const url: string = list[list.length - 1].url
  return url?.startsWith('//') ? `https:${url}` : url
}

/** "12:34" or "1:02:03" → seconds. */
function seconds(s: string): number | undefined {
  if (!/^\d+(:\d+)+$/.test(s.trim())) return undefined
  return s.trim().split(':').reduce((a, p) => a * 60 + Number(p), 0)
}

function browseIdOf(node: any): string | undefined {
  return find(node, 'browseEndpoint')?.browseId
}

/** One video from any of the shapes YouTube uses (older renderers and the newer "lockup" view models). */
function videoFrom(key: string, v: any): YTVideo | null {
  if (key === 'lockupViewModel') {
    if (v.contentType && v.contentType !== 'LOCKUP_CONTENT_TYPE_VIDEO') return null
    const id: string = v.contentId
    const meta = v.metadata?.lockupMetadataViewModel
    if (!id || !meta) return null
    const rows: any[] = meta.metadata?.contentMetadataViewModel?.metadataRows ?? []
    const parts = rows.map((r) => (r.metadataParts ?? []).map((p: any) => text(p.text)).filter(Boolean))
    const badges: string[] = []
    for (const o of (find(v.contentImage, 'overlays') ?? []) as any[]) {
      for (const b of find(o, 'thumbnailBadges') ?? []) badges.push(text(b?.thumbnailBadgeViewModel?.text))
    }
    const len = badges.find((b) => seconds(b) !== undefined)
    const live = badges.some((b) => /live/i.test(b))
    return {
      id,
      title: text(meta.title),
      channel: parts[0]?.[0] ?? '',
      channelId: browseIdOf(meta.image) ?? browseIdOf(rows[0]) ?? null,
      thumbnail: lastThumb(find(v.contentImage, 'image')) ?? `https://i.ytimg.com/vi/${id}/hqdefault.jpg`,
      duration: len ? seconds(len) ?? null : null,
      views: parts[1]?.[0] ?? '',
      published: parts[1]?.[1] ?? '',
      live
    }
  }
  const id: string = v.videoId
  if (!id) return null
  const owner = v.ownerText ?? v.shortBylineText ?? v.longBylineText
  const lenText = text(v.lengthText) || text(find(v.thumbnailOverlays, 'thumbnailOverlayTimeStatusRenderer')?.text)
  const live = !!find(v.badges, 'label')?.toString().match(/live/i) || /live/i.test(find(v.thumbnailOverlays, 'style') ?? '')
  return {
    id,
    title: text(v.title) || text(v.headline),
    channel: text(owner),
    channelId: browseIdOf(owner) ?? null,
    thumbnail: lastThumb(v.thumbnail) ?? `https://i.ytimg.com/vi/${id}/hqdefault.jpg`,
    duration: seconds(lenText) ?? null,
    views: text(v.shortViewCountText) || text(v.viewCountText),
    published: text(v.publishedTimeText),
    live
  }
}

const videoKeys = new Set(['videoRenderer', 'gridVideoRenderer', 'compactVideoRenderer', 'playlistVideoRenderer', 'lockupViewModel'])

/** Every video in an answer, in order, once each (Shorts left out). */
function videos(node: any, out: YTVideo[] = [], seen = new Set<string>()): YTVideo[] {
  if (!node || typeof node !== 'object') return out
  if (Array.isArray(node)) {
    for (const n of node) videos(n, out, seen)
    return out
  }
  for (const [k, v] of Object.entries(node)) {
    if (k === 'reelShelfRenderer' || k === 'shortsLockupViewModel' || k === 'reelItemRenderer') continue
    if (videoKeys.has(k) && v && typeof v === 'object') {
      const video = videoFrom(k, v)
      if (video && video.title && !seen.has(video.id)) {
        seen.add(video.id)
        out.push(video)
      }
      continue
    }
    videos(v, out, seen)
  }
  return out
}

// MARK: Feeds

export async function ytFeed(feed: YTFeedName): Promise<YTVideo[]> {
  const browseId = { subscriptions: 'FEsubscriptions', history: 'FEhistory', watchLater: 'VLWL', liked: 'VLLL' }[feed]
  return videos(await raw('/browse', { browseId }))
}

/** The channels the account is subscribed to (from YouTube's side menu), with "new videos" marks. */
export async function ytChannels(): Promise<YTChannel[]> {
  const data = await raw('/guide', {})
  const out: YTChannel[] = []
  const walk = (n: any): void => {
    if (!n || typeof n !== 'object') return
    if (Array.isArray(n)) return n.forEach(walk)
    const e = n.guideEntryRenderer
    const id: string | undefined = e?.navigationEndpoint?.browseEndpoint?.browseId
    if (e && id?.startsWith('UC') && !out.some((c) => c.id === id)) {
      out.push({ id, name: text(e.formattedTitle), avatar: lastThumb(e.thumbnail) ?? null, fresh: e.presentationStyle === 'GUIDE_ENTRY_PRESENTATION_STYLE_NEW_CONTENT' })
      return
    }
    Object.values(n).forEach(walk)
  }
  walk(find(data, 'guideSubscriptionsSectionRenderer') ?? {})
  return out
}

export async function ytSearch(query: string): Promise<YTVideo[]> {
  // "EgIQAQ==": videos only.
  return videos(await raw('/search', { query, params: 'EgIQAQ%3D%3D' }))
}

export async function ytChannelVideos(id: string): Promise<{ channel: YTChannel; videos: YTVideo[] }> {
  // "EgZ2aWRlb3PyBgQKAjoA": the channel's Videos tab.
  const data = await raw('/browse', { browseId: id, params: 'EgZ2aWRlb3PyBgQKAjoA' })
  const header = find(data, 'pageHeaderViewModel') ?? find(data, 'c4TabbedHeaderRenderer')
  const meta = find(data, 'channelMetadataRenderer')
  const list = videos(data).map((v) => ({ ...v, channel: v.channel || meta?.title || '', channelId: v.channelId ?? id }))
  return {
    channel: {
      id,
      name: meta?.title || text(header?.title) || '',
      avatar: lastThumb(meta?.avatar) ?? lastThumb(find(header, 'avatar')) ?? null,
      fresh: false
    },
    videos: list
  }
}

export async function ytVideo(id: string): Promise<YTVideoDetails> {
  const data = await raw('/next', { videoId: id })
  const primary = find(data, 'videoPrimaryInfoRenderer')
  const secondary = find(data, 'videoSecondaryInfoRenderer')
  const owner = find(secondary, 'videoOwnerRenderer')
  const subscribe = find(secondary, 'subscribeButtonRenderer')
  const related = videos(find(data, 'secondaryResults') ?? {}).filter((v) => v.id !== id && !v.live)
  return {
    id,
    title: text(primary?.title),
    views: text(find(primary?.viewCount, 'viewCount')) || text(find(primary, 'shortViewCount')),
    published: text(primary?.relativeDateText) || text(primary?.dateText),
    description: text(secondary?.attributedDescription) || text(secondary?.description),
    channel: {
      id: owner?.navigationEndpoint?.browseEndpoint?.browseId ?? '',
      name: text(owner?.title),
      avatar: lastThumb(owner?.thumbnail) ?? null,
      fresh: false
    },
    subscribers: text(owner?.subscriberCountText),
    subscribed: subscribe?.subscribed === true,
    related
  }
}

// MARK: Doing things

export async function ytSubscribe(channelId: string, on: boolean): Promise<void> {
  const t = await signedInTube()
  await (on ? t.interact.subscribe(channelId) : t.interact.unsubscribe(channelId))
}

export async function ytLike(videoId: string): Promise<void> {
  const t = await signedInTube()
  await t.interact.like(videoId)
}

export async function ytWatchLater(videoId: string): Promise<void> {
  const t = await signedInTube()
  await t.playlist.addVideos('WL', [videoId])
}
