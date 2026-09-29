//
//  SimplexNoise.metal
//
//  Ported from ShipSwift's `SWSimplexNoise.metal` (github.com/signerlabs/ShipSwift,
//  MIT — see ACKNOWLEDGEMENTS). The 2D simplex noise it uses is Ashima Arts'
//  implementation (public domain), carried over unchanged.
//
//  Two layered 2D simplex noises compose into a 0..1 shape value, then map
//  across base colours with banded transitions, derivative-based
//  anti-aliasing on each band boundary, and a wrap zone so the first and
//  last colours blend smoothly across the gradient seam.
//
//  Self-driven wander eases field scale, band softness and shape offset;
//  the upward drift rate stays positive. The host's four palette colours
//  are stretched across the original's slots.
//

#include "KumoneShaderTypes.h"
using namespace metal;

static float2 simplexMod289_2(float2 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}
static float3 simplexMod289_3(float3 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}
static float3 simplexPermute289(float3 x) {
    return simplexMod289_3((x * 34.0 + 1.0) * x);
}

// 2D simplex noise (Ashima Arts, public domain).
static float simplexSNoise(float2 v) {
    const float4 C = float4(0.211324865405187,
                            0.366025403784439,
                            -0.577350269189626,
                            0.024390243902439);
    float2 i  = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = simplexMod289_2(i);
    float3 p = simplexPermute289(simplexPermute289(i.y + float3(0.0, i1.y, 1.0))
                                 + i.x + float3(0.0, i1.x, 1.0));
    float3 m = max(0.5 - float3(dot(x0, x0),
                                 dot(x12.xy, x12.xy),
                                 dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;
    float3 x  = 2.0 * fract(p * C.www) - 1.0;
    float3 h  = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    float3 g;
    g.x  = a0.x  * x0.x  + h.x  * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

static float simplexSteppedSmooth(float m, float steps, float softness) {
    float stepT  = floor(m * steps) / steps;
    float f      = m * steps - floor(m * steps);
    float fw     = steps * fwidth(m);
    float smoothed = smoothstep(0.5 - softness,
                                min(1.0, 0.5 + softness + fw),
                                f);
    return stepT + smoothed / steps;
}

fragment float4 kumone_fragment_simplex_noise(Varying in [[stage_in]],
                                              constant Uniforms& u [[buffer(0)]]) {
    float2 position = in.uv * u.resolution.y;
    float2 size = u.resolution;

    // Independent slow wander keeps the field self-driven.
    float scale = 1.1 + (wander(u.time * 0.04, 0.0) - 0.5) * 2.0 * 0.6;
    // Bass broadens the noise scale to let low notes breathe across the field.
    scale = audio_gain(scale, audio_band(u.bands[0]), 0.2);
    float softness = 0.55 + (wander(u.time * 0.04, 1.7) - 0.5) * 2.0 * 0.35;
    // Presence softens band boundaries to let the mids smooth the transitions.
    softness = audio_gain(softness, audio_band(u.bands[2]), 0.1);
    float shapeOffset = 0.125 + (wander(u.time * 0.04, 3.3) - 0.5) * 2.0 * 0.125;
    // Beats briefly shift the shape offset to punch through the bands.
    shapeOffset = audio_offset(shapeOffset, audio_pulse(u.beat), 0.1);

    float minDim = max(min(size.x, size.y), 1.0);
    float2 uv = (position - 0.5 * size) / minDim;
    uv /= max(scale, 0.001);
    uv *= 0.1;

    // Additive phase flow: amp = base / (0.05 * 8.0) keeps velocity positive; no reversal.
    float t = 0.2 * (u.time * 0.85 + wander(u.time * 0.05, 5.9) * 2.125);

    float noise  = 0.5 * simplexSNoise(uv - float2(0.0, 0.30 * t));
    noise       += 0.5 * simplexSNoise(2.0 * uv + float2(0.0, 0.32 * t));

    float shape = 0.5 + 0.5 * noise + shapeOffset;
    shape = clamp(shape, 0.0, 1.0);

    // The host's four colours in the original's five gradient slots.
    float3 colors[5] = {
        u.paletteBackground.rgb,
        u.paletteSecondary.rgb,
        mix(u.paletteSecondary.rgb, u.palettePrimary.rgb, 0.5),
        u.palettePrimary.rgb,
        u.paletteAccent.rgb,
    };
    int countI = 5;
    float n = float(countI);
    float mixer = (shape - 0.5 / n) * n;
    float steps = 2.0;

    float3 gradient = colors[0];
    for (int i = 1; i < 5; i++) {
        if (i >= countI) break;
        float localM = clamp(mixer - float(i - 1), 0.0, 1.0);
        localM = simplexSteppedSmooth(localM, steps, 0.5 * softness);
        gradient = mix(gradient, colors[i], localM);
    }

    if (mixer < 0.0 || mixer > (n - 1.0)) {
        float localM = (mixer < 0.0) ? (mixer + 1.0) : (mixer - (n - 1.0));
        localM = simplexSteppedSmooth(localM, steps, 0.5 * softness);
        gradient = mix(colors[countI - 1], colors[0], localM);
    }

    // Loudness lifts field brightness for a slow swell with the mix.
    float brightness = audio_glow(1.0, audio_energy(u.loudness), 0.6);
    gradient *= brightness;

    // Sub-pixel dither against gradient banding.
    float dither = fract(sin(dot(0.014 * position,
                                 float2(12.9898, 78.233))) * 43758.5453123) - 0.5;
    gradient += float3(dither / 256.0);

    return float4(gradient, 1.0);
}
