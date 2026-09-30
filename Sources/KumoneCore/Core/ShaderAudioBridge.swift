import Foundation

/// Derives `ShaderAudioFrame` from `AudioSpectrum`.
///
/// `AudioSpectrum` publishes four per-window band levels and nothing else, but
/// the shaders we port want `beat` and `loudness` too, and want all of it to
/// sway rather than twitch. Rather than touch the real-time audio path, the
/// levels are eased here and `beat`/`loudness` are synthesized from them: a
/// beat is a fast rise in the low band, loudness is a slow average across all
/// four. This is deliberately a proxy, not an analysis — the point is that a
/// shader written against `beat` gets something that moves like one.
///
/// What leaves here is honest `0...1`: the levels are published as the music
/// actually measures, and each shader shapes them itself, so switching one
/// shader's gain does not silently change every other shader.
public struct ShaderAudioBridge {
    /// One smoothed slot per band. The spectrum publishes levels that bounce
    /// with every transient, and the ported shaders multiply those levels
    /// hard, so what the shader reads has to ease in and out rather than
    /// tracking the bounce frame to frame.
    private var bandSmoothed: [Float] = [0, 0, 0, 0]
    private var loudnessSmoothed: Float = 0
    private var beatEnvelope: Float = 0

    /// Raw low-band history behind the beat detector.
    ///
    /// A fixed ring with a running sum rather than an `Array` of samples: this
    /// runs on every rendered frame, and `append` + `removeFirst` allocates on
    /// every call, which the type's own contract forbids.
    private var lowHistory: [Float]
    private var lowHistorySum: Float = 0
    private var lowHistoryWrite = 0
    private var lowHistoryFill = 0

    private let historyLength: Int

    public init(historyLength: Int = 32) {
        self.historyLength = max(1, historyLength)
        self.lowHistory = [Float](repeating: 0, count: self.historyLength)
    }

    /// How strongly audio drives the shaders' continuous motion.
    ///
    /// Unity: the host publishes honest `0...1` levels and lets the shaders
    /// decide how much of the music they want. It used to be `0.3`, which was
    /// right when nothing read these values — every shader that consumes them
    /// now scales them itself (`audio_band` lifts a band by 1.45x, `audio_pulse`
    /// squares the beat envelope, and each shader applies a conservative gain),
    /// so attenuating here as well left the whole path three times too quiet
    /// to see.
    public static let reactivity: Float = 1.0

    /// Reads the spectrum and produces one frame.
    ///
    /// - Parameter sampler: Closure returning the level for band `i`, so tests
    ///   can feed synthetic levels without an `AVPlayer`.
    public mutating func frame(sampler: (Int) -> Float) -> ShaderAudioFrame {
        let raw = (0..<AudioSpectrum.bandCount).map { sampler($0) }

        // Smooth each band before publishing it. The raw levels bounce with
        // every transient and the shaders multiply them hard, so a shader
        // reading them directly twitches on every beat. A soft attack keeps the
        // rise gentle and a quicker release turns the result into a firm swell:
        // a long, slow tail makes every offset the band drives (zoom, rotation,
        // scale) creep back the way it came and reads as the animation running
        // in reverse.
        //
        // Both coefficients are per-frame, which ties the ease to the render
        // rate — at 60fps these land around a 0.17s attack and a 0.28s release,
        // i.e. the music's shape with the frame-to-frame jitter taken out.
        for i in 0..<AudioSpectrum.bandCount {
            let target = raw[i] * Self.reactivity
            let coeff: Float = target > bandSmoothed[i] ? 0.10 : 0.06
            bandSmoothed[i] += (target - bandSmoothed[i]) * coeff
        }

        let b0 = bandSmoothed[0]
        let b1 = bandSmoothed[1]
        let b2 = bandSmoothed[2]
        let b3 = bandSmoothed[3]
        let bands = (b0, b1, b2, b3)

        let level = (b0 + b1 + b2 + b3) * 0.25

        // Loudness: a slow envelope over the mean. Attack/release asymmetric so
        // it swells into a chorus and eases out of one rather than tracking a
        // single frame.
        let loudnessTarget = min(level * 1.35, 1.0)
        let loudnessCoeff: Float = loudnessTarget > loudnessSmoothed ? 0.12 : 0.035
        loudnessSmoothed += (loudnessTarget - loudnessSmoothed) * loudnessCoeff

        // Beat: look for a low-band rise that stands out over its own recent
        // past. A fixed threshold would either fire constantly on bass-heavy
        // tracks or never on acoustic ones, so the threshold is the running
        // mean plus a margin. This reads the raw low band, not the smoothed
        // one above: a transient is a sharp edge, and the smoothing would
        // round it off before the detector could see it. The published beat is
        // still an envelope, so what the shader receives is a glow, not a click.
        let mean = pushLowSample(raw[0])
        // A tight margin over the recent mean so a kick only has to stand out
        // a little to count — a wide margin swallows the beat and the field
        // stops visibly responding to the rhythm.
        let threshold = min(mean * 1.30 + 0.07, 0.95)

        let beatTarget: Float = raw[0] > threshold ? 1.0 : 0.0
        // Snap up hard and release almost as hard: a beat should read as a
        // crisp accent on top of the slow sway, not another long fade. The
        // attack was 0.70 — fast, but a kick is supposed to *snap*, so it goes
        // to 0.85 while the release tightens to 0.075: the contrast between
        // the ease of the sway and the punch of the hit is what makes the
        // rhythm legible.
        let beatCoeff: Float = beatTarget > beatEnvelope ? 0.85 : 0.075
        beatEnvelope += (beatTarget - beatEnvelope) * beatCoeff

        return ShaderAudioFrame(
            bands: bands,
            level: level,
            low: b0,
            mid: (b1 + b2) * 0.5,
            high: b3,
            beat: beatEnvelope,
            loudness: loudnessSmoothed
        )
    }

    /// Silent frames while no track is feeding us, so a shader's motion doesn't
    /// freeze mid-animation when the audio thread goes quiet.
    public mutating func reset() {
        for i in 0..<AudioSpectrum.bandCount { bandSmoothed[i] = 0 }
        for i in 0..<lowHistory.count { lowHistory[i] = 0 }
        lowHistorySum = 0
        lowHistoryWrite = 0
        lowHistoryFill = 0
        loudnessSmoothed = 0
        beatEnvelope = 0
    }

    // MARK: - Beat history ring

    /// Adds one raw low-band sample and returns the running mean over the
    /// window. Allocation-free: the buffer is sized once in `init` and the
    /// mean is maintained as the sum rather than recomputed over the window.
    private mutating func pushLowSample(_ sample: Float) -> Float {
        if lowHistoryFill == historyLength {
            lowHistorySum -= lowHistory[lowHistoryWrite]
        } else {
            lowHistoryFill += 1
        }
        lowHistory[lowHistoryWrite] = sample
        lowHistorySum += sample
        lowHistoryWrite += 1
        if lowHistoryWrite == historyLength { lowHistoryWrite = 0 }
        return lowHistorySum / Float(lowHistoryFill)
    }
}
