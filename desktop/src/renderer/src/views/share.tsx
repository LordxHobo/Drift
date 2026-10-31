// Share a song: copy its link, or a picture of it (cover, title and artist) to paste into a chat or save.
import { useEffect, useState } from 'react'
import type { JSX } from 'react'
import type { Track } from '@shared/types'
import { Store, toast, useStore } from '../state'
import { Icon } from '../icons'
import { Spinner } from '../ui'
import { artwork, ytLink } from '../util'

export const shareStore = new Store<Track | null>(null)

export function openShare(t: Track): void {
  shareStore.set(t)
}

/** Where anyone can open the song (YouTube Music, YouTube, or the episode's file). */
export function shareLink(t: Track): string {
  if (t.audioURL) return t.audioURL
  if (t.podcast) return `https://www.youtube.com/watch?v=${t.id}`
  return ytLink(t)
}

const loadImage = (url: string): Promise<HTMLImageElement | null> =>
  new Promise((resolve) => {
    const img = new Image()
    img.crossOrigin = 'anonymous'
    img.onload = () => resolve(img)
    img.onerror = () => resolve(null)
    img.src = url
  })

/** The colour behind the cover: the artwork's main colour, darkened (like the player). */
function mainColor(img: HTMLImageElement | null): string {
  if (!img) return 'hsl(150 30% 22%)'
  try {
    const c = document.createElement('canvas')
    c.width = c.height = 24
    const ctx = c.getContext('2d')!
    ctx.drawImage(img, 0, 0, 24, 24)
    const d = ctx.getImageData(0, 0, 24, 24).data
    let r = 0, g = 0, b = 0, n = 0
    for (let i = 0; i < d.length; i += 4) {
      const w = 1 + (Math.max(d[i], d[i + 1], d[i + 2]) - Math.min(d[i], d[i + 1], d[i + 2])) / 32
      r += d[i] * w
      g += d[i + 1] * w
      b += d[i + 2] * w
      n += w
    }
    const k = 0.55
    return `rgb(${Math.round((r / n) * k)} ${Math.round((g / n) * k)} ${Math.round((b / n) * k)})`
  } catch {
    return 'hsl(150 30% 22%)'
  }
}

/** Text broken into lines that fit `width`, at most `max` lines (the last one shortened with …). */
function wrap(ctx: CanvasRenderingContext2D, text: string, width: number, max: number): string[] {
  const words = text.split(/\s+/)
  const lines: string[] = []
  let line = ''
  for (const w of words) {
    const next = line ? `${line} ${w}` : w
    if (ctx.measureText(next).width <= width || !line) line = next
    else {
      lines.push(line)
      line = w
    }
  }
  if (line) lines.push(line)
  if (lines.length > max) {
    lines.length = max
    let last = lines[max - 1]
    while (last && ctx.measureText(`${last}…`).width > width) last = last.slice(0, -1)
    lines[max - 1] = `${last}…`
  }
  return lines.map((l) => {
    let s = l
    while (s.length > 1 && ctx.measureText(s).width > width) s = s.slice(0, -1)
    return s === l ? l : `${s}…`
  })
}

/** The picture: 1080 × 1920 (a phone story), the cover in the middle on its own colour. */
export async function renderCard(t: Track): Promise<HTMLCanvasElement> {
  const W = 1080, H = 1920, S = 3
  const c = document.createElement('canvas')
  c.width = W
  c.height = H
  const ctx = c.getContext('2d')!
  const img = await loadImage(artwork(t, 800) ?? '')
  const color = mainColor(img)
  const g = ctx.createLinearGradient(0, 0, 0, H)
  g.addColorStop(0, color)
  g.addColorStop(0.55, color)
  g.addColorStop(1, '#0e0e10')
  ctx.fillStyle = g
  ctx.fillRect(0, 0, W, H)
  ctx.fillStyle = 'rgba(14,14,16,0.25)'
  ctx.fillRect(0, H * 0.4, W, H * 0.6)

  const x = 40 * S
  const width = 280 * S
  const artH = t.podcast && !t.audioURL ? Math.round(width * 9 / 16) : width
  const fontStack = 'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif'
  ctx.font = `800 ${26 * S}px ${fontStack}`
  const titleLines = wrap(ctx, t.title, width, 3)
  ctx.font = `500 ${18 * S}px ${fontStack}`
  const artistLines = wrap(ctx, t.artist, width, 2)
  const block = artH + 24 * S + titleLines.length * 32 * S + 4 * S + artistLines.length * 24 * S
  let y = Math.round((H - block) / 2)

  // Cover with a soft shadow.
  ctx.save()
  ctx.shadowColor = 'rgba(0,0,0,0.45)'
  ctx.shadowBlur = 20 * S
  ctx.shadowOffsetY = 12 * S
  ctx.beginPath()
  ctx.roundRect(x, y, width, artH, 10 * S)
  ctx.fillStyle = '#222'
  ctx.fill()
  ctx.restore()
  ctx.save()
  ctx.beginPath()
  ctx.roundRect(x, y, width, artH, 10 * S)
  ctx.clip()
  if (img) {
    const scale = Math.max(width / img.width, artH / img.height)
    const dw = img.width * scale, dh = img.height * scale
    ctx.drawImage(img, x + (width - dw) / 2, y + (artH - dh) / 2, dw, dh)
  }
  ctx.restore()
  y += artH + 24 * S

  ctx.fillStyle = '#fff'
  ctx.textBaseline = 'top'
  ctx.font = `800 ${26 * S}px ${fontStack}`
  for (const l of titleLines) {
    ctx.fillText(l, x, y)
    y += 32 * S
  }
  y += 4 * S
  ctx.fillStyle = 'rgba(255,255,255,0.75)'
  ctx.font = `500 ${18 * S}px ${fontStack}`
  for (const l of artistLines) {
    ctx.fillText(l, x, y)
    y += 24 * S
  }

  // Drift's logo and name at the bottom.
  const lh = 21 * S, lw = lh * 492 / 519, k = lh / 519
  const lx = x, ly = H - 40 * S - lh
  ctx.fillStyle = '#fff'
  const bars: [number, number][] = [[50, 469], [120, 399], [0, 519], [80, 439]]
  bars.forEach(([top, bottom], i) => {
    ctx.beginPath()
    ctx.roundRect(lx + i * 132 * k, ly + top * k, 96 * k, (bottom - top) * k, 48 * k)
    ctx.fill()
  })
  ctx.font = `800 ${17 * S}px ${fontStack}`
  ctx.textBaseline = 'middle'
  ctx.fillText('Drift', lx + lw + 8 * S, ly + lh / 2)
  return c
}

export function ShareDialog(): JSX.Element | null {
  const track = useStore(shareStore)
  const [card, setCard] = useState<HTMLCanvasElement | null>(null)
  const [url, setUrl] = useState<string | null>(null)

  useEffect(() => {
    setCard(null)
    setUrl(null)
    if (!track) return
    let alive = true
    void renderCard(track).then((c) => {
      if (!alive) return
      setCard(c)
      try {
        setUrl(c.toDataURL('image/png'))
      } catch {
        setUrl(null)
      }
    })
    return () => {
      alive = false
    }
  }, [track])

  if (!track) return null
  const close = (): void => shareStore.set(null)
  const link = shareLink(track)
  const fileName = `${track.artist} - ${track.title}`.replace(/[\\/:*?"<>|]+/g, ' ').trim().slice(0, 120) || 'Drift'

  const copyPicture = (): void => {
    card?.toBlob((blob) => {
      if (!blob) return toast('Couldn’t copy the picture.')
      navigator.clipboard
        .write([new ClipboardItem({ 'image/png': blob })])
        .then(() => toast('Picture copied. Paste it into a chat.'))
        .catch(() => toast('Couldn’t copy the picture.'))
    }, 'image/png')
  }

  return (
    <div className="dialog-layer" onMouseDown={close}>
      <div className="dialog share-dialog" onMouseDown={(e) => e.stopPropagation()} onKeyDown={(e) => e.key === 'Escape' && close()} tabIndex={-1}>
        <h3>Share</h3>
        <div className="share-preview">
          {url ? <img src={url} alt={`Picture of ${track.title} by ${track.artist}`} /> : <Spinner size={22} />}
        </div>
        <div className="share-link">
          <span className="share-url" title={link}>{link}</span>
          <button className="btn ghost" onClick={() => void navigator.clipboard.writeText(link).then(() => toast('Link copied'))}>
            <Icon name="link" size={16} /> Copy link
          </button>
        </div>
        <div className="dialog-buttons">
          <a className={`btn ghost ${url ? '' : 'disabled'}`} href={url ?? undefined} download={`${fileName}.png`} aria-disabled={!url}>
            Save picture…
          </a>
          <span className="spacer" />
          <button className="btn ghost" onClick={close}>Close</button>
          <button className="btn primary" disabled={!url} onClick={copyPicture}>Copy picture</button>
        </div>
      </div>
    </div>
  )
}
