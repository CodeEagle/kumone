#include <metal_stdlib>
using namespace metal;

#pragma once

// MARK: - Host contract
//
// A custom shader is a single fragment function with this signature:
//
//     fragment float4 kumone_fragment(Varying in [[stage_in]],
//                                     constant Uniforms& u [[buffer(0)]]);
//
// The host supplies the full-screen vertex stage and every uniform; the shader
// only decides a color per pixel. `Varying.uv` is already aspect-corrected to
// the longest edge, so a shader written against a square travels correctly to
// a wide screen (centered, not stretched).

struct Uniforms {
    float   time;
    float2  resolution;
    float   bands[4];       // AudioSpectrum, 0...1, smoothed
    float   level;          // mean of the four bands
    float   low, mid, high; // derived from bands
    float   beat;           // derived envelope peak, 0...1
    float   loudness;       // derived slow RMS proxy, 0...1
    float   _pad;
    float4  palettePrimary;
    float4  paletteSecondary;
    float4  paletteAccent;
    float4  paletteBackground;
};

struct Varying {
    float4 position [[position]];
    float2 uv;
};


// MARK: - Common noise helpers
//
// `static inline` so each translation unit gets its own copy. Without that,
// linking every shader into one library reports `fbm` as a duplicate symbol.

static inline float hash21(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

static inline float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static inline float fbm(float2 p) {
    float v = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 4; ++i) {
        v += vnoise(p) * amp;
        p = p * 2.07 + float2(13.1, 9.7);
        amp *= 0.5;
    }
    return v;
}
