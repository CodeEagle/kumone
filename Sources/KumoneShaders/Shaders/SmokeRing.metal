//
//  SmokeRing.metal
//
//  Ported from ShipSwift's `SWSmokeRing.metal` (github.com/signerlabs/ShipSwift,
//  MIT — see ACKNOWLEDGEMENTS).
//
//  A polar-coordinate ring distorted by two layers of value-noise fbm. The
//  layers are phase-shifted in time and cross-faded so the smoke perpetually
//  re-rolls instead of looping visibly. The distorted ring mask drives the
//  alpha and a step-quantized colour gradient.
//
//  Self-driven wander eases ring radius, thickness, noise frequency and
//  inner fill. The re-roll rate stays positive; the gradient is the host palette.
//

#include "KumoneShaderTypes.h"
using namespace metal;

static float smokeRingHash21(float2 p) {
    p = fract(p * float2(0.3183099, 0.3678794)) + 0.1;
    p += dot(p, p.yx + 19.19);
    return fract(p.x * p.y);
}

static float smokeRingRandomR(float2 p) {
    float2 uv = floor(p) / 100.0 + 0.5;
    return smokeRingHash21(fract(uv));
}

static float smokeRingValueNoise(float2 st) {
    float2 i = floor(st);
    float2 f = fract(st);
    float a = smokeRingRandomR(i);
    float b = smokeRingRandomR(i + float2(1.0, 0.0));
    float c = smokeRingRandomR(i + float2(0.0, 1.0));
    float d = smokeRingRandomR(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    float x1 = mix(a, b, u.x);
    float x2 = mix(c, d, u.x);
    return mix(x1, x2, u.y);
}

static float2 smokeRingFBM(float2 n0, float2 n1, int iterations) {
    float2 total = float2(0.0);
    float  amplitude = 0.4;
    for (int i = 0; i < 8; i++) {
        if (i >= iterations) break;
        total.x += smokeRingValueNoise(n0) * amplitude;
        total.y += smokeRingValueNoise(n1) * amplitude;
        n0 *= 1.99;
        n1 *= 1.99;
        amplitude *= 0.65;
    }
    return total;
}

static float smokeRingGetNoise(float2 uv, float2 pUv, float t,
                               float noiseScale, int iterations) {
    const float TWO_PI = 6.28318530718;
    float2 pUvLeft  = pUv + 0.03 * t;
    float period   = max(abs(noiseScale * TWO_PI), 1e-6);
    float2 pUvRight = float2(fract(pUv.x / period) * period, pUv.y) + 0.03 * t;
    float2 n = smokeRingFBM(pUvLeft, pUvRight, iterations);
    return mix(n.y, n.x, smoothstep(-0.25, 0.25, uv.x));
}

static float smokeRingGetRingShape(float2 uv, float radius,
                                   float thickness, float innerShape) {
    float d = length(uv);
    float ring = 1.0 - smoothstep(radius, radius + thickness, d);
    float inner = pow(innerShape, 3.0) * thickness;
    ring *= smoothstep(radius - inner, radius, d);
    return ring;
}

fragment float4 kumone_fragment_smoke_ring(Varying in [[stage_in]],
                                           constant Uniforms& u [[buffer(0)]]) {
    float2 position = in.uv * u.resolution.y;
    float2 size = u.resolution;

    // Independent slow wander keeps the field self-driven.
    float scale = 1.0;
    float radius = 0.6 + (wander(u.time * 0.04, 0.0) - 0.5) * 2.0 * 0.25;
    // Bass expands the ring radius to give low notes a rounded pulse.
    radius = audio_gain(radius, audio_band(u.bands[0]), 0.2);
    // Gentle thickness breathing follows slow drift, without sustained beat swelling.
    float thickness = 0.19 + (wander(u.time * 0.04, 1.7) - 0.5) * 2.0 * 0.04;
    // Beats briefly thicken the ring to make each transient a soft punch.
    thickness = audio_gain(thickness, audio_pulse(u.beat), 0.2);
    float innerShape = 2.0 + (wander(u.time * 0.04, 3.3) - 0.5) * 2.0 * 1.0;
    float noiseScale = 3.25 + (wander(u.time * 0.04, 5.9) - 0.5) * 2.0 * 1.75;
    // Air raises noise frequency to add fine detail to the smoke.
    noiseScale = audio_gain(noiseScale, audio_band(u.bands[3]), 0.2);
    int iterations = 6;
    const float cycleDuration = 3.0;

    float maxDim = max(max(size.x, size.y), 1.0);
    float2 uv = (position - 0.5 * size) / (0.5 * maxDim);
    uv /= max(scale, 0.001);

    // Additive phase flow: amp = base / (0.05 * 8.0) keeps velocity positive; no reversal.
    float t = u.time * 0.75 + wander(u.time * 0.05, 8.1) * 1.875;

    // Two phase-shifted time loops + a cross-fade so the smoke never visibly
    // repeats.
    float timeBlend = 0.5 + 0.5 * sin(0.1 * t * 3.14159265358979 / cycleDuration
                                      - 0.5 * 3.14159265358979);

    float period2    = 2.0 * cycleDuration;
    float localTime1 = fract((0.1 * t + cycleDuration) / period2) * period2;
    float localTime2 = fract((0.1 * t) / period2) * period2;

    float atg = atan2(uv.y, uv.x) + 0.001;
    float l   = length(uv);
    float radialOffset = 0.5 * l - rsqrt(max(1e-4, l));

    float2 polar1 = float2(atg, localTime1 - radialOffset) * noiseScale;
    float2 polar2 = float2(atg, localTime2 - radialOffset) * noiseScale;

    float noise1 = smokeRingGetNoise(uv, polar1, t, noiseScale, iterations);
    float noise2 = smokeRingGetNoise(uv, polar2, t, noiseScale, iterations);
    float noise  = mix(noise1, noise2, timeBlend);

    // Noise warps the polar UV so the ring's silhouette billows.
    float2 shapeUV = uv * (0.8 + 1.2 * noise);
    float ringShape = smokeRingGetRingShape(shapeUV, radius, thickness, innerShape);

    // The host palette in the original's five gradient slots.
    float3 colors[5] = {
        u.paletteAccent.rgb,
        u.palettePrimary.rgb,
        mix(u.palettePrimary.rgb, u.paletteSecondary.rgb, 0.5),
        u.paletteSecondary.rgb,
        u.paletteBackground.rgb,
    };
    int colorsCount = 5;
    int idxLast = colorsCount - 1;

    float mixer = ringShape * ringShape * float(colorsCount - 1);

    float3 gradient = colors[idxLast];
    for (int i = 8; i >= 0; i--) {
        if (i >= idxLast) continue;
        float localT = clamp(mixer - float(idxLast - i - 1), 0.0, 1.0);
        gradient = mix(gradient, colors[i], localT);
    }

    // Loudness swells ring glow while leaving the uncovered background steady.
    float brightness = audio_glow(1.0, audio_energy(u.loudness), 0.6);
    float3 color = gradient * ringShape * brightness;
    float3 bgRGB = u.paletteBackground.rgb;
    color = color + bgRGB * (1.0 - ringShape);

    // Sub-pixel dither against banding.
    float dither = fract(sin(dot(0.014 * position,
                                 float2(12.9898, 78.233))) * 43758.5453123) - 0.5;
    color += float3(dither / 256.0);

    color = beat_flash(color, u.beat, 0.35);
    return float4(color, 1.0);
}
