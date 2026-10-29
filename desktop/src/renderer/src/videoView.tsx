// Where the episode video shows: a full page (Drift style), the full-screen player (Apple Music
// style) and a small floating window while you browse.
import { useEffect, useRef, useState } from 'react'
import type { JSX } from 'react'
import { Icon } from './icons'
import { back, drift, fullPlayerStore, go, panelStore, setSettings, settingsStore, useRoute, useStore } from './state'
import { usePlayer } from './player'
import { bestQuality, useVideoReady, videoEl } from './video'
import { IconButton, Spinner, TrackArt } from './ui'
import { ChapterList, CurrentChapter, useChapters } from './chapters'

const qualityCache = new Map<string, number[]>()

/** The heights this episode's video comes in. */
function useQualities(id: string | undefined): number[] {
  const [list, setList] = useState<number[]>(() => (id && qualityCache.get(id)) || [])
  useEffect(() => {
    if (!id) return setList([])
    const known = qualityCache.get(id)
    if (known) return setList(known)
    let live = true
    setList([])
    drift
      .videoQualities(id)
      .then((q) => {
        if (q.length) qualityCache.set(id, q)
        if (live) setList(q)
      })
      .catch(() => undefined)
    return () => {
      live = false
    }
  }, [id])
  return list
}

const label = (h: number): string => (h >= 2160 ? '4K' : h >= 1440 ? '1440p' : `${h}p`)

/** The quality button on the video, with its list (drawn inside the video, so it works in full screen too). */
function QualityPicker(): JSX.Element | null {
  const p = usePlayer()
  const want = useStore(settingsStore).videoQuality || 720
  const options = useQualities(p.info?.playId ?? p.current?.id)
  const [open, setOpen] = useState(false)
  const box = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!open) return
    const close = (e: PointerEvent): void => {
      if (!box.current?.contains(e.target as Node)) setOpen(false)
    }
    window.addEventListener('pointerdown', close)
    return () => window.removeEventListener('pointerdown', close)
  }, [open])
  // What's actually playing: the sharpest at or under the setting (or the lowest there is).
  const playing = options.filter((h) => h <= want).at(-1) ?? options[0]
  return (
    <div className="quality" ref={box} onDoubleClick={(e) => e.stopPropagation()}>
      <button className={`quality-btn ${open ? 'on' : ''}`} title="Video quality" aria-label="Video quality" onClick={() => setOpen(!open)}>
        {playing ? label(playing) : label(want)}
        {playing && playing >= 720 && <span className="hd">HD</span>}
      </button>
      {open && (
        <div className="quality-menu" role="menu">
          <div className="quality-head">Quality</div>
          {options.length === 0 && <div className="quality-none"><Spinner size={14} /></div>}
          {options
            .slice()
            .reverse()
            .map((h) => (
              <button
                key={h}
                role="menuitemradio"
                aria-checked={h === playing}
                className={h === playing ? 'on' : ''}
                onClick={() => {
                  // The highest choice means "always the sharpest".
                  setSettings({ videoQuality: h === options.at(-1) ? bestQuality : h })
                  setOpen(false)
                }}
              >
                <span className="quality-check">{h === playing ? <Icon name="check" size={14} /> : null}</span>
                {label(h)}
                {h >= 720 && <span className="hd">HD</span>}
              </button>
            ))}
        </div>
      )}
    </div>
  )
}

/** Shows the one video element here (it moves between places without reloading). */
export function VideoSurface({ className, onExpand }: { className?: string; onExpand?: () => void }): JSX.Element {
  const box = useRef<HTMLDivElement>(null)
  const ready = useVideoReady()
  const p = usePlayer()
  useEffect(() => {
    box.current?.appendChild(videoEl)
  }, [])
  const fullscreen = (): void => {
    if (document.fullscreenElement) void document.exitFullscreen()
    else void box.current?.requestFullscreen()
  }
  return (
    <div className={`video-surface ${className ?? ''}`} ref={box} onDoubleClick={fullscreen}>
      {!ready && p.current && (
        <div className="video-waiting">
          <TrackArt track={p.current} px={640} className="video-poster" radius={0} />
          <Spinner size={22} />
        </div>
      )}
      <div className="video-tools">
        <QualityPicker />
        {onExpand && <IconButton icon="expand" label="Bigger" size={16} onClick={onExpand} />}
        <IconButton icon="fullscreen" label="Full screen" size={16} onClick={fullscreen} />
      </div>
    </div>
  )
}

/** True when the current episode should show its video. */
export function useVideoOn(): boolean {
  const p = usePlayer()
  const s = useStore(settingsStore)
  return !!p.current?.podcast && !p.current.audioURL && s.podcastVideo
}

/** Drift style: the video filling the main area. */
export function VideoPage(): JSX.Element {
  const p = usePlayer()
  const on = useVideoOn()
  const t = p.current
  const { chapters } = useChapters(t)
  // Not twice: the side panel may already be showing them.
  const panelShows = useStore(panelStore) === 'lyrics'
  const showChapters = chapters.length > 0 && !panelShows
  return (
    <div className="video-page">
      <div className="lv-head">
        <IconButton icon="minimize" label="Close video" className="round" onClick={back} />
        {t && (
          <div className="lv-now">
            <div>
              <div className="lv-title">{t.title}</div>
              <div className="lv-artist">
                {t.artist}
                <CurrentChapter className="lv-chapter" />
              </div>
            </div>
          </div>
        )}
      </div>
      {on ? (
        <div className="video-body">
          <VideoSurface className="big" />
          {showChapters && (
            <aside className="video-chapters">
              <div className="lp-label">CHAPTERS</div>
              <ChapterList track={t} size="small" />
            </aside>
          )}
        </div>
      ) : (
        <div className="empty">
          {t?.podcast ? (
            <>
              Video is off. <button className="btn" onClick={() => setSettings({ podcastVideo: true })}>Show video</button>
            </>
          ) : (
            'Video plays for podcast episodes.'
          )}
        </div>
      )}
    </div>
  )
}

/** The small floating video while browsing other pages. */
export function MiniVideo(): JSX.Element | null {
  const on = useVideoOn()
  const route = useRoute()
  const full = useStore(fullPlayerStore)
  const music = useStore(settingsStore).style === 'music'
  const p = usePlayer()
  const [hiddenFor, setHiddenFor] = useState<string | null>(null)
  if (!on || route.name === 'video' || full || hiddenFor === p.current?.id) return null
  return (
    <div className={`mini-video ${music ? 'music' : ''}`}>
      <VideoSurface onExpand={() => (music ? fullPlayerStore.set(true) : go({ name: 'video' }))} />
      <button className="mini-video-close" aria-label="Hide video" title="Hide (keeps playing)" onClick={() => setHiddenFor(p.current?.id ?? null)}>
        <Icon name="close" size={14} />
      </button>
    </div>
  )
}

/** Player button: turn the episode video on or off. */
export function VideoButton(): JSX.Element | null {
  const p = usePlayer()
  const s = useStore(settingsStore)
  const route = useRoute()
  // Episodes from a show's feed are audio only.
  if (!p.current?.podcast || p.current.audioURL) return null
  return (
    <IconButton
      icon="video"
      label={s.podcastVideo ? 'Video on' : 'Show video'}
      active={s.podcastVideo}
      size={18}
      onClick={() => {
        if (!s.podcastVideo) {
          setSettings({ podcastVideo: true })
          if (s.style === 'music') fullPlayerStore.set(true)
          else go({ name: 'video' })
        } else if (route.name === 'video') {
          back()
          setSettings({ podcastVideo: false })
        } else {
          setSettings({ podcastVideo: false })
        }
      }}
    />
  )
}
