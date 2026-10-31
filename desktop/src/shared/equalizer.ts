// The equalizer: 10 bands from 32 Hz to 16 kHz, -12 to +12 dB each, with presets. Same as the phone
// (Drift/Core/Equalizer.swift).

export const eqBands = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
export const eqMax = 12

export const eqPresets: { name: string; gains: number[] }[] = [
  { name: 'Flat', gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0] },
  { name: 'Bass boost', gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0] },
  { name: 'Bass reducer', gains: [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0] },
  { name: 'Treble boost', gains: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6] },
  { name: 'Treble reducer', gains: [0, 0, 0, 0, 0, -1, -2, -4, -5, -6] },
  { name: 'Vocal', gains: [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1] },
  { name: 'Loudness', gains: [5, 4, 2, 0, -1, -1, 0, 2, 4, 5] },
  { name: 'Acoustic', gains: [4, 4, 3, 1, 2, 2, 3, 3, 3, 2] },
  { name: 'Electronic', gains: [4, 4, 1, 0, -2, 2, 1, 1, 4, 5] },
  { name: 'Hip-hop', gains: [5, 4, 2, 3, -1, -1, 1, -1, 2, 3] },
  { name: 'Rock', gains: [5, 4, 3, 1, -1, -1, 1, 3, 4, 5] },
  { name: 'Pop', gains: [-1, -1, 0, 2, 4, 4, 2, 0, -1, -2] },
  { name: 'Classical', gains: [4, 3, 2, 1, -1, -1, 0, 2, 3, 4] },
  { name: 'Spoken word', gains: [-4, -3, -1, 1, 3, 4, 4, 2, 0, -2] }
]

export const flatGains = (): number[] => eqBands.map(() => 0)

/** The preset these gains match, or "Custom". */
export function eqPresetName(gains: number[]): string {
  return eqPresets.find((p) => p.gains.every((g, i) => Math.abs(g - (gains[i] ?? 0)) < 0.05))?.name ?? 'Custom'
}

export const eqLabel = (hz: number): string => (hz >= 1000 ? `${hz / 1000}k` : String(hz))

/** How much to turn the sound down before boosting, so boosted bands don't distort (dB). */
export const eqPreamp = (gains: number[]): number => -Math.max(0, ...gains) * 0.8
