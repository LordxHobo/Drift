import Accelerate
import AVFoundation
import MediaToolbox

/// Loudest sample of the audio that just played, measured as it plays (0 = silence, 1 = full scale).
final class LevelMeter: @unchecked Sendable {
    /// Starts "loud" so nothing is skipped until real measurements arrive.
    var peak: Float = 1
}

/// Listens to the audio of a song through an audio tap, without changing it.
enum SilenceDetector {
    static func audioMix(for track: AVAssetTrack, meter: LevelMeter) -> AVAudioMix? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(meter).toOpaque()),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<LevelMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: nil,
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr
                else { return }
                let meter = Unmanaged<LevelMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                var peak: Float = 0
                for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
                    guard let data = buffer.mData else { continue }
                    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    guard count > 0 else { continue }
                    var m: Float = 0
                    vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &m, vDSP_Length(count))
                    peak = max(peak, m)
                }
                meter.peak = peak
            }
        )
        var tap: Unmanaged<MTAudioProcessingTap>?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                         kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
              let tap else { return nil }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap.takeRetainedValue()
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}
