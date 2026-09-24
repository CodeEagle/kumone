import CoreGraphics
import Foundation

/// Preserve the cover's representative colors independently of the subdued
/// ambient UI palette. Metal's sRGB render target expects linear RGB output,
/// so the sRGB-encoded `ArtworkColors` slots are decoded here.
public enum ShaderPaletteBuilder {
    public static func make(from colors: ArtworkColors) -> ShaderPalette {
        let primary = linear(colors.shaderPrimary ?? colors.primary)
        let secondary = linear(colors.shaderSecondary ?? colors.secondary)

        // Scale all channels together: brighten without bleaching or shifting hue.
        let peak = max(primary.x, max(primary.y, primary.z))
        let gain: Float = peak > 0 ? min(1.25, 1 / peak) : 1
        let accent = SIMD4(primary.x * gain, primary.y * gain, primary.z * gain, 1)
        // Shaders fill non-subject regions with paletteBackground. Neutral black
        // avoids competing with the cover colors and lets primary/secondary/accent stand out.
        let background = SIMD4<Float>(0, 0, 0, 1)
        return ShaderPalette(primary: primary, secondary: secondary,
                             accent: accent, background: background)
    }

    /// sRGB-encoded float4 → linear float4. Same transfer function
    /// `CGColor.converted(to: extendedLinearSRGB)` applies, kept numeric so the
    /// palette drops straight into a Metal `float4` uniform.
    private static func linear(_ srgb: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4(decode(srgb.x), decode(srgb.y), decode(srgb.z), 1)
    }

    private static func decode(_ channel: Float) -> Float {
        let c = min(max(channel, 0), 1)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
}
