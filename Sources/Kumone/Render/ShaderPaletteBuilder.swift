import CoreGraphics
import Foundation
import SwiftUI

/// Builds a `ShaderPalette` from the app's two-color `ArtworkColors`.
///
/// Shaders ported from auralis expect four palette slots, but the app only
/// extracts two dominant colors. Rather than widen the extraction (and change
/// the caching, the fallback, and every caller), the missing slots are derived
/// here: `accent` is a lighter, more saturated take on the primary, and
/// `background` is a deepened secondary. A shader gets a full palette without
/// the app's color pipeline knowing anything about Metal.
enum ShaderPaletteBuilder {
    static func make(from colors: ArtworkColors) -> ShaderPalette {
        let primary = simd(colors.primary)
        let secondary = simd(colors.secondary)

        // Lift the primary toward a highlight so it reads as a brighter take
        // on the same color, not a tinted white.
        var accent = mix(primary, SIMD4<Float>(1, 1, 1, 1), t: 0.35)
        // Nudge the hue toward the secondary so the palette reads as one family,
        // then restore whatever brightness the hue mix cost it. An accent that
        // is dimmer than the color it accents just looks like a bug.
        let hueShifted = mix(accent, secondary, t: 0.18)
        if hueShifted.x < primary.x {
            accent = mix(hueShifted, SIMD4<Float>(1, 1, 1, 1), t: 1.0)
        } else {
            accent = hueShifted
        }

        let background = mix(secondary, SIMD4<Float>(0, 0, 0, 1), t: 0.45)

        return ShaderPalette(
            primary: primary,
            secondary: secondary,
            accent: accent,
            background: background
        )
    }

    /// `Color` → float4 via its resolved components. `Color` exposes no direct
    /// accessor that is consistent across platforms, so read through the
    /// primitive components it was built from.
    private static func simd(_ color: Color) -> SIMD4<Float> {
        guard let comps = color.cgColor?.components, comps.count >= 3 else {
            return SIMD4(0, 0, 0, 1)
        }
        let r = Float(comps[0])
        let g = Float(comps[1])
        let b = Float(comps[2])
        let a = comps.count > 3 ? Float(comps[3]) : 1.0
        return SIMD4(r, g, b, a)
    }

    /// Blends two float4s. The alpha channel is ignored by the shader's additive
    /// stage but kept intact so the struct stays a complete color.
    private static func mix(_ a: SIMD4<Float>, _ b: SIMD4<Float>, t: Float) -> SIMD4<Float> {
        a + (b - a) * t
    }
}
