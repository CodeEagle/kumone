//
//  Voronoi.metal
//
//  Ported from ShipSwift's `SWVoronoi.metal` (github.com/signerlabs/ShipSwift,
//  MIT — see ACKNOWLEDGEMENTS).
//
//  Cellular noise with a quantized palette and a glowing ridge. Self-driven
//  wander eases scale, cell distortion, ridge glow and border width; the cell
//  motion rate stays positive. The host's four-color palette fills five slots.
//

#include "KumoneShaderTypes.h"
using namespace metal;

static float2 voronoiHash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

/// Classic voronoi: returns (edge distance, nearest offset, cell hash).
static float4 voronoiCells(float2 x, float time, float distortion) {
    const float TWO_PI = 6.28318530718;
    float2 ip = floor(x);
    float2 fp = fract(x);
    float2 mg = float2(0.0);
    float2 mr = float2(0.0);
    float  md = 8.0;
    float  rndHash = 0.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 g = float2(float(i), float(j));
            float2 o = voronoiHash22(ip + g);
            float rawHash = o.x;
            o = 0.5 + distortion * sin(time + TWO_PI * o);
            float2 r = g + o - fp;
            float d = dot(r, r);
            if (d < md) {
                md = d;
                mr = r;
                mg = g;
                rndHash = rawHash;
            }
        }
    }
    md = 8.0;
    for (int j = -2; j <= 2; j++) {
        for (int i = -2; i <= 2; i++) {
            float2 g = mg + float2(float(i), float(j));
            float2 o = voronoiHash22(ip + g);
            o = 0.5 + distortion * sin(time + TWO_PI * o);
            float2 r = g + o - fp;
            if (dot(mr - r, mr - r) > 0.00001) {
                md = min(md, dot(0.5 * (mr + r), normalize(r - mr)));
            }
        }
    }
    return float4(md, mr, rndHash);
}

fragment float4 kumone_fragment_voronoi(Varying in [[stage_in]],
                                        constant Uniforms& u [[buffer(0)]]) {
    float time = u.time;
    float2 aspect = u.resolution / max(u.resolution.y, 1.0);
    float minDim = max(min(u.resolution.x, u.resolution.y), 1.0);
    // Centered, isotropic coordinates measured in min-dimension units.
    float2 uv = (in.uv - 0.5 * aspect) * (u.resolution.y / minDim);

    // Independent slow wander keeps the field self-driven.
    float scale = 2.95 + (wander(u.time * 0.04, 0.0) - 0.5) * 2.0 * 0.75;
    float distortion = 0.3 + (wander(u.time * 0.04, 3.3) - 0.5) * 2.0 * 0.15;
    uv *= max(scale, 1e-4);

    // Additive phase flow: amp = base / (0.05 * 8.0) keeps velocity positive; no reversal.
    float t = time * 0.3 + wander(u.time * 0.05, 1.7) * 0.75;
    float4 v = voronoiCells(uv, t, saturate(distortion));

    // The five palette slots from the host's four colors.
    float3 colors[5] = {
        u.paletteBackground.rgb,
        u.paletteSecondary.rgb,
        mix(u.paletteSecondary.rgb, u.palettePrimary.rgb, 0.5),
        u.palettePrimary.rgb,
        u.paletteAccent.rgb,
    };
    int countI = 5;
    float countF = float(countI);

    float shape = saturate(v.w);
    float mixer = (shape - 0.5 / countF) * countF;
    float steps = 2.0;

    float3 gradient = colors[0];
    for (int i = 1; i < 5; i++) {
        if (i >= countI) break;
        float localT = clamp(mixer - float(i - 1), 0.0, 1.0);
        localT = round(localT * steps) / steps;
        gradient = mix(gradient, colors[i], localT);
    }
    if (mixer < 0.0 || mixer > (countF - 1.0)) {
        float localT = mixer + 1.0;
        if (mixer > (countF - 1.0)) {
            localT = mixer - (countF - 1.0);
        }
        localT = round(localT * steps) / steps;
        gradient = mix(colors[countI - 1], colors[0], localT);
    }

    float3 cellColor = gradient;
    float cellOpacity = 1.0;

    // Ridge glow with slowly wandering intensity.
    float glow = 0.65 + (wander(u.time * 0.04, 5.9) - 0.5) * 2.0 * 0.3;
    float glows = length(v.yz * saturate(glow));
    glows = pow(glows, 1.5);
    float3 glowRGB = u.paletteAccent.rgb * 0.6;
    float3 col = mix(cellColor, glowRGB, glows);
    float opacity = cellOpacity + glows;

    // Narrow borders breathe with slow drift, without sustained beat emphasis.
    float gap = 0.016 + (wander(u.time * 0.04, 8.1) - 0.5) * 2.0 * 0.004;
    float edge = v.x;
    float smoothEdge = 0.02 / (2.0 * max(scale, 1e-4)) * (1.0 + 0.5 * saturate(gap));
    edge = smoothstep(saturate(gap) - smoothEdge, saturate(gap) + smoothEdge, edge);
    float3 gapRGB = u.paletteAccent.rgb;
    col = mix(gapRGB, col, edge);
    opacity = mix(1.0, opacity, edge);

    col = col + u.paletteBackground.rgb * (1.0 - saturate(opacity));
    return float4(col, 1.0);
}
