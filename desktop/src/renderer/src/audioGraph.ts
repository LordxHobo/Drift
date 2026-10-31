// The sound's path from the audio element to the speakers, through Web Audio: the equalizer (10 filters
// and a little less volume when boosting, so it doesn't distort) and a meter that hears silence.
// The streams come from Drift's own drift:// links, which allow this (CORS), so nothing is muted.
import { eqBands, eqPreamp } from '@shared/equalizer'
import { settingsStore } from './state'

interface Graph {
  ctx: AudioContext
  filters: BiquadFilterNode[]
  pre: GainNode
  analyser: AnalyserNode
  buffer: Float32Array<ArrayBuffer>
}

let graph: Graph | undefined
let failed = false

/** Sends the element's sound through the equalizer (once; later calls just wake it up). */
export function connectAudio(el: HTMLAudioElement): void {
  if (failed) return
  if (graph) {
    if (graph.ctx.state === 'suspended') void graph.ctx.resume().catch(() => undefined)
    return
  }
  try {
    const ctx = new AudioContext()
    const source = ctx.createMediaElementSource(el)
    const analyser = ctx.createAnalyser()
    analyser.fftSize = 2048
    const pre = ctx.createGain()
    const filters = eqBands.map((hz, i) => {
      const f = ctx.createBiquadFilter()
      f.type = i === 0 ? 'lowshelf' : i === eqBands.length - 1 ? 'highshelf' : 'peaking'
      f.frequency.value = hz
      f.Q.value = 1.41
      f.gain.value = 0
      return f
    })
    // Silence is measured before the equalizer, so boosting can't hide it.
    source.connect(analyser)
    source.connect(pre)
    let last: AudioNode = pre
    for (const f of filters) {
      last.connect(f)
      last = f
    }
    last.connect(ctx.destination)
    graph = { ctx, filters, pre, analyser, buffer: new Float32Array(analyser.fftSize) }
    apply()
    settingsStore.subscribe(apply)
    if (ctx.state === 'suspended') void ctx.resume().catch(() => undefined)
  } catch {
    failed = true
  }
}

function apply(): void {
  if (!graph) return
  const s = settingsStore.get()
  const gains = s.eqEnabled && Array.isArray(s.eqGains) ? s.eqGains : []
  const t = graph.ctx.currentTime
  graph.filters.forEach((f, i) => f.gain.setTargetAtTime(gains[i] ?? 0, t, 0.02))
  graph.pre.gain.setTargetAtTime(Math.pow(10, eqPreamp(gains.length ? gains : [0]) / 20), t, 0.02)
}

/** The loudest sample right now (0 = silence, 1 = full scale), or null when Drift can't hear the sound. */
export function peakLevel(): number | null {
  if (!graph || graph.ctx.state !== 'running') return null
  graph.analyser.getFloatTimeDomainData(graph.buffer)
  let peak = 0
  for (const v of graph.buffer) peak = Math.max(peak, Math.abs(v))
  return peak
}
