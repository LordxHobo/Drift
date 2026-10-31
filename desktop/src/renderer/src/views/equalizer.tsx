// Settings › Equalizer: on or off, a preset, and the 10 bands (this computer only).
import { useRef } from 'react'
import type { JSX } from 'react'
import { eqBands, eqLabel, eqMax, eqPresetName, eqPresets, flatGains } from '@shared/equalizer'
import { drift, setSettings, settingsStore, useStore } from '../state'

export function EqualizerSettings(): JSX.Element {
  const s = useStore(settingsStore)
  const gains = Array.isArray(s.eqGains) && s.eqGains.length === eqBands.length ? s.eqGains : flatGains()
  const current = eqPresetName(gains)
  const saveTimer = useRef<number | undefined>(undefined)

  // While dragging, the sound changes right away; the setting is saved once you stop.
  const setBand = (i: number, v: number): void => {
    const next = gains.map((g, j) => (j === i ? v : g))
    settingsStore.update((x) => ({ ...x, eqGains: next, eqEnabled: true }))
    window.clearTimeout(saveTimer.current)
    saveTimer.current = window.setTimeout(() => void drift.setSettings({ eqGains: next, eqEnabled: true }), 400)
  }

  return (
    <div className="eqz">
      <div className="eqz-presets" role="group" aria-label="Presets">
        {eqPresets.map((p) => (
          <button
            key={p.name}
            className={`chip ${current === p.name ? 'on' : ''}`}
            aria-pressed={current === p.name}
            onClick={() => setSettings({ eqGains: p.gains, eqEnabled: s.eqEnabled || p.name !== 'Flat' })}
          >
            {p.name}
          </button>
        ))}
      </div>
      <div className={`eqz-bands ${s.eqEnabled ? '' : 'off'}`}>
        <div className="eqz-scale" aria-hidden="true">
          <span>+{eqMax}</span>
          <span>0</span>
          <span>−{eqMax}</span>
        </div>
        {eqBands.map((hz, i) => (
          <label key={hz} className="eqz-band">
            <span className="eqz-value">{gains[i] > 0 ? `+${gains[i]}` : gains[i]}</span>
            <input
              type="range"
              min={-eqMax}
              max={eqMax}
              step={0.5}
              value={gains[i]}
              onChange={(e) => setBand(i, Number(e.target.value))}
              aria-label={`${eqLabel(hz)} hertz`}
              aria-valuetext={`${gains[i]} decibels`}
            />
            <span className="eqz-hz">{eqLabel(hz)}</span>
          </label>
        ))}
      </div>
      <div className="eqz-foot">
        <span>{current === 'Custom' ? 'Custom' : `Preset: ${current}`}. Drift lowers the volume a little when you boost, so loud songs don’t distort.</span>
        <button className="btn ghost" onClick={() => setSettings({ eqGains: flatGains() })}>Reset to flat</button>
      </div>
    </div>
  )
}
