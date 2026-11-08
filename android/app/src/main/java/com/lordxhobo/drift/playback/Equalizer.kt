package com.lordxhobo.drift.playback

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor.AudioFormat
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * The equalizer: 10 bands from 32 Hz to 16 kHz, -12 to +12 dB each, with presets. Same bands, presets and
 * filters as the iPhone and the computer. Applied to the sound in the player, so it works for streamed,
 * cached and downloaded songs, and over Bluetooth.
 */
object Equalizer {
    val bands = listOf(32.0, 64.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0)
    const val MAX_DB = 12.0

    data class Preset(val name: String, val gains: List<Double>)

    val presets = listOf(
        Preset("Flat", listOf(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)),
        Preset("Bass boost", listOf(6.0, 5.0, 4.0, 2.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)),
        Preset("Bass reducer", listOf(-6.0, -5.0, -4.0, -2.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)),
        Preset("Treble boost", listOf(0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 2.0, 4.0, 5.0, 6.0)),
        Preset("Treble reducer", listOf(0.0, 0.0, 0.0, 0.0, 0.0, -1.0, -2.0, -4.0, -5.0, -6.0)),
        Preset("Vocal", listOf(-2.0, -2.0, -1.0, 1.0, 3.0, 4.0, 3.0, 1.0, 0.0, -1.0)),
        Preset("Loudness", listOf(5.0, 4.0, 2.0, 0.0, -1.0, -1.0, 0.0, 2.0, 4.0, 5.0)),
        Preset("Acoustic", listOf(4.0, 4.0, 3.0, 1.0, 2.0, 2.0, 3.0, 3.0, 3.0, 2.0)),
        Preset("Electronic", listOf(4.0, 4.0, 1.0, 0.0, -2.0, 2.0, 1.0, 1.0, 4.0, 5.0)),
        Preset("Hip-hop", listOf(5.0, 4.0, 2.0, 3.0, -1.0, -1.0, 1.0, -1.0, 2.0, 3.0)),
        Preset("Rock", listOf(5.0, 4.0, 3.0, 1.0, -1.0, -1.0, 1.0, 3.0, 4.0, 5.0)),
        Preset("Pop", listOf(-1.0, -1.0, 0.0, 2.0, 4.0, 4.0, 2.0, 0.0, -1.0, -2.0)),
        Preset("Classical", listOf(4.0, 3.0, 2.0, 1.0, -1.0, -1.0, 0.0, 2.0, 3.0, 4.0)),
        Preset("Spoken word", listOf(-4.0, -3.0, -1.0, 1.0, 3.0, 4.0, 4.0, 2.0, 0.0, -2.0)),
    )

    var enabled by mutableStateOf(false)
        private set
    var gains by mutableStateOf(List(bands.size) { 0.0 })
        private set

    /** What the sound thread reads (changes bump the version). */
    @Volatile internal var snapshot = Snapshot(false, List(bands.size) { 0.0 }, 0)
        private set

    internal data class Snapshot(val enabled: Boolean, val gains: List<Double>, val version: Int)

    private lateinit var prefs: SharedPreferences

    fun init(context: Context) {
        prefs = context.getSharedPreferences("drift.settings", Context.MODE_PRIVATE)
        enabled = prefs.getBoolean("eqEnabled", false)
        gains = prefs.getString("eqGains", null)?.split(",")?.mapNotNull { it.toDoubleOrNull() }
            ?.takeIf { it.size == bands.size } ?: List(bands.size) { 0.0 }
        publish()
    }

    private fun publish() {
        snapshot = Snapshot(enabled, gains, snapshot.version + 1)
        if (::prefs.isInitialized) prefs.edit().putBoolean("eqEnabled", enabled).putString("eqGains", gains.joinToString(",")).apply()
    }

    fun turn(on: Boolean) {
        enabled = on
        publish()
    }

    fun changeBand(i: Int, db: Double) {
        gains = gains.toMutableList().also { it[i] = db.coerceIn(-MAX_DB, MAX_DB) }
        publish()
    }

    fun choose(p: Preset) {
        gains = p.gains
        if (!enabled) enabled = true
        publish()
    }

    /** The preset these gains match ("Custom" otherwise). */
    fun presetName(g: List<Double> = gains): String =
        presets.firstOrNull { p -> p.gains.zip(g).all { (a, b) -> abs(a - b) < 0.05 } }?.name ?: "Custom"

    fun label(hz: Double): String = if (hz >= 1000) "${(hz / 1000).toInt()}k" else "${hz.toInt()}"

    /** How much to turn the sound down before boosting, so boosted bands don't distort (dB). */
    fun preamp(g: List<Double>): Double = -maxOf(0.0, g.maxOrNull() ?: 0.0) * 0.8

    /** Biquad coefficients (b0, b1, b2, a1, a2 per band, normalised). Bands at or above half the sample rate stay flat. */
    fun coefficients(g: List<Double>, fs: Double): DoubleArray {
        val out = DoubleArray(bands.size * 5)
        for ((i, f) in bands.withIndex()) {
            val gain = g.getOrElse(i) { 0.0 }
            val o = i * 5
            if (f >= fs * 0.45 || abs(gain) <= 0.01) {
                out[o] = 1.0
                continue
            }
            val a = 10.0.pow(gain / 40)
            val w0 = 2 * PI * f / fs
            val cosw = cos(w0)
            val sinw = sin(w0)
            val b0: Double; val b1: Double; val b2: Double; val a0: Double; val a1: Double; val a2: Double
            if (i == 0 || i == bands.size - 1) {
                // Shelves at the ends (slope 1).
                val alpha = sinw / 2 * sqrt(2.0)
                val sq = 2 * sqrt(a) * alpha
                if (i == 0) {
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
                val alpha = sinw / (2 * 1.41)
                b0 = 1 + alpha * a
                b1 = -2 * cosw
                b2 = 1 - alpha * a
                a0 = 1 + alpha / a
                a1 = -2 * cosw
                a2 = 1 - alpha / a
            }
            out[o] = b0 / a0; out[o + 1] = b1 / a0; out[o + 2] = b2 / a0; out[o + 3] = a1 / a0; out[o + 4] = a2 / a0
        }
        return out
    }
}

/** Applies the equalizer to the sound on its way out (16-bit sound; anything else passes unchanged). */
@UnstableApi
class EqualizerProcessor : BaseAudioProcessor() {
    private var version = -1
    private var on = false
    private var coef = DoubleArray(0)
    private var gain = 1.0
    /** Per channel and band: x1, x2, y1, y2. */
    private var state = DoubleArray(0)
    private var channels = 2
    private var rate = 44_100.0

    override fun onConfigure(inputAudioFormat: AudioFormat): AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) return AudioFormat.NOT_SET
        channels = inputAudioFormat.channelCount
        rate = inputAudioFormat.sampleRate.toDouble()
        version = -1
        return inputAudioFormat
    }

    override fun onFlush() {
        state = DoubleArray(channels * Equalizer.bands.size * 4)
        version = -1
    }

    private fun rebuild(s: Equalizer.Snapshot) {
        version = s.version
        on = s.enabled && s.gains.any { abs(it) > 0.01 }
        coef = Equalizer.coefficients(s.gains, rate)
        gain = 10.0.pow(Equalizer.preamp(s.gains) / 20)
        if (state.size != channels * Equalizer.bands.size * 4) state = DoubleArray(channels * Equalizer.bands.size * 4)
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val size = inputBuffer.remaining()
        if (size == 0) return
        val s = Equalizer.snapshot
        if (s.version != version) rebuild(s)
        val out = replaceOutputBuffer(size)
        if (!on) {
            out.put(inputBuffer).flip()
            return
        }
        val input = inputBuffer.order(ByteOrder.nativeOrder())
        out.order(ByteOrder.nativeOrder())
        val bandCount = Equalizer.bands.size
        var ch = 0
        while (input.remaining() >= 2) {
            var x = input.short / 32768.0 * gain
            for (b in 0 until bandCount) {
                val c = b * 5
                if (coef[c] == 1.0 && coef[c + 1] == 0.0 && coef[c + 2] == 0.0 && coef[c + 3] == 0.0 && coef[c + 4] == 0.0) continue
                val st = (ch * bandCount + b) * 4
                val y = coef[c] * x + coef[c + 1] * state[st] + coef[c + 2] * state[st + 1] - coef[c + 3] * state[st + 2] - coef[c + 4] * state[st + 3]
                state[st + 1] = state[st]
                state[st] = x
                state[st + 3] = state[st + 2]
                state[st + 2] = y
                x = y
            }
            out.putShort((x * 32768.0).coerceIn(-32768.0, 32767.0).toInt().toShort())
            ch = (ch + 1) % channels
        }
        input.position(input.limit())
        out.flip()
    }
}
