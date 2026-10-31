// Control other device: the device button (pick where the music plays) and the player bar while it plays
// on another device.
import { useEffect, useState } from 'react'
import type { JSX } from 'react'
import { deviceOnline, devicePosition } from '@shared/remote'
import type { RemoteDevice } from '@shared/remote'
import { accountStore, back, forward, navStore, openMenuAt, useStore } from '../state'
import type { MenuItem } from '../state'
import { Icon } from '../icons'
import { Art, IconButton } from '../ui'
import { Slider } from '../controls'
import { formatTime, resized } from '../util'
import { connect, playHere, refreshDevices, remoteStore, send, targetDevice } from '../remote'

const deviceIcon = (d: RemoteDevice): string => (d.kind === 'phone' ? 'phone' : 'computer')

function deviceLabel(d: RemoteDevice): string {
  if (!deviceOnline(d)) return `${d.name} (not available)`
  if (d.track) return `${d.name} · ${d.playing ? 'playing' : 'paused'}: ${d.track.title}`
  return d.name
}

/** Opens the device list at a button. */
export async function openDevices(anchor: HTMLElement): Promise<void> {
  if (!accountStore.get().linked) {
    openMenuAt(anchor, [{ label: 'Link your phone in Settings to play there from here.', disabled: true }])
    return
  }
  await refreshDevices()
  const v = remoteStore.get()
  const items: MenuItem[] = [
    { label: 'This computer', icon: 'computer', checked: !v.target, action: () => v.target && playHere() },
    ...(v.devices.length ? [{ label: '', separator: true }] : []),
    ...v.devices.map((d) => ({
      label: deviceLabel(d),
      icon: deviceIcon(d),
      checked: v.target === d.id,
      disabled: !deviceOnline(d),
      action: () => connect(d.id)
    })),
    ...(!v.devices.length ? [{ label: 'Your phone shows up here while Drift is open on it.', disabled: true }] : [])
  ]
  openMenuAt(anchor, items)
}

export function DevicesButton({ size = 18 }: { size?: number }): JSX.Element {
  const v = useStore(remoteStore)
  const d = targetDevice(v)
  return (
    <IconButton
      icon="devices"
      label={d ? `Playing on ${d.name}. Choose a device` : 'Play on another device'}
      active={!!v.target}
      size={size}
      onClick={(e) => void openDevices(e.currentTarget)}
    />
  )
}

/** Ticks twice a second so the position moves. */
function useNow(): number {
  const [now, setNow] = useState(Date.now())
  useEffect(() => {
    const t = window.setInterval(() => setNow(Date.now()), 500)
    return () => window.clearInterval(t)
  }, [])
  return now
}

/** The player bar while the music plays on another device. */
export function RemoteBar({ music }: { music?: boolean }): JSX.Element | null {
  const v = useStore(remoteStore)
  const nav = useStore(navStore)
  const now = useNow()
  const d = targetDevice(v)
  if (!v.target) return null
  const t = d?.track
  const online = !!d && deviceOnline(d, now)
  const position = d ? devicePosition(d, now) : 0
  const duration = d?.duration ?? 0
  return (
    <footer className={`playerbar remote-bar ${music ? 'music' : ''}`}>
      <div className="pb-left">
        {music && (
          <div className="m-top-nav">
            <IconButton icon="back" label="Back" size={16} onClick={back} disabled={nav.index === 0} />
            <IconButton icon="forward" label="Forward" size={16} onClick={forward} disabled={nav.index >= nav.stack.length - 1} />
          </div>
        )}
        {t ? (
          <>
            <Art src={resized(t.artworkURL ?? `https://i.ytimg.com/vi/${t.id}/mqdefault.jpg`, 120)} seed={t.id} size={56} radius={6} />
            <div className="pb-text">
              <span className="pb-title">{t.title}</span>
              <span className="pb-artist">{t.artist}</span>
            </div>
          </>
        ) : (
          <div className="pb-text"><span className="pb-artist">Nothing playing there yet. Pick something to play.</span></div>
        )}
      </div>
      <div className="pb-center">
        <div className="transport">
          <button className={`icon-btn ${d?.shuffle ? 'active' : ''}`} aria-label="Shuffle" aria-pressed={!!d?.shuffle} title="Shuffle" disabled={!online} onClick={() => send({ type: 'shuffle', on: !d?.shuffle })}>
            <Icon name="shuffle" size={18} />
          </button>
          <button className="icon-btn" aria-label="Previous" title="Previous" disabled={!online || !t} onClick={() => send({ type: 'previous' })}>
            <Icon name="prev" size={18} />
          </button>
          <button className="play-btn" aria-label={d?.playing ? 'Pause' : 'Play'} title={d?.playing ? 'Pause' : 'Play'} disabled={!online || !t} onClick={() => send({ type: 'toggle' })}>
            <Icon name={d?.playing ? 'pause' : 'play'} size={16} />
          </button>
          <button className="icon-btn" aria-label="Next" title="Next" disabled={!online || !t} onClick={() => send({ type: 'next' })}>
            <Icon name="next" size={18} />
          </button>
          <button
            className={`icon-btn repeat ${d && d.repeat !== 'off' ? 'active' : ''}`}
            aria-label="Repeat"
            title="Repeat"
            disabled={!online}
            onClick={() => send({ type: 'repeat', mode: d?.repeat === 'off' ? 'all' : d?.repeat === 'all' ? 'one' : 'off' })}
          >
            <Icon name="repeat" size={18} />
            {d?.repeat === 'one' && <span className="repeat-one">1</span>}
          </button>
        </div>
        <div className="progress">
          <span className="time">{formatTime(position)}</span>
          <Slider value={position} max={duration} label="Position" onCommit={(p) => send({ type: 'seek', position: p })} />
          <span className="time">{formatTime(duration)}</span>
        </div>
      </div>
      <div className="pb-right">
        <span className={`remote-pill ${online ? '' : 'offline'}`} title={online ? undefined : 'Make sure Drift is open on it and it’s online.'}>
          <Icon name={d ? deviceIcon(d) : 'phone'} size={14} />
          {d ? (online ? `Playing on ${d.name}` : `Can’t reach ${d.name}`) : 'Connecting…'}
        </span>
        <div className="volume">
          <Icon name="volume" size={18} />
          <Slider value={d?.volume ?? 1} max={1} label={`Volume on ${d?.name ?? 'the other device'}`} className="volume-slider" onCommit={(value) => send({ type: 'volume', value })} />
        </div>
        <DevicesButton />
        <button className="btn ghost small" onClick={playHere} title="Play here instead">Play here</button>
      </div>
      {v.error && <div className="pb-error" title={v.error}>{v.error}</div>}
    </footer>
  )
}
