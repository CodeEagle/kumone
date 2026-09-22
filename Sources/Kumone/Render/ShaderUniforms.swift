import Foundation
import Metal

/// Mirror of the `Uniforms` struct in `KumoneShaderTypes.metal`.
///
/// Both structs must agree byte-for-byte: the host copies this straight into a
/// Metal buffer with no conversion. The layout below follows MSL's default C
/// rules — `float2`/`float4` are 8-/16-byte aligned, so the trailing `_pad`
/// keeps `palettePrimary` 16-byte aligned the way MSL expects it.
struct ShaderUniforms {
    var time: Float = 0
    var resolution: SIMD2<Float> = .zero
    var bands: (Float, Float, Float, Float) = (0, 0, 0, 0)
    var level: Float = 0
    var low: Float = 0
    var mid: Float = 0
    var high: Float = 0
    var beat: Float = 0
    var loudness: Float = 0
    var _pad: Float = 0
    var palettePrimary: SIMD4<Float> = .zero
    var paletteSecondary: SIMD4<Float> = .zero
    var paletteAccent: SIMD4<Float> = .zero
    var paletteBackground: SIMD4<Float> = .zero

    /// Fails the build at link time if Swift ever disagrees with the shader.
    /// The struct is 128 bytes: `time` then 4 bytes of alignment padding before
    /// the 8-byte-aligned `resolution`, then `bands` and the scalar envelope,
    /// then 4 bytes of padding before the 16-byte-aligned palette float4s.
    static let expectedSize = 128
}

/// Palette the host derives from `ArtworkColors`. `accent`/`background` are
/// synthesized on the host side so a two-color extraction still lights a
/// four-slot shader.
struct ShaderPalette {
    var primary: SIMD4<Float>
    var secondary: SIMD4<Float>
    var accent: SIMD4<Float>
    var background: SIMD4<Float>

    static let fallback = ShaderPalette(
        primary: SIMD4(0.16, 0.16, 0.20, 1),
        secondary: SIMD4(0.09, 0.09, 0.12, 1),
        accent: SIMD4(0.55, 0.62, 0.75, 1),
        background: SIMD4(0.05, 0.05, 0.07, 1)
    )
}

/// A frame's worth of audio data, ready for the GPU. Everything the renderer
/// needs to fill `ShaderUniforms`; computed off the render thread.
struct ShaderAudioFrame {
    var bands: (Float, Float, Float, Float) = (0, 0, 0, 0)
    var level: Float = 0
    var low: Float = 0
    var mid: Float = 0
    var high: Float = 0
    var beat: Float = 0
    var loudness: Float = 0

    static let silent = ShaderAudioFrame()
}
