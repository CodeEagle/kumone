import Accelerate
import AVFoundation
import Foundation

/// Real-time band levels pulled out of the playing audio.
///
/// The playback engine is `APlay`, which exposes the interleaved PCM that is
/// about to enter its render graph through `APlay.pcmTap`. The tap runs on the
/// audio render thread and hands those samples to `ingest(_:frameCount:format:)`,
/// which folds them to mono and runs a small FFT. Everything the ingest path
/// touches below is preallocated, lock-free and allocation-free, because the
/// render thread must not malloc or block.
///
/// Band levels are plain `Float` slots read from the render thread by the
/// shaders and by the track-list bars, so a torn read costs at most one slightly
/// stale bar.
public final class AudioSpectrum: @unchecked Sendable {
    public static let shared = AudioSpectrum()

    /// Number of frequency bands published to the UI. Read from the audio thread
    /// too, so it stays a plain constant.
    public nonisolated static let bandCount = 4

    private let store = SpectrumStore()
    private init() {}

    /// True while the tap is actually delivering samples for the current track.
    public var isLive: Bool { store.isLive }

    /// What is known about the current track's tap.
    ///
    /// Three states rather than a flag, because there is a stretch after the
    /// user hits play where the answer isn't known yet: the track's URL is still
    /// being resolved. Treating that as "untappable" flashes the silence for a
    /// moment right as a song starts, and treating it as "tapped" would freeze
    /// the previous track's last frame under it.
    public enum TapState: Int {
        /// Nothing playing.
        case idle = 0
        /// Resolving the source; no samples have arrived yet.
        case preparing = 1
        /// The engine is playing and the tap is delivering samples.
        case tapped = 2
        /// This source can't be tapped — the decorative fallback belongs here.
        case untappable = 3
    }

    public var tapState: TapState { store.tapState }

    /// Latest level for one band, already smoothed and normalized to `0...1`.
    /// A single pointer read — cheap enough to call per bar, per frame.
    public func level(at index: Int) -> Float {
        store.level(at: index)
    }

    /// Call as soon as a track is chosen — before its URL is resolved — so the
    /// bars hold still instead of falling back while the answer is unknown.
    public func beginPreparing() {
        store.setTapState(.preparing)
        store.reset()
    }

    /// Call once the engine reports that the current track is actually playing.
    public func markTapped() {
        store.setTapState(.tapped)
    }

    /// Call when playback stops entirely.
    public func markIdle() {
        store.setTapState(.idle)
        store.reset()
    }

    /// Silences the bands without forgetting that the current item is tapped —
    /// pausing shouldn't make a tapped track look untappable when it resumes.
    public func reset() {
        store.reset()
    }

    /// Entry point for the engine's PCM tap.
    ///
    /// Runs on the audio render thread with the samples that are about to enter
    /// `APlay`'s render graph. The buffer list and its `mData` are only valid for
    /// the duration of the call.
    public func ingest(_ bufferList: UnsafePointer<AudioBufferList>, frameCount: UInt32, format: AVAudioFormat) {
        store.ingest(bufferList, frameCount: Int(frameCount), format: format)
    }
}

// MARK: - Lock-free store shared with the audio thread

/// Backing storage. Held by `AudioSpectrum` and reached from the render thread;
/// every field it exposes is a plain `Float`/`Int32` slot, so reads and writes
/// are individual atomic-sized stores rather than tearing races over compound
/// state.
private final class SpectrumStore: @unchecked Sendable {
    /// FFT window. 512 samples ≈ 12ms at 44.1kHz — fast enough to feel reactive,
    /// long enough to resolve bass.
    private static let fftSize = 512
    private static let log2n = vDSP_Length(9)   // 2^9 == 512
    private static let binCount = fftSize / 2

    /// Int16 PCM is normalized to `[-1, 1)` before analysis so the dB windows
    /// calibrated for the Float32 era still apply.
    private static let int16Scale: Float = 1.0 / 32_768.0

    /// Published band levels, written by the audio thread, read by the UI.
    private let levels: UnsafeMutablePointer<Float>
    /// Whether the tap has produced audio recently.
    private let liveFlag: UnsafeMutablePointer<Int32>
    /// Tap state, written from the engine, read by the shaders.
    private let tapStateSlot: UnsafeMutablePointer<Int32>

    /// Scratch buffers — preallocated because the audio thread must not malloc.
    private let window: UnsafeMutablePointer<Float>
    private let mono: UnsafeMutablePointer<Float>
    private let ring: UnsafeMutablePointer<Float>
    /// Per-channel staging for Int16 → Float32 conversion before the downmix.
    private let channelScratch: UnsafeMutablePointer<Float>
    /// Accumulates mono samples between tap calls until a full FFT window is
    /// available. See `ingest`.
    private let accum: UnsafeMutablePointer<Float>
    private let accumCapacity: Int
    private var accumFill: Int = 0
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    private let magnitudes: UnsafeMutablePointer<Float>
    private let fftSetup: FFTSetup?

    /// Source format, learned from the PCM the engine hands us.
    private var sampleRate: Double = 0
    private var channelCount = 0
    private var isInterleaved = true

    /// Band definitions resolved to bin indices for the current sample rate.
    private let binLo: UnsafeMutablePointer<Int32>
    private let binHi: UnsafeMutablePointer<Int32>
    /// Current window edges in dB, tracking the level this band is producing.
    private let windowHiDB: UnsafeMutablePointer<Float>
    private let windowLoDB: UnsafeMutablePointer<Float>

    init() {
        let n = Self.fftSize
        levels = .allocate(capacity: AudioSpectrum.bandCount)
        levels.initialize(repeating: 0, count: AudioSpectrum.bandCount)
        liveFlag = .allocate(capacity: 1)
        liveFlag.initialize(to: 0)
        tapStateSlot = .allocate(capacity: 1)
        tapStateSlot.initialize(to: Int32(AudioSpectrum.TapState.idle.rawValue))
        window = .allocate(capacity: n)
        mono = .allocate(capacity: n)
        ring = .allocate(capacity: n)
        ring.initialize(repeating: 0, count: n)
        // The ingest path fills this one window at a time and never past it,
        // so a quantum of any size is handled without a bigger buffer.
        accumCapacity = n
        accum = .allocate(capacity: accumCapacity)
        accum.initialize(repeating: 0, count: accumCapacity)
        channelScratch = .allocate(capacity: n)
        realp = .allocate(capacity: Self.binCount)
        imagp = .allocate(capacity: Self.binCount)
        magnitudes = .allocate(capacity: Self.binCount)
        binLo = .allocate(capacity: AudioSpectrum.bandCount)
        binHi = .allocate(capacity: AudioSpectrum.bandCount)
        windowHiDB = .allocate(capacity: AudioSpectrum.bandCount)
        windowLoDB = .allocate(capacity: AudioSpectrum.bandCount)
        fftSetup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))
        vDSP_hann_window(window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    }

    deinit {
        levels.deallocate()
        liveFlag.deallocate()
        tapStateSlot.deallocate()
        window.deallocate()
        mono.deallocate()
        ring.deallocate()
        accum.deallocate()
        channelScratch.deallocate()
        realp.deallocate()
        imagp.deallocate()
        magnitudes.deallocate()
        binLo.deallocate()
        binHi.deallocate()
        windowHiDB.deallocate()
        windowLoDB.deallocate()
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    var isLive: Bool { liveFlag.pointee != 0 }

    var tapState: AudioSpectrum.TapState {
        AudioSpectrum.TapState(rawValue: Int(tapStateSlot.pointee)) ?? .idle
    }

    func setTapState(_ state: AudioSpectrum.TapState) {
        tapStateSlot.pointee = Int32(state.rawValue)
    }

    func level(at index: Int) -> Float {
        guard index >= 0, index < AudioSpectrum.bandCount else { return 0 }
        return levels[index]
    }

    func reset() {
        for i in 0..<AudioSpectrum.bandCount {
            levels[i] = 0
            // Start each track from the calibrated window rather than inheriting
            // the last one's loudness.
            let band = Self.bandEdges[i]
            windowHiDB[i] = band.ceilingDB
            windowLoDB[i] = band.floorDB
        }
        liveFlag.pointee = 0
        accumFill = 0
    }

    // MARK: Format handling

    /// Learns the source format, resolving each band to bin indices only when it
    /// actually changes, so the render thread does no extra work per call.
    private func adopt(format: AVAudioFormat) {
        let rate = format.sampleRate > 0 ? format.sampleRate : 44_100
        let channels = max(1, Int(format.channelCount))
        let interleaved = format.isInterleaved
        guard rate != sampleRate || channels != channelCount || interleaved != isInterleaved else { return }
        sampleRate = rate
        channelCount = channels
        isInterleaved = interleaved

        // Resolve each band to bin indices once, here, so the ingest path
        // touches nothing but plain buffers — iterating a Swift array of tuples
        // on a real-time thread risks retain traffic and lazy-init locks.
        let binWidth = Float(rate) / Float(Self.fftSize)
        for i in 0..<AudioSpectrum.bandCount {
            let band = Self.bandEdges[i]
            binLo[i] = Int32(max(1, Int(band.low / binWidth)))
            binHi[i] = Int32(min(Self.binCount - 1, Int(band.high / binWidth)))
            windowHiDB[i] = band.ceilingDB
            windowLoDB[i] = band.floorDB
        }
    }

    // MARK: Audio-thread analysis

    /// Frequency bands, each with its own dB window.
    ///
    /// Music falls off steeply with frequency — measured across tracks, presence
    /// sits some 30dB under bass — so one shared window would peg the low bars and
    /// leave the high ones flat on the floor. The windows below were calibrated
    /// from real material so every bar spends its time in the visible middle.
    private static let bandEdges: [(low: Float, high: Float, floorDB: Float, ceilingDB: Float)] = [
        (60, 250, -44, -20),
        (250, 800, -46, -26),
        (800, 2_500, -62, -36),
        (2_500, 8_000, -72, -50),
    ]

    /// Envelope time constants in seconds: rise fast so transients register,
    /// fall slowly so the bars read as motion rather than flicker. A slow release
    /// smears beats together and the bars stop reading as movement at all.
    private static let attackSeconds: Float = 0.03
    private static let releaseSeconds: Float = 0.16

    /// Each band's window tracks both edges of the level it actually sees.
    ///
    /// A fixed window can't serve both a sparse acoustic mix and a dense,
    /// heavily-limited one. The loud mix doesn't merely sit higher — it barely
    /// moves, riding a few dB under its limiter, so any window wide enough for
    /// the acoustic track renders it as four motionless bars. Tracking both
    /// edges lets the window slide *and* close in, so a small dynamic range is
    /// spread across the full height instead of vanishing.
    ///
    /// How fast the window closes back in once the extremes stop arriving. Slow
    /// enough that the window describes the passage, not the current beat.
    private static let windowRelaxDBPerSecond: Float = 1.0

    /// How fast each edge reaches out to a new extreme. Snapping to the exact
    /// min/max instead lets one freak-quiet frame set the floor tens of dB below
    /// anything the music does, and the window then describes that outlier for
    /// the rest of the song. The lower edge is the more exposed of the two, so
    /// it moves more cautiously.
    private static let windowRiseSeconds: Float = 0.15
    private static let windowFallSeconds: Float = 0.5

    /// Never let the window close below this, or a quiet passage gets stretched
    /// until its noise floor looks like music.
    private static let minWindowDB: Float = 6

    /// Nor let it open wider than this. Without a cap, one outlier sets an edge
    /// that takes minutes to relax back, and everything in between reads flat.
    private static let maxWindowDB: Float = 42

    /// Frames below this carry no signal at all — digital silence lands near
    /// -180dB. They must not touch the window, or leading silence drags its
    /// floor to the numeric bottom and the whole track plays out against it.
    private static let noSignalDB: Float = -95

    /// A band whose upper edge sits below this reads as silence.
    private static let silenceDB: Float = -70

    /// The engine's PCM tap, on the audio render thread.
    ///
    /// `APlay` hands over the samples about to enter its render graph, usually
    /// interleaved stereo Int16. Whatever the layout, it is folded to mono
    /// Float32 and fed to `analyze` in consecutive FFT-sized windows, so band
    /// levels come from exactly the path they always have.
    ///
    /// The render quantum the engine delivers (470 frames here) can be smaller
    /// than the FFT window (512), so samples are accumulated until a window is
    /// full. The quantum is consumed one window at a time, which keeps the
    /// accumulator no larger than a single window regardless of quantum size:
    /// a small quantum fills across calls, a large one yields several windows.
    fileprivate func ingest(_ bufferList: UnsafePointer<AudioBufferList>, frameCount: Int, format: AVAudioFormat) {
        guard frameCount > 0, fftSetup != nil else { return }
        adopt(format: format)

        let list = bufferList.pointee
        let bufferCount = Int(list.mNumberBuffers)
        guard bufferCount > 0, list.mBuffers.mData != nil else { return }
        let isFloat = format.commonFormat == .pcmFormatFloat32
        let n = Self.fftSize

        var consumed = 0
        while consumed < frameCount {
            let take = min(n - accumFill, frameCount - consumed)
            appendMono(bufferList, baseFrame: consumed, frameCount: take, isFloat: isFloat)
            consumed += take
            if accumFill >= n {
                memcpy(ring, accum, MemoryLayout<Float>.stride * n)
                analyze(blockFrames: n)
                accumFill = 0
            }
        }
    }

    /// Folds `frameCount` frames starting at `baseFrame` to mono and appends
    /// them to the accumulator. Partial — callers top the accumulator up to one
    /// window, never past it.
    private func appendMono(_ bufferList: UnsafePointer<AudioBufferList>, baseFrame: Int, frameCount: Int, isFloat: Bool) {
        let list = bufferList.pointee
        let bufferCount = Int(list.mNumberBuffers)
        let dest = accum.advanced(by: accumFill)
        let n = frameCount
        vDSP_vclr(dest, 1, vDSP_Length(n))

        if bufferCount == 1 {
            // Interleaved: one buffer holding the quantum's multi-channel frames.
            guard let data = list.mBuffers.mData else { return }
            let elementSize = isFloat ? MemoryLayout<Float>.size : MemoryLayout<Int16>.size
            guard Int(list.mBuffers.mDataByteSize) >= (baseFrame + n) * channelCount * elementSize else { return }
            for channel in 0..<channelCount {
                // Element 0 of frame `f` for this channel sits at
                // `(f * channels) + channel` — every channel is walked with a
                // stride of `channels` from its own base.
                if isFloat {
                    let src = data.assumingMemoryBound(to: Float.self).advanced(by: baseFrame * channelCount + channel)
                    vDSP_vadd(dest, 1, src, vDSP_Stride(channelCount), dest, 1, vDSP_Length(n))
                } else {
                    let src = data.assumingMemoryBound(to: Int16.self).advanced(by: baseFrame * channelCount + channel)
                    vDSP_vflt16(src, vDSP_Stride(channelCount), channelScratch, 1, vDSP_Length(n))
                    vDSP_vadd(dest, 1, channelScratch, 1, dest, 1, vDSP_Length(n))
                }
            }
            var scale = isFloat ? 1.0 / Float(channelCount) : Self.int16Scale / Float(channelCount)
            vDSP_vsmul(dest, 1, &scale, dest, 1, vDSP_Length(n))
        } else {
            // Planar: one buffer per channel, each holding the quantum's samples.
            guard bufferCount == channelCount else { return }
            for channel in 0..<bufferCount {
                guard let data = planarBuffer(bufferList, channel).mData else { continue }
                if isFloat {
                    let src = data.assumingMemoryBound(to: Float.self).advanced(by: baseFrame)
                    vDSP_vadd(dest, 1, src, 1, dest, 1, vDSP_Length(n))
                } else {
                    let src = data.assumingMemoryBound(to: Int16.self).advanced(by: baseFrame)
                    vDSP_vflt16(src, 1, channelScratch, 1, vDSP_Length(n))
                    vDSP_vadd(dest, 1, channelScratch, 1, dest, 1, vDSP_Length(n))
                }
            }
            var scale = isFloat ? 1.0 / Float(bufferCount) : Self.int16Scale / Float(bufferCount)
            vDSP_vsmul(dest, 1, &scale, dest, 1, vDSP_Length(n))
        }
        accumFill += n
    }

    /// Element access for the variable-length `mBuffers` array of a planar list.
    private func planarBuffer(_ bufferList: UnsafePointer<AudioBufferList>, _ index: Int) -> AudioBuffer {
        bufferList.withMemoryRebound(to: AudioBuffer.self, capacity: Int(bufferList.pointee.mNumberBuffers)) { ptr in
            ptr[index]
        }
    }

    /// One FFT over `ring`, folded into the published levels.
    private func analyze(blockFrames: Int) {
        guard let fftSetup else { return }
        let n = Self.fftSize
        let take = blockFrames

        vDSP_vmul(ring, 1, window, 1, mono, 1, vDSP_Length(n))

        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        mono.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { ptr in
            vDSP_ctoz(ptr, 2, &split, 1, vDSP_Length(n / 2))
        }
        vDSP_fft_zrip(fftSetup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
        vDSP_zvabs(&split, 1, magnitudes, 1, vDSP_Length(Self.binCount))

        // vDSP's real FFT returns doubled magnitudes; scale back before dB.
        var scale: Float = 1.0 / Float(2 * n)
        vDSP_vsmul(magnitudes, 1, &scale, magnitudes, 1, vDSP_Length(Self.binCount))

        var sawSignal = false

        // Smoothing coefficients derived from elapsed time, so the envelope
        // behaves the same whatever buffer size the tap hands us.
        let dt = Float(take) / Float(sampleRate)
        let attackCoefficient = 1 - expf(-dt / Self.attackSeconds)
        let releaseCoefficient = 1 - expf(-dt / Self.releaseSeconds)
        let relax = Self.windowRelaxDBPerSecond * dt
        let riseCoefficient = 1 - expf(-dt / Self.windowRiseSeconds)
        let fallCoefficient = 1 - expf(-dt / Self.windowFallSeconds)

        for i in 0..<AudioSpectrum.bandCount {
            let lo = Int(binLo[i])
            let hi = Int(binHi[i])
            guard hi >= lo else { continue }

            var sum: Float = 0
            vDSP_sve(magnitudes.advanced(by: lo), 1, &sum, vDSP_Length(hi - lo + 1))
            let mean = sum / Float(hi - lo + 1)
            if mean > 1e-7 { sawSignal = true }

            let db = 20 * log10f(max(mean, 1e-9))

            // Move the window's edges toward what this band is actually doing:
            // snap out to a new extreme, creep back in otherwise.
            var hiDB = windowHiDB[i]
            var loDB = windowLoDB[i]
            // Reach out toward a new extreme, relax back when none arrives.
            // Silent frames are skipped entirely.
            if db > Self.noSignalDB {
                if db > hiDB { hiDB += (db - hiDB) * riseCoefficient } else { hiDB -= relax }
                if db < loDB { loDB += (db - loDB) * fallCoefficient } else { loDB += relax }
                if hiDB - loDB > Self.maxWindowDB {
                    loDB = hiDB - Self.maxWindowDB
                }
                if hiDB - loDB < Self.minWindowDB {
                    let mid = (hiDB + loDB) * 0.5
                    hiDB = mid + Self.minWindowDB * 0.5
                    loDB = mid - Self.minWindowDB * 0.5
                }
            }
            windowHiDB[i] = hiDB
            windowLoDB[i] = loDB

            var target: Float = 0
            if hiDB > Self.silenceDB {
                target = (db - loDB) / (hiDB - loDB)
                target = min(max(target, 0), 1)
            }

            let previous = levels[i]
            let coefficient = target > previous ? attackCoefficient : releaseCoefficient
            levels[i] = previous + (target - previous) * coefficient
        }

        if sawSignal { liveFlag.pointee = 1 }
    }
}
