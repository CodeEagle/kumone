//
//  ColorPanels.metal
//
//  Ported from ShipSwift's `SWColorPanels.metal` (github.com/signerlabs/ShipSwift,
//  MIT — see ACKNOWLEDGEMENTS).
//
//  Pseudo-3D semi-transparent panels rotating around a central vertical axis.
//  Each panel is rendered analytically: given its angle, a perspective
//  projection derives the per-pixel z-depth and decides which side of the
//  panel we're on. Panels spawn in two interleaved sets so the wheel appears
//  continuous.
//
//  Self-driven wander eases wheel scale, density, edge skew and fades;
//  the rotation rate stays positive. Panel colours come from the host palette.
//

#include "KumoneShaderTypes.h"
using namespace metal;

constant float colorPanelsZLimit = 0.5;

// Analytic perspective projection of one panel.
// Returns (panelMask, panelMap) where panelMap is 0 at the far edge and 1 at
// the near edge.
static float2 colorPanelsGetPanel(float angle, float2 uv, float invLength,
                                  float aa, float a1, float a2,
                                  float blur, float scale, bool edges) {
    float sinA = sin(angle);
    float cosA = cos(angle);

    float denom = sinA - uv.y * cosA;
    if (abs(denom) < 0.01) return float2(0.0);

    float z = uv.y / denom;
    if (z <= 0.0 || z > colorPanelsZLimit) return float2(0.0);

    float zRatio   = z / colorPanelsZLimit;
    float panelMap = 1.0 - zRatio;
    float x        = uv.x * (cosA * z + 1.0) * invLength;

    float zOffset = zRatio - 0.5;
    float left    = -0.5 + zOffset * a1;
    float right   =  0.5 - zOffset * a2;
    float blurX   = aa + 2.0 * panelMap * blur;

    float leftEdge1  = left  - blurX;
    float leftEdge2  = left  + 0.25 * blurX;
    float rightEdge1 = right - 0.25 * blurX;
    float rightEdge2 = right + blurX;

    float panel = smoothstep(leftEdge1, leftEdge2, x) *
                  (1.0 - smoothstep(rightEdge1, rightEdge2, x));
    panel *= mix(0.0, panel,
                 smoothstep(0.0, 0.01 / max(scale, 1e-6), panelMap));

    float midScreen = abs(sinA);
    if (edges) {
        panelMap = mix(0.99, panelMap,
                       panel * clamp(panelMap / (0.15 * (1.0 - pow(midScreen, 0.1))),
                                     0.0, 1.0));
    } else if (midScreen < 0.07) {
        panel *= (midScreen * 15.0);
    }

    return float2(panel, panelMap);
}

// Composite one panel's colour onto the running buffer.
static float4 colorPanelsBlendColor(float4 colorA, float panelMask,
                                    float panelMap, float fadeIn, float fadeOut) {
    float fade = 1.0 - smoothstep(0.97 - 0.97 * fadeIn, 1.0, panelMap);
    fade *= smoothstep(-0.2 * (1.0 - fadeOut), fadeOut, panelMap);

    float3 blendedRGB = mix(float3(0.0), colorA.rgb, fade);
    float  blendedA   = mix(0.0, colorA.a, fade);
    return float4(blendedRGB, blendedA) * panelMask;
}

fragment float4 kumone_fragment_color_panels(Varying in [[stage_in]],
                                             constant Uniforms& u [[buffer(0)]]) {
    float2 position = in.uv * u.resolution.y;
    float2 size = u.resolution;

    // Independent slow wander keeps the field self-driven.
    float scale = 1.3 + (wander(u.time * 0.04, 0.0) - 0.5) * 2.0 * 0.3;
    // Bass breathes the wheel scale on top of the wander.
    scale = audio_gain(scale, audio_band(u.bands[0]), 0.2);
    float density = 1.95 + (wander(u.time * 0.04, 1.7) - 0.5) * 2.0 * 0.75;
    // Low-mid packs the panels tighter, so presence in the mix reads as a
    // fuller wheel rather than a faster one.
    density = audio_gain(density, audio_band(u.bands[1]), 0.25);
    float angle1 = 0.2 + (wander(u.time * 0.04, 3.3) - 0.5) * 2.0 * 0.4;
    // A beat snaps the edge skew, a brief geometry punch on every hit.
    angle1 = audio_offset(angle1, audio_pulse(u.beat), 0.15);
    float angle2 = -0.2 + (wander(u.time * 0.04, 5.9) - 0.5) * 2.0 * 0.4;
    float fadeIn = 0.6 + (wander(u.time * 0.04, 8.1) - 0.5) * 2.0 * 0.25;
    float fadeOut = 0.7 + (wander(u.time * 0.04, 10.7) - 0.5) * 2.0 * 0.2;
    const float panelLength = 1.0;
    const float blur = 0.06;
    const float gradient = 0.5;
    const bool edges = true;

    const float TWO_PI = 6.28318530718;
    const float PI = 3.14159265358979;

    float maxDim = max(max(size.x, size.y), 1.0);
    float2 uv = (position - 0.5 * size) / (0.5 * maxDim);
    uv /= max(scale, 0.001);
    uv *= 1.25;

    // Additive phase flow: amp = base / (0.05 * 8.0) keeps velocity positive; no reversal.
    float t = 0.02 * (u.time * 0.9 + wander(u.time * 0.05, 13.3) * 2.25);
    t = fract(t);
    bool reverseTime = (t < 0.5);

    float3 color   = float3(0.0);
    float  opacity = 0.0;

    float aa = 0.005 / max(scale, 0.001);

    // The host palette as the panel set. Five keeps the cycle coherent at the
    // original's 20-panel count.
    float3 cs[5] = {
        u.paletteSecondary.rgb,
        u.palettePrimary.rgb,
        mix(u.paletteSecondary.rgb, u.palettePrimary.rgb, 0.5),
        u.paletteAccent.rgb,
        mix(u.palettePrimary.rgb, u.paletteAccent.rgb, 0.5),
    };
    int colorsCount = 5;

    float invLength = 1.5 / max(panelLength, 0.001);

    int panelsNumber = 20;
    float densityNormalizer = 1.67;
    float fPanelsNumber = float(panelsNumber);
    float panelGrad = 1.0 - clamp(gradient, 0.0, 1.0);

    for (int set = 0; set < 2; set++) {
        bool isForward = (set == 0 && !reverseTime) || (set == 1 && reverseTime);
        if (!isForward) continue;

        // Forward-rotating panels.
        for (int i = 0; i <= 20; i++) {
            if (i >= panelsNumber) break;
            int   idx    = panelsNumber - 1 - i;
            float offset = float(idx) / fPanelsNumber;
            if (set == 1) offset += 0.5;

            float densityFract = densityNormalizer * fract(t + offset);
            float angleNorm    = densityFract / max(density, 0.001);
            if (densityFract >= 0.5 || angleNorm >= 0.3) continue;

            float smoothDensity = clamp((0.5 - densityFract) / 0.1, 0.0, 1.0) *
                                  clamp(densityFract / 0.01, 0.0, 1.0);
            float smoothAngle   = clamp((0.3 - angleNorm) / 0.05, 0.0, 1.0);
            if (smoothDensity * smoothAngle < 0.001) continue;

            if (angleNorm > 0.5) angleNorm = 0.5;

            float2 panel = colorPanelsGetPanel(angleNorm * TWO_PI + PI, uv,
                                               invLength, aa, angle1, angle2,
                                               blur, scale, edges);
            if (panel.x <= 0.001) continue;

            float panelMask = panel.x * smoothDensity * smoothAngle;
            float panelMap  = panel.y;

            int colorIdx     = idx % colorsCount;
            int nextColorIdx = (idx + 1) % colorsCount;
            float4 colorA = float4(cs[colorIdx], 1.0);
            float4 colorB = float4(cs[nextColorIdx], 1.0);

            colorA = mix(colorA, colorB,
                         max(0.0, smoothstep(0.0, 0.45, panelMap) - panelGrad));
            float4 blended = colorPanelsBlendColor(colorA, panelMask, panelMap,
                                                    fadeIn, fadeOut);
            color   = blended.rgb + color * (1.0 - blended.a);
            opacity = blended.a   + opacity * (1.0 - blended.a);
        }

        // Reverse-rotating panels (mirrored across the axis).
        for (int i = 0; i <= 20; i++) {
            if (i >= panelsNumber) break;
            int   idx    = panelsNumber - 1 - i;
            float offset = float(idx) / fPanelsNumber;
            if (set == 0) offset += 0.5;

            float densityFract = densityNormalizer * fract(-t + offset);
            float angleNorm    = -densityFract / max(density, 0.001);
            if (densityFract >= 0.5 || angleNorm < -0.3) continue;

            float smoothDensity = clamp((0.5 - densityFract) / 0.1, 0.0, 1.0) *
                                  clamp(densityFract / 0.01, 0.0, 1.0);
            float smoothAngle   = clamp((angleNorm + 0.3) / 0.05, 0.0, 1.0);
            if (smoothDensity * smoothAngle < 0.001) continue;

            float2 panel = colorPanelsGetPanel(angleNorm * TWO_PI + PI, uv,
                                               invLength, aa, angle1, angle2,
                                               blur, scale, edges);
            float panelMask = panel.x * smoothDensity * smoothAngle;
            if (panelMask <= 0.001) continue;
            float panelMap = panel.y;

            int colorIdx     = (colorsCount - (idx % colorsCount)) % colorsCount;
            if (colorIdx < 0) colorIdx += colorsCount;
            int nextColorIdx = (colorIdx + 1) % colorsCount;

            float4 colorA = float4(cs[colorIdx], 1.0);
            float4 colorB = float4(cs[nextColorIdx], 1.0);
            colorA = mix(colorA, colorB,
                         max(0.0, smoothstep(0.0, 0.45, panelMap) - panelGrad));
            float4 blended = colorPanelsBlendColor(colorA, panelMask, panelMap,
                                                    fadeIn, fadeOut);
            color   = blended.rgb + color * (1.0 - blended.a);
            opacity = blended.a   + opacity * (1.0 - blended.a);
        }
    }

    float3 bgRGB = u.paletteBackground.rgb;
    // Loudness swells the composite; silence leaves the panels at full strength.
    color *= audio_glow(1.0, audio_energy(u.loudness), 0.5);
    color = color + bgRGB * (1.0 - saturate(opacity));

    // Sub-pixel dither against banding.
    float dither = fract(sin(dot(0.014 * position,
                                 float2(12.9898, 78.233))) * 43758.5453123) - 0.5;
    color += float3(dither / 256.0);

    color = audio_bands_color(color, u.low, u.mid, u.high);
    color = audio_fire(color, u.beat, 0.5);
    return float4(color, 1.0);
}
