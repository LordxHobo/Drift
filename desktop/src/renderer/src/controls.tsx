import { useRef, useState } from 'react'
import type { JSX } from 'react'
import { Icon } from './icons'
import { cycleRepeat, next, previous, seek, setShuffle, setVolume, toggle, toggleMute, usePlayer, usePosition } from './player'
import { formatTime } from './util'
import { Spinner } from './ui'

/** A draggable bar (song position or volume). */
export function Slider({ value, max, onChange, onCommit, label, className }: {
  value: number; max: number; onChange?: (v: number) => void; onCommit: (v: number) => void; label: string; className?: string
}): JSX.Element {
  const ref = useRef<HTMLDivElement>(null)
  const [drag, setDrag] = useState<number | null>(null)
  const shown = drag ?? value
  const pct = max > 0 ? Math.max(0, Math.min(100, (shown / max) * 100)) : 0

  const at = (clientX: number): number => {
    const r = ref.current!.getBoundingClientRect()
    return Math.max(0, Math.min(1, (clientX - r.left) / r.width)) * max
  }

  return (
    <div
      ref={ref}
      className={`slider ${drag !== null ? 'dragging' : ''} ${className ?? ''}`}
      role="slider"
      aria-label={label}
      aria-valuemin={0}
      aria-valuemax={max}
      aria-valuenow={Math.round(shown)}
      tabIndex={0}
      onKeyDown={(e) => {
        const step = max / 20
        if (e.key === 'ArrowRight') onCommit(Math.min(max, value + step))
        if (e.key === 'ArrowLeft') onCommit(Math.max(0, value - step))
      }}
      onPointerDown={(e) => {
        if (max <= 0) return
        e.currentTarget.setPointerCapture(e.pointerId)
        const v = at(e.clientX)
        setDrag(v)
        onChange?.(v)
      }}
      onPointerMove={(e) => {
        if (drag === null) return
        const v = at(e.clientX)
        setDrag(v)
        onChange?.(v)
      }}
      onPointerUp={(e) => {
        if (drag === null) return
        onCommit(at(e.clientX))
        setDrag(null)
      }}
      onPointerCancel={() => setDrag(null)}
    >
      <div className="slider-track">
        <div className="slider-fill" style={{ width: `${pct}%` }} />
      </div>
      <div className="slider-knob" style={{ left: `${pct}%` }} />
    </div>
  )
}

export function Progress({ showTimes = true, className }: { showTimes?: boolean; className?: string }): JSX.Element {
  const p = usePlayer()
  const position = usePosition()
  const [preview, setPreview] = useState<number | null>(null)
  return (
    <div className={`progress ${className ?? ''}`}>
      {showTimes && <span className="time">{formatTime(preview ?? position)}</span>}
      <Slider
        value={position}
        max={p.duration}
        label="Song position"
        onChange={setPreview}
        onCommit={(v) => {
          setPreview(null)
          seek(v)
        }}
      />
      {showTimes && <span className="time">{formatTime(p.duration)}</span>}
    </div>
  )
}

export function Transport({ size = 'normal' }: { size?: 'normal' | 'large' }): JSX.Element {
  const p = usePlayer()
  const big = size === 'large'
  return (
    <div className={`transport ${big ? 'large' : ''}`}>
      <button className={`icon-btn ${p.shuffle ? 'active' : ''}`} title={p.shuffle ? 'Shuffle on' : 'Shuffle'} aria-label="Shuffle" aria-pressed={p.shuffle} onClick={() => setShuffle(!p.shuffle)}>
        <Icon name="shuffle" size={big ? 22 : 18} />
      </button>
      <button className="icon-btn" title="Previous" aria-label="Previous" onClick={previous} disabled={!p.current}>
        <Icon name="prev" size={big ? 26 : 18} />
      </button>
      <button className="play-btn" title={p.playing ? 'Pause' : 'Play'} aria-label={p.playing ? 'Pause' : 'Play'} onClick={toggle} disabled={!p.current}>
        {p.loading && p.playing ? <Spinner size={big ? 22 : 16} /> : <Icon name={p.playing ? 'pause' : 'play'} size={big ? 26 : 16} />}
      </button>
      <button className="icon-btn" title="Next" aria-label="Next" onClick={() => next()} disabled={!p.current}>
        <Icon name="next" size={big ? 26 : 18} />
      </button>
      <button
        className={`icon-btn repeat ${p.repeat !== 'off' ? 'active' : ''}`}
        title={p.repeat === 'off' ? 'Repeat' : p.repeat === 'all' ? 'Repeat all' : 'Repeat one'}
        aria-label="Repeat"
        onClick={cycleRepeat}
      >
        <Icon name="repeat" size={big ? 22 : 18} />
        {p.repeat === 'one' && <span className="repeat-one">1</span>}
      </button>
    </div>
  )
}

export function Volume(): JSX.Element {
  const p = usePlayer()
  const icon = p.muted || p.volume === 0 ? 'mute' : p.volume < 0.5 ? 'volumeLow' : 'volume'
  return (
    <div className="volume">
      <button className="icon-btn" title={p.muted ? 'Unmute' : 'Mute'} aria-label={p.muted ? 'Unmute' : 'Mute'} onClick={toggleMute}>
        <Icon name={icon} size={18} />
      </button>
      <Slider value={p.muted ? 0 : p.volume} max={1} label="Volume" onChange={setVolume} onCommit={setVolume} className="volume-slider" />
    </div>
  )
}
