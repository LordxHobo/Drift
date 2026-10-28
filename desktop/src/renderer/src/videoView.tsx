// Where the episode video shows: a full page (Drift style), the full-screen player (Apple Music
// style) and a small floating window while you browse.
import { useEffect, useRef, useState } from 'react'
import type { JSX } from 'react'
import { Icon } from './icons'
import { back, fullPlayerStore, go, setSettings, settingsStore, useRoute, useStore } from './state'
import { usePlayer } from './player'
import { useVideoReady, videoEl } from './video'
import { IconButton, Spinner, TrackArt } from './ui'

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
  return !!p.current?.podcast && s.podcastVideo
}

/** Drift style: the video filling the main area. */
export function VideoPage(): JSX.Element {
  const p = usePlayer()
  const on = useVideoOn()
  const t = p.current
  return (
    <div className="video-page">
      <div className="lv-head">
        <IconButton icon="minimize" label="Close video" className="round" onClick={back} />
        {t && (
          <div className="lv-now">
            <div>
              <div className="lv-title">{t.title}</div>
              <div className="lv-artist">{t.artist}</div>
            </div>
          </div>
        )}
      </div>
      {on ? (
        <VideoSurface className="big" />
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
  if (!p.current?.podcast) return null
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
