import Accelerate
import Foundation
import os

/// The equalizer: 10 bands from 32 Hz to 16 kHz, -12 to +12 dB each, with presets. Same bands and presets
/// as the computer (desktop/src/shared/equalizer.ts). Applied to the sound in the player's audio tap
/// (SilenceDetector), so it works for streamed, cached and downloaded songs and for podcasts. Not over
/// AirPlay: the receiving speaker plays the sound there.
enum Equalizer {
    static let bands: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let range: ClosedRange<Double> = -12...12

    struct Preset: Identifiable {
        let name: String
        let gains: [Double]
        var id: String { name }
    }

    static let presets: [Preset] = [
        Preset(name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        Preset(name: "Bass boost", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        Preset(name: "Bass reducer", gains: [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0]),
        Preset(name: "Treble boost", gains: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        Preset(name: "Treble reducer", gains: [0, 0, 0, 0, 0, -1, -2, -4, -5, -6]),
        Preset(name: "Vocal", gains: [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1]),
        Preset(name: "Loudness", gains: [5, 4, 2, 0, -1, -1, 0, 2, 4, 5]),
        Preset(name: "Acoustic", gains: [4, 4, 3, 1, 2, 2, 3, 3, 3, 2]),
        Preset(name: "Electronic", gains: [4, 4, 1, 0, -2, 2, 1, 1, 4, 5]),
        Preset(name: "Hip-hop", gains: [5, 4, 2, 3, -1, -1, 1, -1, 2, 3]),
        Preset(name: "Rock", gains: [5, 4, 3, 1, -1, -1, 1, 3, 4, 5]),
        Preset(name: "Pop", gains: [-1, -1, 0, 2, 4, 4, 2, 0, -1, -2]),
        Preset(name: "Classical", gains: [4, 3, 2, 1, -1, -1, 0, 2, 3, 4]),
        Preset(name: "Spoken word", gains: [-4, -3, -1, 1, 3, 4, 4, 2, 0, -2]),
    ]

    /// The preset these gains match, if any ("Custom" otherwise).
    static func presetName(_ gains: [Double]) -> String {
        presets.first { p in zip(p.gains, gains).allSatisfy { abs($0 - $1) < 0.05 } }?.name ?? "Custom"
    }

    static func label(_ hz: Double) -> String { hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))" }

    /// How much to turn the sound down before boosting, so boosted bands don't distort (dB).
    static func preamp(_ gains: [Double]) -> Double { -max(0, gains.max() ?? 0) * 0.8 }

    /// Biquad coefficients (b0, b1, b2, a1, a2 per band, normalised) for vDSP_biquad. Bands at or above
    /// half the sample rate are left flat.
    static func coefficients(_ gains: [Double], sampleRate fs: Double) -> [Double] {
        var out: [Double] = []
        for (i, f) in bands.enumerated() {
            let g = i < gains.count ? gains[i] : 0
            guard f < fs * 0.45, abs(g) > 0.01 else {
                out += [1, 0, 0, 0, 0]
                continue
            }
            let a = pow(10, g / 40)
            let w0 = 2 * Double.pi * f / fs
            let cosw = cos(w0), sinw = sin(w0)
            let b0, b1, b2, a0, a1, a2: Double
            if i == 0 || i == bands.count - 1 {
                // Shelves at the ends (slope 1).
                let alpha = sinw / 2 * sqrt(2.0)
                let sq = 2 * sqrt(a) * alpha
                if i == 0 {
                    b0 = a * ((a + 1) - (a - 1) * cosw + sq)
                    b1 = 2 * a * ((a - 1) - (a + 1) * cosw)
                    b2 = a * ((a + 1) - (a - 1) * cosw - sq)
                    a0 = (a + 1) + (a - 1) * cosw + sq
                    a1 = -2 * ((a - 1) + (a + 1) * cosw)
                    a2 = (a + 1) + (a - 1) * cosw - sq
                } else {
                    b0 = a * ((a + 1) + (a - 1) * cosw + sq)
                    b1 = -2 * a * ((a - 1) + (a + 1) * cosw)
                    b2 = a * ((a + 1) + (a - 1) * cosw - sq)
                    a0 = (a + 1) - (a - 1) * cosw + sq
                    a1 = 2 * ((a - 1) - (a + 1) * cosw)
                    a2 = (a + 1) - (a - 1) * cosw - sq
                }
            } else {
                // Peaking, about an octave wide.
                let alpha = sinw / (2 * 1.41)
                b0 = 1 + alpha * a
                b1 = -2 * cosw
                b2 = 1 - alpha * a
                a0 = 1 + alpha / a
                a1 = -2 * cosw
                a2 = 1 - alpha / a
            }
            out += [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
        }
        return out
    }
}

/// The equalizer setting, readable from the audio thread.
final class EqualizerState: Sendable {
    static let shared = EqualizerState()

    struct Snapshot: Sendable {
        var enabled = false
        var gains = [Double](repeating: 0, count: Equalizer.bands.count)
        var version = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: Snapshot())

    func current() -> Snapshot { state.withLock { $0 } }

    func set(enabled: Bool, gains: [Double]) {
        state.withLock {
            $0.enabled = enabled
            $0.gains = gains
            $0.version += 1
        }
    }
}

/// One song's equalizer filters (used only on the audio thread).
final class EqualizerFilter {
    private var setup: vDSP_biquad_Setup?
    private var delays: [[Float]] = []
    private var version = -1
    private var rate: Double = 44_100
    private var on = false
    private var gain: Float = 1

    deinit {
        if let setup { vDSP_biquad_DestroySetup(setup) }
    }

    /// The sound's sample rate (when the tap is prepared).
    func prepare(sampleRate: Double) {
        if sampleRate > 0 { rate = sampleRate }
        version = -1
    }

    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        let s = EqualizerState.shared.current()
        if s.version != version { rebuild(s) }
        guard on, let setup, frames > 0 else { return }
        var k = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let ptr = data.assumingMemoryBound(to: Float.self)
            let channels = max(1, Int(buffer.mNumberChannels))
            let samples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let n = samples / channels
            guard n > 0 else { continue }
            for ch in 0..<channels {
                if delays.count <= k { delays.append([Float](repeating: 0, count: 2 * Equalizer.bands.count + 2)) }
                vDSP_biquad(setup, &delays[k], ptr + ch, vDSP_Stride(channels), ptr + ch, vDSP_Stride(channels), vDSP_Length(n))
                k += 1
            }
            var g = gain
            vDSP_vsmul(ptr, 1, &g, ptr, 1, vDSP_Length(samples))
        }
    }

    private func rebuild(_ s: EqualizerState.Snapshot) {
        version = s.version
        on = s.enabled && s.gains.contains { abs($0) > 0.01 }
        if let old = setup {
            vDSP_biquad_DestroySetup(old)
            setup = nil
        }
        for i in delays.indices { delays[i] = [Float](repeating: 0, count: delays[i].count) }
        guard on else { return }
        let c = Equalizer.coefficients(s.gains, sampleRate: rate)
        setup = c.withUnsafeBufferPointer { vDSP_biquad_CreateSetup($0.baseAddress!, vDSP_Length(Equalizer.bands.count)) }
        gain = Float(pow(10, Equalizer.preamp(s.gains) / 20))
    }
}
