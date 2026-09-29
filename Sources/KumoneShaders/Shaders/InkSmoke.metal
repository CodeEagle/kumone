//
//  InkSmoke.metal
//
//  Ported from ShipSwift's `SWInkSmoke.metal` (github.com/signerlabs/ShipSwift,
//  MIT — see ACKNOWLEDGEMENTS).
//
//  Domain-warped fbm "ink in water" smoke field. Three noise layers build the
//  body: `q` warps `p`, `r2` warps it again with `q` as the offset, and `f` is
//  a final fbm sampled at the double-warped point. Four ink colors are mixed
//  by `f`, `q.x` and `r2.y`, then a wispy highlight is added where `f` peaks.
//
//  Self-driven wander eases field scale, domain warp and wispy highlights.
//  The drift rate stays positive. The four inks are the host palette.
//

#include "KumoneShaderTypes.h"
using namespace metal;

static float inkSmokeHash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float inkSmokeVNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = inkSmokeHash21(i);
    float b = inkSmokeHash21(i + float2(1.0, 0.0));
    float c = inkSmokeHash21(i + float2(0.0, 1.0));
    float d = inkSmokeHash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// 5-octave fbm. Loop bound is static so the compiler unrolls it.
static float inkSmokeFBM(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * inkSmokeVNoise(p);
        p *= 2.0;
        a *= 0.5;
    }
    return v;
}

fragment float4 kumone_fragment_ink_smoke(Varying in [[stage_in]],
                                          constant Uniforms& u [[buffer(0)]]) {
    float2 position = in.uv * u.resolution.y;
    float2 size = u.resolution;

    // Independent slow wander keeps the field self-driven.
    float scale = 2.1 + (wander(u.time * 0.04, 0.0) - 0.5) * 2.0 * 0.9;
    // Beats briefly tighten the smoke field to give each hit a spatial punch.
    scale = audio_gain(scale, audio_pulse(u.beat), 0.15);
    float warp = 1.2 + (wander(u.time * 0.04, 1.7) - 0.5) * 2.0 * 0.7;
    // Bass deepens the domain warp so low notes curl the smoke.
    warp = audio_gain(warp, audio_band(u.bands[0]), 0.2);
    float highlight = 1.2 + (wander(u.time * 0.04, 5.9) - 0.5) * 2.0 * 0.7;
    // Loudness brightens only the wisps, keeping the palette background steady.
    highlight = audio_glow(highlight, audio_energy(u.loudness), 0.6);

    float2 uv = (position * 2.0 - size) / min(size.x, size.y);

    // Additive phase flow: amp = base / (0.05 * 8.0) keeps velocity positive; no reversal.
    float  t = 0.2 * (u.time * 0.75 + wander(u.time * 0.05, 3.3) * 1.875);
    float2 p = uv * max(scale, 0.0001);

    // Two-stage domain warp.
    float2 q  = float2(inkSmokeFBM(p + float2(t * 0.4, t * 0.3)),
                       inkSmokeFBM(p + float2(t * 0.2, -t * 0.4)));
    float2 r2 = float2(inkSmokeFBM(p + q * warp + float2(1.7, 9.2) + t * 0.15),
                       inkSmokeFBM(p + q * warp + float2(8.3, 2.8) - t * 0.1));
    float  f  = inkSmokeFBM(p + r2 * 2.0);

    float3 c1 = u.paletteBackground.rgb;
    float3 c2 = u.paletteSecondary.rgb;
    float3 c3 = u.palettePrimary.rgb;
    float3 c4 = mix(u.palettePrimary.rgb, u.paletteAccent.rgb, 0.5);
    float3 g  = u.paletteAccent.rgb;

    float3 col = mix(c1, c2, clamp(f * 2.0, 0.0, 1.0));
    col        = mix(col, c3, clamp(q.x * 1.5, 0.0, 1.0));
    col        = mix(col, c4, clamp(r2.y * 0.8, 0.0, 1.0));

    // Wispy highlights where the double-warped field peaks.
    float wisp = pow(clamp(f * 1.5, 0.0, 1.0), 3.0);
    col       += g * wisp * highlight;

    return float4(col, 1.0);
}
