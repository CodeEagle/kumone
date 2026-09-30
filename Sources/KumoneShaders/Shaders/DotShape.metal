//
//  DotShape.metal
//
//  Ported from ShipSwift's `SWDotsPlasma.metal` (github.com/signerlabs/ShipSwift,
//  MIT — see ACKNOWLEDGEMENTS) — the `plasma` style of the SWDots family.
//
//  ShipSwift's demo list has no exact "dot shape" entry: the closest match,
//  "Dot Sphere", is Canvas-rendered (SWDotSphere.swift, not a .metal file) and
//  cannot travel to this pipeline. This plasma-lit flat dot grid stands in for
//  it, and is called out as such in ACKNOWLEDGEMENTS.
//
//  A sin-stack plasma lights a flat (non-perspective) dot grid; each dot reads
//  the plasma intensity at its cell centre and tones up accordingly.
//
//  Self-driven wander eases plasma spatial frequency, dot size and brightness.
//  The plasma flow rate stays positive.
//

#include "KumoneShaderTypes.h"
using namespace metal;

fragment float4 kumone_fragment_dot_shape(Varying in [[stage_in]],
                                          constant Uniforms& u [[buffer(0)]]) {
    float2 position = in.uv * u.resolution.y;
    float2 size = u.resolution;

    // Independent slow wander keeps the field self-driven.
    float patternScale = 2.25 + (wander(u.time * 0.04, 0.0) - 0.5) * 2.0 * 1.25;
    // Bass tightens the plasma pattern to give low notes a spatial pulse.
    patternScale = audio_gain(patternScale, audio_band(u.bands[0]), 0.2);
    float dotSize = 1.4 + (wander(u.time * 0.04, 1.7) - 0.5) * 2.0 * 0.4;
    // Beats briefly enlarge the dots to make transients visible.
    dotSize = audio_gain(dotSize, audio_pulse(u.beat), 0.1);
    float brightness = 1.1 + (wander(u.time * 0.04, 3.3) - 0.5) * 2.0 * 0.4;
    // Loudness lifts dot brightness for a slow swell with the mix.
    brightness = audio_glow(brightness, audio_energy(u.loudness), 0.6);
    float gridDensity = 0.85 + (wander(u.time * 0.018, 8.1) - 0.5) * 2.0 * 0.3;
    float shapeMix = 0.5 + (wander(u.time * 0.025, 11.2) - 0.5) * 2.0 * 0.5;
    float aspect = 1.0 + (wander(u.time * 0.02, 14.6) - 0.5) * 2.0 * 0.35;
    const float vignette = 1.0;

    float2 uv = (position - 0.5 * size) / size.y;
    // Additive angular phase keeps rotation progressing while its offset eases.
    float angle = u.time * 0.025 + wander(u.time * 0.008, 18.3) * 0.2;
    float c = cos(angle), s = sin(angle);
    uv = float2(c * uv.x - s * uv.y, s * uv.x + c * uv.y);
    // Additive phase flow: amp = base / (0.05 * 8.0) keeps velocity positive; no reversal.
    float t = u.time * 0.75 + wander(u.time * 0.05, 5.9) * 1.875;

    float grid      = 0.018 / max(gridDensity, 0.01);
    float2 cell      = round(uv / grid) * grid;
    float2 local = (uv - cell) * float2(aspect, 1.0 / aspect);
    // Continuously morph between circular and rounded-square dots.
    float distToDot = mix(length(local), max(abs(local.x), abs(local.y)), shapeMix);
    float pxR       = (1.6 / size.y) * dotSize;
    float mask      = smoothstep(pxR * 1.4, pxR * 0.6, distToDot);

    float v = sin(cell.x * 8.0 * patternScale + t * 1.3) +
              sin(cell.y * 8.0 * patternScale + t * 1.1) +
              sin((cell.x + cell.y) * 6.0 * patternScale + t * 1.5) +
              sin(length(cell) * 10.0 * patternScale - t * 1.8);
    v = v * 0.25;
    float bright = clamp(0.5 + 0.5 * v, 0.0, 1.0);
    bright = pow(bright, 2.5);

    float2 vUV = (position - 0.5 * size) / size;
    float vig  = clamp(1.0 - dot(vUV, vUV) * 0.9 * vignette, 0.0, 1.0);
    float intensity = mask * bright * vig;

    float3 bg = u.paletteBackground.rgb;
    float3 fg = u.paletteAccent.rgb * brightness;
    fg = mix(fg, u.palettePrimary.rgb, 0.35);
    float3 col = mix(bg, fg, intensity);
    col = audio_bands_color(col, u.low, u.mid, u.high);
    col = audio_fire(col, u.beat, 0.5);
    return float4(col, 1.0);
}
