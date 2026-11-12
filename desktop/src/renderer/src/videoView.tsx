// Where the episode video shows: a full page (Drift style), the full-screen player (Apple Music
// style) and a small floating window while you browse.
import { useEffect, useRef, useState } from 'react'
import type { JSX, MouseEvent as ReactMouseEvent } from 'react'
import { Icon } from './icons'
import { back, drift, fullPlayerStore, go, panelStore, setSettings, settingsStore, useRoute, useStore } from './state'
import { usePlayer } from './player'
import { bestQuality, retryVideo, useVideoFailed, useVideoReady, videoEl } from './video'
import { Progress } from './controls'
import { seek, toggle, usePosition } from './player'
import { formatTime } from './util'
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

/**
 * Where the one video element is shown. It can be in several places at once (the watch page and the
 * full player on top, say): the newest one gets it, and when that one closes, it goes back to the one
 * before, so the video never goes blank.
 */
const surfaces: HTMLDivElement[] = []

function claim(): void {
  const top = surfaces[surfaces.length - 1]
  if (top && videoEl.parentElement !== top) top.prepend(videoEl)
}

/** Shows the one video element here (it moves between places without reloading). */
export function VideoSurface({ className, onExpand, controls, theater, onTheater }: {
  className?: string
  onExpand?: () => void
  /** YouTube-style controls on the video (and a click pauses, like YouTube). */
  controls?: boolean
  theater?: boolean
  onTheater?: () => void
}): JSX.Element {
  const clickTimer = useRef<number | undefined>(undefined)
  const box = useRef<HTMLDivElement>(null)
  const ready = useVideoReady()
  const failed = useVideoFailed()
  const p = usePlayer()
  useEffect(() => {
    const el = box.current
    if (!el) return
    surfaces.push(el)
    claim()
    return () => {
      const i = surfaces.indexOf(el)
      if (i >= 0) surfaces.splice(i, 1)
      claim()
    }
  }, [])
  const fullscreen = (): void => {
    window.clearTimeout(clickTimer.current)
    if (document.fullscreenElement) void document.exitFullscreen()
    else void box.current?.requestFullscreen()
  }
  // A click pauses or plays; a double click goes full screen instead (so the click waits a moment).
  const click = (e: ReactMouseEvent): void => {
    if (!controls || (e.target as HTMLElement).closest('button, .video-controls, .quality')) return
    window.clearTimeout(clickTimer.current)
    clickTimer.current = window.setTimeout(toggle, 220)
  }
  return (
    <div className={`video-surface ${className ?? ''} ${controls ? 'with-controls' : ''}`} ref={box} onClick={click} onDoubleClick={fullscreen}>
      {!ready && p.current && (
        <div className="video-waiting">
          <TrackArt track={p.current} px={640} className="video-poster" radius={0} />
          {failed ? (
            <div className="video-failed">
              The picture didn’t load (the sound keeps playing).
              <button className="btn" onClick={(e) => { e.stopPropagation(); retryVideo() }}>Try again</button>
            </div>
          ) : (
            <Spinner size={22} />
          )}
        </div>
      )}
      {controls && <VideoControls onFullscreen={fullscreen} theater={theater} onTheater={onTheater} />}
      <div className="video-tools">
        <QualityPicker />
        {onExpand && <IconButton icon="expand" label="Bigger" size={16} onClick={onExpand} />}
        <IconButton icon="fullscreen" label="Full screen" size={16} onClick={fullscreen} />
      </div>
    </div>
  )
}

/** On the video, like YouTube's: play/pause, back and ahead 10 s, the time and the timeline (with SponsorBlock parts). */
function VideoControls({ onFullscreen, theater, onTheater }: { onFullscreen: () => void; theater?: boolean; onTheater?: () => void }): JSX.Element {
  const p = usePlayer()
  const position = usePosition()
  return (
    <div className="video-controls" onClick={(e) => e.stopPropagation()} onDoubleClick={(e) => e.stopPropagation()}>
      <Progress showTimes={false} className="video-timeline" />
      <div className="video-controls-row">
        <IconButton icon={p.playing ? 'pause' : 'play'} label={p.playing ? 'Pause' : 'Play'} size={20} onClick={toggle} />
        <button className="video-skip" aria-label="Back 10 seconds" onClick={() => seek(Math.max(0, position - 10))}>−10</button>
        <button className="video-skip" aria-label="Ahead 10 seconds" onClick={() => seek(Math.min(p.duration || position + 10, position + 10))}>+10</button>
        <span className="video-time">
          {formatTime(position)} / {formatTime(p.duration)}
        </span>
        <span className="spacer" />
        {onTheater && (
          <button className={`video-theater ${theater ? 'on' : ''}`} aria-label={theater ? 'Default view (T)' : 'Theater mode (T)'} title={theater ? 'Default view (T)' : 'Theater mode (T)'} onClick={onTheater}>
            <span aria-hidden="true" />
          </button>
        )}
        <IconButton icon="fullscreen" label="Full screen (F)" size={18} onClick={onFullscreen} />
      </div>
    </div>
  )
}

/** True when the current episode should show its video. */
export function useVideoOn(): boolean {
  const p = usePlayer()
  const s = useStore(settingsStore)
  return !!p.current?.podcast && !p.current.audioURL && (s.podcastVideo || !!p.current.watch)
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
  if (!on || route.name === 'video' || route.name === 'yt-watch' || full || hiddenFor === p.current?.id) return null
  return (
    <div className={`mini-video ${music ? 'music' : ''}`}>
      <VideoSurface
        onExpand={() =>
          p.current?.watch ? go({ name: 'yt-watch', id: p.current.id }) : music ? fullPlayerStore.set(true) : go({ name: 'video' })
        }
      />
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
  // Episodes from a show's feed are audio only; videos from the YouTube viewer always show.
  if (!p.current?.podcast || p.current.audioURL || p.current.watch) return null
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
