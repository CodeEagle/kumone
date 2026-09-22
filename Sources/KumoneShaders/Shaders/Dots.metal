//
//  Dots.metal
//
//  Ported from ShipSwift's `SWDotsWavy.metal` (github.com/signerlabs/ShipSwift,
//  MIT — see ACKNOWLEDGEMENTS).
//
//  The `wavy` style of the SWDots family: a 3D dot grid laid on a
//  wave-displaced ground plane. Four sinusoids of different spatial and
//  temporal frequencies build the swell, attenuated toward the horizon so
//  distant cells flatten.
//
//  Ported, the low band lifts the swell, mids quicken the pattern, the beat
//  pulses the dot size, and overall level drives the brightness. The tint is
//  the palette accent over the palette background.
//

#include "KumoneShaderTypes.h"
using namespace metal;

static float dotsWavyHeight(float x, float z, float t,
                            float amplitude, float patternScale) {
    float base = (sin(x * 3.6 * patternScale + t * 0.85) * 0.45 +
                  sin(z * 2.2 * patternScale + t * 0.65) * 0.40 +
                  sin((x * 1.9 + z * 2.0) * patternScale + t * 1.10) * 0.30 +
                  sin((x * 2.8 - z * 1.3) * patternScale + t * 0.45) * 0.22) * 0.16;
    float damp = 1.0 - smoothstep(3.5, 9.0, z) * 0.85;
    return base * damp * amplitude;
}

fragment float4 kumone_fragment_dots(Varying in [[stage_in]],
                                     constant Uniforms& u [[buffer(0)]]) {
    float2 position = in.uv * u.resolution.y;
    float2 size = u.resolution;

    // Audio: low lifts the swell, mids quicken it, beat pulses the dots,
    // level sets the brightness.
    float amplitude = 0.7 + u.low * 1.6;
    float speed = 0.5 + u.loudness * 0.6 + u.mid * 0.3;
    float dotSize = 1.0 + u.beat * 0.8;
    float brightness = 0.7 + 0.6 * u.level;
    float patternScale = 1.0 + u.mid * 1.5;
    float gridDensity = 1.0;
    float vignette = 1.0;
    float depthFade = 1.0 + u.high * 2.0;
    const float horizon = 0.55;

    float2 uv = (position - 0.5 * size) / size.y;
    float t = u.time * speed;

    float yFromHorizon = uv.y - horizon;
    if (yFromHorizon < 0.002) {
        return float4(u.paletteBackground.rgb, 1.0);
    }

    float gridSize = 0.034 / max(gridDensity, 0.01);
    const float cellZmax = 9.1;
    float jMaxAbsolute = cellZmax / gridSize;

    // `dampEst` is evaluated at the smallest candidate cell Z (the cells lifted
    // most by the wave), because damp decreases with Z so damp(Zmin) bounds it.
    float yampMax   = 0.22 * amplitude;
    float Zmin      = max(0.05, (1.0 - yampMax) / yFromHorizon);
    float dampEst   = 1.0 - smoothstep(3.5, 9.0, Zmin) * 0.85;
    float yampBound = max(0.22 * dampEst * amplitude, 0.03);
    float Zlo = max(0.05, (1.0 - yampBound) / yFromHorizon);
    float Zhi = (1.0 + yampBound) / yFromHorizon;
    int jMin = max(1, int(floor(Zlo / gridSize)));
    int jMax = min(int(jMaxAbsolute), int(ceil(Zhi / gridSize)));

    float3 accum = float3(0.0);
    float halfSizeX = 0.5 * size.x;
    float halfSizeY = 0.5 * size.y;
    for (int j = jMin; j <= jMax; j++) {
        float jf    = float(j);
        float cellZ = jf * gridSize;

        float rawR             = 4.4 / (1.0 + cellZ * 1.10);
        float pxR              = max(rawR, 0.85) * dotSize;
        float horizCullThresh  = pxR * 4.0 + 2.0;
        float baseHaloScale    = max(pxR * 1.7, 1.2);
        float subPxFade        = smoothstep(0.4, 1.0, rawR);
        float depth            = 1.0 / (1.0 + cellZ * 0.35 * depthFade);

        float iCenter         = round(uv.x * jf);
        float invCellZ        = 1.0 / cellZ;
        float pitchScreenX    = gridSize * invCellZ * size.y;
        // At high amplitude crests live at small cellZ where the X-pitch grows
        // past the halo's reach; stretch the halo to span the pitch so the
        // ridge stays continuous instead of showing a hole at the wave's peak.
        float haloScale       = max(baseHaloScale, pitchScreenX * 0.5);
        float iCenterScreenX  = iCenter * pitchScreenX + halfSizeX;
        float iCenterCellX    = iCenter * gridSize;

        for (int di = -1; di <= 1; di++) {
            float dotScreenX = iCenterScreenX + float(di) * pitchScreenX;
            if (abs(position.x - dotScreenX) > horizCullThresh) continue;

            float cellX = iCenterCellX + float(di) * gridSize;
            float Y     = dotsWavyHeight(cellX, cellZ, t, amplitude, patternScale);

            float dotYFromHorizon = (1.0 - Y) * invCellZ;
            if (dotYFromHorizon < 0.01) continue;
            float dotScreenY = (horizon + dotYFromHorizon) * size.y + halfSizeY;
            if (abs(position.y - dotScreenY) > horizCullThresh) continue;

            float horizonFade = smoothstep(0.0, 0.05, dotYFromHorizon);
            float distPx      = length(position - float2(dotScreenX, dotScreenY));
            float mask        = smoothstep(pxR + 1.0, pxR - 1.0, distPx);
            float halo        = exp(-distPx / haloScale) * 0.25;
            float crest       = clamp(Y / (0.22 * max(amplitude, 0.01)) * 0.5 + 0.5, 0.0, 1.0);
            float highlight   = 0.55 + 0.85 * crest;
            float intensity   = (mask + halo) * depth * highlight * horizonFade * subPxFade;
            accum = max(accum, float3(intensity));
        }
    }
    accum *= 1.25;
    accum  = min(accum, float3(1.0));

    float2 vUV = (position - 0.5 * size) / size;
    float vig  = clamp(1.0 - dot(vUV, vUV) * 0.6 * vignette, 0.0, 1.0);
    accum *= vig;

    float3 fg = u.paletteAccent.rgb * brightness;
    float3 bg = u.paletteBackground.rgb;
    float3 col = mix(bg, fg, accum);
    return float4(col, 1.0);
}
