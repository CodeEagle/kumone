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
//  Ported, the mid band sets the plasma's spatial frequency, the beat pulses
//  the dot size, the overall level sets the brightness, and loudness sets the
//  flow speed.
//

#include "KumoneShaderTypes.h"
using namespace metal;

fragment float4 kumone_fragment_dot_shape(Varying in [[stage_in]],
                                          constant Uniforms& u [[buffer(0)]]) {
    float2 position = in.uv * u.resolution.y;
    float2 size = u.resolution;

    // Audio: mids set the plasma frequency, beat pulses the dots, level sets
    // the brightness, loudness flows the plasma.
    float patternScale = 1.0 + u.mid * 2.5;
    float dotSize = 1.0 + u.beat * 0.8;
    float brightness = 0.7 + 0.8 * u.level;
    float speed = 0.5 + u.loudness * 1.0;
    const float gridDensity = 1.0;
    const float vignette = 1.0;

    float2 uv = (position - 0.5 * size) / size.y;
    float t = u.time * speed;

    float grid      = 0.018 / max(gridDensity, 0.01);
    float2 cell      = round(uv / grid) * grid;
    float distToDot = length(uv - cell);
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
    return float4(col, 1.0);
}
