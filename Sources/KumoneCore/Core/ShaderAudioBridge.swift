import Foundation

/// Derives `ShaderAudioFrame` from `AudioSpectrum`.
///
/// `AudioSpectrum` publishes four per-window band levels and nothing else, but
/// the shaders we port want `beat` and `loudness` too, and want all of it to
/// sway rather than twitch. Rather than touch the real-time audio path, the
/// levels are eased and attenuated here and `beat`/`loudness` are synthesized
/// from them: a beat is a fast rise in the low band, loudness is a slow
/// average across all four. This is deliberately a proxy, not an analysis —
/// the point is that a shader written against `beat` gets something that
/// moves like one.
public struct ShaderAudioBridge {
    /// History kept as plain floats; this runs per frame and must not allocate.
    private var lowHistory: [Float] = []
    /// One smoothed slot per band. The spectrum publishes levels that bounce
    /// with every transient, and the ported shaders multiply those levels
    /// hard, so what the shader reads has to ease in and out rather than
    /// tracking the bounce frame to frame.
    private var bandSmoothed: [Float] = [0, 0, 0, 0]
    private var loudnessSmoothed: Float = 0
    private var beatEnvelope: Float = 0

    private let historyLength = 32

    public init() {}

    /// How strongly audio drives the shaders' continuous motion. The ported
    /// effects read best as a gentle modulation on top of their own time-driven
    /// motion; driven at full level every shader twitches on every transient
    /// instead of swaying. The beat carries the punch separately, so this only
    /// has to carry the sway and stays low.
    public static let reactivity: Float = 0.3

    /// Reads the spectrum and produces one frame.
    ///
    /// - Parameter sampler: Closure returning the level for band `i`, so tests
    ///   can feed synthetic levels without an `AVPlayer`.
    public mutating func frame(sampler: (Int) -> Float) -> ShaderAudioFrame {
        let raw = (0..<AudioSpectrum.bandCount).map { sampler($0) }

        // Smooth and attenuate each band before publishing it. The raw levels
        // bounce with every transient and the shaders multiply them hard, so a
        // shader reading them directly twitches on every beat. A soft attack
        // keeps the rise gentle and a quicker release turns the result into a
        // firm swell: a long, slow tail makes every offset the band drives
        // (zoom, rotation, scale) creep back the way it came and reads as the
        // animation running in reverse.
        for i in 0..<AudioSpectrum.bandCount {
            let target = raw[i] * Self.reactivity
            let coeff: Float = target > bandSmoothed[i] ? 0.05 : 0.035
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
        lowHistory.append(raw[0])
        if lowHistory.count > historyLength { lowHistory.removeFirst() }
        let mean = lowHistory.reduce(0, +) / Float(lowHistory.count)
        // A tight margin over the recent mean so a kick only has to stand out
        // a little to count — a wide margin swallows the beat and the field
        // stops visibly responding to the rhythm.
        let threshold = min(mean * 1.30 + 0.07, 0.95)

        let beatTarget: Float = raw[0] > threshold ? 1.0 : 0.0
        // Snap up hard and release almost as hard: a beat should read as a
        // crisp accent on top of the slow sway, not another long fade.
        let beatCoeff: Float = beatTarget > beatEnvelope ? 0.70 : 0.11
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
        lowHistory.removeAll(keepingCapacity: true)
        bandSmoothed = [0, 0, 0, 0]
        loudnessSmoothed = 0
        beatEnvelope = 0
    }
}
