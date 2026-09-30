//
//  DotOrbit.metal
//
//  Ported from ShipSwift's `SWDotOrbit.metal` (github.com/signerlabs/ShipSwift,
//  MIT — see ACKNOWLEDGEMENTS).
//
//  Dots that each orbit around their own Voronoi-cell centre, coloured across
//  a step-discretized gradient. The per-cell randomizers are pure hash
//  functions, so no auxiliary texture has to be bound.
//
//  Self-driven wander eases grid scale, orbit width and dot size, with a
//  positive orbit rate. The host palette spans the original ten gradient slots.
//

#include "KumoneShaderTypes.h"
using namespace metal;

static float dotOrbitHash11(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static float2 dotOrbitHash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

static float2 dotOrbitRotate(float2 uv, float th) {
    float c = cos(th), s = sin(th);
    return float2(c * uv.x - s * uv.y, s * uv.x + c * uv.y);
}

/// 3x3 neighbour scan for the closest orbiting cell centre.
/// Returns (minDist, randomizer.x, randomizer.y).
static float3 dotOrbitVoronoi(float2 uv, float time, float spreading) {
    const float TWO_PI = 6.28318530718;
    float2 iuv = floor(uv);
    float2 fuv = fract(uv);

    float s = 0.25 * saturate(spreading);

    float minDist = 1.0;
    float2 randomizer = float2(0.0);
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 tileOffset = float2(float(x), float(y));
            float2 rnd = dotOrbitHash22(iuv + tileOffset);
            float2 center = float2(0.5 + 1e-4);
            center += s * cos(time + TWO_PI * rnd);
            center -= 0.5;
            center = dotOrbitRotate(center,
                                    dotOrbitHash11(float2(rnd.x, rnd.y)) + 0.1 * time);
            center += 0.5;
            float d = length(tileOffset + center - fuv);
            if (d < minDist) {
                minDist = d;
                randomizer = rnd;
            }
        }
    }
    return float3(minDist, randomizer);
}

/// The original's ten palette slots, stretched from the host's four colours.
static void dotOrbitPalette(constant Uniforms& u, thread float3 out[10]) {
    float3 bg  = u.paletteBackground.rgb;
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
    out[8] = mix(pri, bg, 0.5);
    out[9] = acc;
}

fragment float4 kumone_fragment_dot_orbit(Varying in [[stage_in]],
                                          constant Uniforms& u [[buffer(0)]]) {
    float2 position = in.uv * u.resolution.y;
    float2 size = u.resolution;

    // Independent slow wander keeps the field self-driven.
    float scale = 2.75 + (wander(u.time * 0.04, 0.0) - 0.5) * 2.0 * 1.25;
    // Bass opens the grid, so a heavy low end spreads the cells apart.
    scale = audio_gain(scale, audio_band(u.bands[0]), 0.2);
    float spreading = 0.8 + (wander(u.time * 0.04, 1.7) - 0.5) * 2.0 * 0.4;
    // Low-mid widens each orbit; the inner saturate() keeps the radius sane.
    spreading = audio_gain(spreading, audio_band(u.bands[1]), 0.3);
    float dotScale = 1.3 + (wander(u.time * 0.04, 3.3) - 0.5) * 2.0 * 0.7;
    // A beat punches the dot size, on top of the slow wander.
    dotScale = audio_gain(dotScale, audio_pulse(u.beat), 0.2);

    float minDim = max(min(size.x, size.y), 1.0);
    float2 uv = (position - 0.5 * size) / minDim;
    uv *= max(scale, 1e-4);

    const float firstFrameOffset = -10.0;
    // Additive phase flow: amp = base / (0.05 * 8.0) keeps velocity positive; no reversal.
    float t = u.time * 0.8 + wander(u.time * 0.05, 5.9) * 2.0 + firstFrameOffset;

    float3 voro = dotOrbitVoronoi(uv, t, spreading) + 1e-4;

    float radius = 0.25 * dotScale - 0.1 * voro.z;
    float dist = voro.x;
    float edgeWidth = fwidth(dist);
    float dots = 1.0 - smoothstep(radius - edgeWidth, radius + edgeWidth, dist);

    float3 colors[10];
    dotOrbitPalette(u, colors);
    int countI = 5;
    float countF = float(countI);
    float steps = 2.0;

    float shape = voro.y;
    float mixer = (shape - 0.5 / countF) * countF;

    float3 gradient = colors[0];
    for (int i = 1; i < 10; i++) {
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

    // Loudness swells the dots themselves, not the background, so the field
    // brightens with the mix while silence leaves it wandering on its own.
    float3 col = gradient * dots * audio_glow(1.0, audio_energy(u.loudness), 0.6);
    float3 bgRGB = u.paletteBackground.rgb;
    col = col + bgRGB * (1.0 - dots);

    col = beat_flash(col, u.beat, 0.35);
    return float4(col, 1.0);
}
