//
//  Metaballs.metal
//
//  Ported from ShipSwift's `SWMetaballs.metal` (github.com/signerlabs/ShipSwift,
//  MIT — see ACKNOWLEDGEMENTS).
//
//  The originals march up to eight blobs around the field with a smooth
//  metaball merge. Self-driven wander eases blob size and count, with a
//  positive drift rate. The host's four-color palette is stretched into
//  the original's eight slots.
//
//  Entry point: kumone_fragment_metaballs — orbiting blobs.
//
//  ShipSwift's demo "Metaball" is the orbiting-blobs style; the fountain
//  variant that used to live here is gone from the curated list.
//

#include "KumoneShaderTypes.h"
using namespace metal;

static float metaballsHash1(float x) {
    return fract(sin(x * 12.9898) * 43758.5453);
}

static float metaballsNoise1(float x) {
    float i = floor(x);
    float f = fract(x);
    float u = f * f * (3.0 - 2.0 * f);
    return mix(metaballsHash1(i), metaballsHash1(i + 1.0), u);
}

static float metaballsBallShape(float2 uv, float2 c, float p, float2 aspectScale) {
    float2 diff = (uv - c) * aspectScale;
    float s = 0.5 * length(diff);
    s = 1.0 - saturate(s);
    return pow(s, p);
}

/// The original eight color slots, stretched from the host's four colors.
static void metaballsPalette(constant Uniforms& u, thread float3 out[8]) {
    float3 bg = u.paletteBackground.rgb;
    float3 sec = u.paletteSecondary.rgb;
    float3 pri = u.palettePrimary.rgb;
    float3 acc = u.paletteAccent.rgb;
    out[0] = sec;
    out[1] = pri;
    out[2] = mix(sec, pri, 0.5);
    out[3] = acc;
    out[4] = mix(pri, acc, 0.5);
    out[5] = mix(bg, sec, 0.5);
    out[6] = pri;
    out[7] = mix(sec, acc, 0.5);
}

// MARK: - Orbiting blobs

fragment float4 kumone_fragment_metaballs(Varying in [[stage_in]],
                                          constant Uniforms& u [[buffer(0)]]) {
    float time = u.time;
    float2 aspect = u.resolution / max(u.resolution.y, 1.0);
    float2 uv = in.uv / aspect;                  // 0..1 square coordinates
    float2 aspectScale = aspect;

    // Independent slow wander keeps the field self-driven.
    float count = 6.5 + (wander(u.time * 0.04, 1.7) - 0.5) * 2.0 * 1.5;
    float size  = 0.675 + (wander(u.time * 0.04, 3.3) - 0.5) * 2.0 * 0.275;

    float3 colors[8];
    metaballsPalette(u, colors);
    int colorsCountInt = 5;

    // Additive phase flow: amp = base / (0.05 * 8.0) keeps velocity positive; no reversal.
    float t = 0.2 * (time * 0.45 + wander(u.time * 0.05, 0.0) * 1.125 + 2503.4);
    float countClamped = min(max(count, 1.0), 8.0);
    int countCeil = int(ceil(countClamped));

    float3 totalColor = float3(0.0);
    float  totalShape = 0.0;
    for (int i = 0; i < 8; i++) {
        if (i >= countCeil) break;
        float idxFract = float(i) / 20.0;
        float angle = 6.2831853 * idxFract;
        float spd = 1.0 - 0.2 * idxFract;
        float noiseX = metaballsNoise1(angle * 10.0 + float(i) + t * spd);
        float noiseY = metaballsNoise1(angle * 20.0 + float(i) - t * spd);
        float2 pos = float2(0.5) + 1e-4 + 0.9 * (float2(noiseX, noiseY) - 0.5);

        float3 rgb = colors[i % colorsCountInt];
        float sizeFrac = 1.0;
        if (float(i) > floor(countClamped - 1.0)) {
            sizeFrac *= fract(countClamped);
        }
        float p = 45.0 - 30.0 * size * sizeFrac;
        float shape = metaballsBallShape(uv, pos, p, aspectScale);
        shape *= pow(size, 0.2);
        shape = smoothstep(0.0, 1.0, shape);
        totalColor += rgb * shape;
        totalShape += shape;
    }
    totalColor /= max(totalShape, 1e-4);

    float edgeWidth = fwidth(totalShape);
    float finalShape = smoothstep(0.4, 0.4 + edgeWidth, totalShape);
    float3 col = totalColor * finalShape +
                 u.paletteBackground.rgb * (1.0 - finalShape);
    return float4(col, 1.0);
}
