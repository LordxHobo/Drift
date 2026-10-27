import { useEffect, useState } from 'react'
import type { Playlist, Track } from '@shared/types'

/** YouTube Music images carry their size in the link. */
export function resized(url: string | null | undefined, size: number): string | undefined {
  if (!url) return undefined
  if (url.includes('googleusercontent.com') || url.includes('ggpht.com')) {
    return url.replace(/=w\d+-h\d+/, `=w${size}-h${size}`)
  }
  return url
}

export function artwork(t: Track, size: number): string | undefined {
  if (!t.artworkURL) return `https://i.ytimg.com/vi/${t.id}/hqdefault.jpg`
  return resized(t.artworkURL, size)
}

export function formatTime(t: number | null | undefined): string {
  if (t == null || !Number.isFinite(t) || t < 0) return '0:00'
  const s = Math.floor(t)
  const two = (n: number): string => String(n).padStart(2, '0')
  if (s >= 3600) return `${Math.floor(s / 3600)}:${two(Math.floor((s % 3600) / 60))}:${two(s % 60)}`
  return `${Math.floor(s / 60)}:${two(s % 60)}`
}

export function formatTotal(tracks: Track[]): string {
  const total = Math.round(tracks.reduce((a, t) => a + (t.duration ?? 0), 0))
  const h = Math.floor(total / 3600)
  const m = Math.floor((total % 3600) / 60)
  return h > 0 ? `${h} h ${m} min` : `${m} min`
}

export const plural = (n: number, one: string, many = one + 's'): string => `${n.toLocaleString()} ${n === 1 ? one : many}`

export const tiles = ['#C2410C', '#0F766E', '#6D28D9', '#BE185D', '#1E3A8A', '#854D0E', '#14532D', '#9F1239']
export const tile = (i: number): string => tiles[Math.abs(i) % tiles.length]

export function seedTile(seed: string): string {
  let h = 0
  for (const c of seed) h = (h * 31 + c.charCodeAt(0)) | 0
  return tile(h)
}

/** Drift's accent colors (same as the phone), with a darker shade for the light look. */
export const accents = [
  { dark: '#1ED760', light: '#16A34A', name: 'Green' },
  { dark: '#F5A524', light: '#B45309', name: 'Amber' },
  { dark: '#8B7CFF', light: '#6D5BF5', name: 'Violet' },
  { dark: '#FF6B5B', light: '#DC3F2E', name: 'Coral' },
  { dark: '#2DD4BF', light: '#0D9488', name: 'Teal' }
]
export const musicRed = '#FA2D48'

export function greeting(): string {
  const h = new Date().getHours()
  if (h < 5) return 'Good night'
  if (h < 12) return 'Good morning'
  if (h < 18) return 'Good afternoon'
  return 'Good evening'
}

export const isPhoto = (p: Playlist): boolean => p.coverStyle === 'photo' && !!p.cover

/** All songs in your library, once each (liked songs first). */
export function allSongs(liked: Track[], playlists: Playlist[]): Track[] {
  const seen = new Set<string>()
  const out: Track[] = []
  for (const t of [...liked, ...playlists.flatMap((p) => p.tracks)]) {
    if (seen.has(t.id)) continue
    seen.add(t.id)
    out.push(t)
  }
  return out
}

const colorCache = new Map<string, string>()

/** A deep color taken from the artwork, for the lyrics and header backgrounds. */
export function useArtColor(url: string | undefined, fallbackSeed: string): string {
  const fallback = seedTile(fallbackSeed)
  const [color, setColor] = useState(() => (url && colorCache.get(url)) || fallback)
  useEffect(() => {
    if (!url) return setColor(fallback)
    const known = colorCache.get(url)
    if (known) return setColor(known)
    setColor(fallback)
    let alive = true
    const img = new Image()
    img.crossOrigin = 'anonymous'
    img.onload = () => {
      try {
        const c = document.createElement('canvas')
        c.width = c.height = 24
        const ctx = c.getContext('2d')!
        ctx.drawImage(img, 0, 0, 24, 24)
        const d = ctx.getImageData(0, 0, 24, 24).data
        let r = 0, g = 0, b = 0, n = 0
        for (let i = 0; i < d.length; i += 4) {
          const max = Math.max(d[i], d[i + 1], d[i + 2])
          const min = Math.min(d[i], d[i + 1], d[i + 2])
          const weight = 1 + (max - min) / 32 // favor colorful pixels
          r += d[i] * weight
          g += d[i + 1] * weight
          b += d[i + 2] * weight
          n += weight
        }
        let [h, s, l] = rgbToHsl(r / n, g / n, b / n)
        s = Math.min(0.75, s * 1.2)
        l = Math.max(0.2, Math.min(0.32, l))
        const out = `hsl(${Math.round(h * 360)} ${Math.round(s * 100)}% ${Math.round(l * 100)}%)`
        colorCache.set(url, out)
        if (alive) setColor(out)
      } catch {
        // the image couldn't be read; keep the fallback
      }
    }
    img.src = url
    return () => {
      alive = false
    }
  }, [url, fallback])
  return color
}

function rgbToHsl(r: number, g: number, b: number): [number, number, number] {
  r /= 255
  g /= 255
  b /= 255
  const max = Math.max(r, g, b)
  const min = Math.min(r, g, b)
  const l = (max + min) / 2
  if (max === min) return [0, 0, l]
  const d = max - min
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min)
  let h = max === r ? (g - b) / d + (g < b ? 6 : 0) : max === g ? (b - r) / d + 2 : (r - g) / d + 4
  h /= 6
  return [h, s, l]
}

export function ytLink(t: Track): string {
  return t.upload ? `https://www.youtube.com/watch?v=${t.id}` : `https://music.youtube.com/watch?v=${t.id}`
}

export function timeAgo(ms: number): string {
  const s = Math.round((Date.now() - ms) / 1000)
  if (s < 45) return 'just now'
  if (s < 3600) return `${Math.round(s / 60)} min ago`
  if (s < 86400) return `${Math.round(s / 3600)} h ago`
  return new Date(ms).toLocaleDateString()
}
