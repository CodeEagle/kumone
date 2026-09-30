import CoreGraphics
import Foundation

/// Derives the shader palette from the cover's representative colours.
///
/// Metal's render target is `bgra8Unorm_srgb`, so every value below is computed
/// in LINEAR light and handed straight to the `float4` uniforms.
///
/// The four slots are a scheme, not four independent averages:
///
/// - `primary`    the cover's dominant colour — its hue and saturation kept, its
///                level lifted into a range that still reads as colour once it
///                is composited additively over a dark frosted window;
/// - `secondary`  a supporting colour at a genuinely different hue, so the two
///                never blend into one flat wash;
/// - `accent`     the brightest, most vivid slot. Shaders use it for glow, so it
///                has to be the brightest of the four or the glow reads as noise;
/// - `background` a deep tint of the cover's OWN hue rather than black. Most
///                shaders fill everything that is not their subject with this
///                slot, so a black background is what made the backdrop stop
///                looking like the song. It stays dark — ≈0.035 linear, about a
///                fifth of the primary's level — because controls sit on top.
///
/// A near-grey cover has no hue worth separating, so nothing is rotated for it:
/// the slots stay neutral instead of inventing a colour the artwork never had.
///
/// Pure and deterministic: the same colours in, the same palette out, with no
/// global state and no randomness.
public enum ShaderPaletteBuilder {

    /// Linear-light peak per slot. `accent` leads because it is the glow
    /// colour; `background` trails because it fills the frame.
    ///
    /// Lifted from (0.5 / 0.28 / 1.0 / 0.035): the palette is composited over a
    /// frosted window that dims whatever it sits on, and the old levels read
    /// as grey once they survived that attenuation. `primary` at 0.68 linear
    /// is sRGB ~0.83 — macaron territory, light but still a colour after the
    /// window subdues it; `background` at 0.055 keeps the frame deep but
    /// visibly tinted.
    private static let primaryPeak: Float = 0.68
    private static let secondaryPeak: Float = 0.50
    private static let accentPeak: Float = 1.0
    private static let backgroundPeak: Float = 0.055

    /// Below this saturation a colour has no hue to separate or preserve.
    private static let neutralSaturation: Float = 0.06
    /// A cover this dark in linear light carries no usable colour at all.
    private static let minimumBrightness: Float = 0.004

    public static func make(from colors: ArtworkColors) -> ShaderPalette {
        // No analysed cover yet (the app is idle, or the artwork failed to load):
        // keep the subdued ambient colours rather than inventing a scheme from a
        // placeholder. `ArtworkPalette` only fills the `shader*` slots once it
        // has actually looked at a cover.
        guard let dominantSource = colors.shaderPrimary else {
            return unanalyzed(colors)
        }

        let dominant = linearHSB(decode(dominantSource))
        guard dominant.brightness > minimumBrightness else { return .fallback }

        let supporting = colors.shaderSecondary.map { linearHSB(decode($0)) } ?? dominant
        let highlight = colors.shaderHighlight.map { linearHSB(decode($0)) } ?? supporting

        let neutral = dominant.saturation < neutralSaturation
        let primarySaturation = neutral ? dominant.saturation : saturated(dominant.saturation, floor: 0.42)

        // Secondary keeps the artwork's own supporting hue when it is already a
        // different colour, and is rotated only when the cover is monochrome
        // enough that primary and supporting are the same hue.
        var secondaryHue = supporting.hue
        if !neutral {
            secondaryHue = separate(secondaryHue, from: dominant.hue, minimum: 0.06, offset: -0.15)
        }

        // The glow slot starts from the cover's highlight and is nudged away
        // from both of the others, so shaders always have a colour that is not
        // just a brighter version of the background they sit on.
        var accentHue = highlight.hue
        if !neutral {
            accentHue = separate(accentHue, from: dominant.hue, minimum: 0.07, offset: 0.10)
            if hueDistance(accentHue, secondaryHue) < 0.04 {
                accentHue = wrapHue(accentHue + 0.12)
            }
        }

        let secondarySaturation = neutral ? supporting.saturation : saturated(supporting.saturation, floor: 0.48)
        let accentSaturation = neutral ? highlight.saturation : saturated(highlight.saturation, floor: 0.60)
        // The tint behind everything carries the dominant hue at a saturation the
        // cover may never reach on its own — a washed-out cover still gets a
        // recognisable backdrop, while staying far too dark to compete with the
        // subject colours drawn over it.
        let backgroundSaturation = neutral ? dominant.saturation : max(primarySaturation, 0.45)

        return ShaderPalette(
            primary: slot(hue: dominant.hue, saturation: primarySaturation, brightness: primaryPeak),
            secondary: slot(hue: secondaryHue, saturation: secondarySaturation, brightness: secondaryPeak),
            accent: slot(hue: accentHue, saturation: accentSaturation, brightness: accentPeak),
            background: slot(hue: dominant.hue, saturation: backgroundSaturation, brightness: backgroundPeak)
        )
    }

    /// The palette for a track whose cover has not been analysed yet: the
    /// subdued ambient colours, decoded for the sRGB render target, with the
    /// accent lifted to full scale so a two-colour extraction still lights a
    /// four-slot shader.
    private static func unanalyzed(_ colors: ArtworkColors) -> ShaderPalette {
        let primary = decode(colors.primary)
        let secondary = decode(colors.secondary)
        let peak = max(primary.x, max(primary.y, primary.z))
        let gain: Float = peak > 0 ? min(1.25, 1 / peak) : 1
        let accent = SIMD4(primary.x * gain, primary.y * gain, primary.z * gain, 1)
        return ShaderPalette(primary: primary, secondary: secondary,
                             accent: accent, background: SIMD4<Float>(0, 0, 0, 1))
    }

    /// Keeps `hue` when it already sits far enough from `other`; otherwise
    /// rotates it by a fixed `offset`. The offset is a constant rather than a
    /// search so two covers that need one end up with the same relationship
    /// between their slots instead of drifting apart run to run.
    private static func separate(_ hue: Float, from other: Float,
                                 minimum: Float, offset: Float) -> Float {
        hueDistance(hue, other) >= minimum ? hue : wrapHue(hue + offset)
    }

    /// Circular distance between two hues, 0...0.5.
    private static func hueDistance(_ a: Float, _ b: Float) -> Float {
        let delta = abs(wrapHue(a) - wrapHue(b))
        return min(delta, 1 - delta)
    }

    private static func wrapHue(_ hue: Float) -> Float {
        let wrapped = hue.truncatingRemainder(dividingBy: 1)
        return wrapped < 0 ? wrapped + 1 : wrapped
    }

    /// A chromatic cover keeps as much of its own saturation as it has, but
    /// never so little that the slot stops reading as a colour once it is scaled
    /// up to a usable level. Neutral covers are left completely alone.
    ///
    /// The ceiling is 1 rather than slightly below it: saturation is a ratio, so
    /// the level it is combined with is what bounds the result. Clipping a pure
    /// cover colour here would tint it (a pure red came out 5% pink).
    private static func saturated(_ saturation: Float, floor: Float) -> Float {
        min(max(saturation, floor), 1)
    }

    private static func slot(hue: Float, saturation: Float, brightness: Float) -> SIMD4<Float> {
        rgb(hue: hue, saturation: saturation, brightness: brightness)
    }

    /// sRGB-encoded float4 → linear float4. Same transfer function
    /// `CGColor.converted(to: extendedLinearSRGB)` applies, kept numeric so the
    /// palette drops straight into a Metal `float4` uniform.
    private static func decode(_ srgb: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4(decode(srgb.x), decode(srgb.y), decode(srgb.z), 1)
    }

    private static func decode(_ channel: Float) -> Float {
        let c = min(max(channel, 0), 1)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func linearHSB(_ linear: SIMD4<Float>) -> HSB {
        let r = linear.x, g = linear.y, b = linear.z
        let high = max(r, max(g, b))
        guard high > 0 else { return HSB(hue: 0, saturation: 0, brightness: 0) }
        let low = min(r, min(g, b))
        let delta = high - low
        var hue: Float = 0
        if delta > 0 {
            if high == r {
                hue = (g - b) / delta
            } else if high == g {
                hue = 2 + (b - r) / delta
            } else {
                hue = 4 + (r - g) / delta
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return HSB(hue: wrapHue(hue), saturation: delta / high, brightness: high)
    }

    /// HSB → RGB float4 in the same (linear) light the slots were analysed in.
    private static func rgb(hue: Float, saturation: Float, brightness: Float) -> SIMD4<Float> {
        let h = wrapHue(hue) * 6
        let sector = Int(h)
        let f = h - Float(sector)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - f * saturation)
        let t = brightness * (1 - (1 - f) * saturation)
        let rgb: (Float, Float, Float)
        switch sector % 6 {
        case 0: rgb = (brightness, t, p)
        case 1: rgb = (q, brightness, p)
        case 2: rgb = (p, brightness, t)
        case 3: rgb = (p, q, brightness)
        case 4: rgb = (t, p, brightness)
        default: rgb = (brightness, p, q)
        }
        return SIMD4(rgb.0, rgb.1, rgb.2, 1)
    }

    private struct HSB {
        var hue: Float
        var saturation: Float
        var brightness: Float
    }
}
