//
//  StarNest.metal
//
//  Ported from ShipSwift's `SWStarNest.metal` (github.com/signerlabs/ShipSwift,
//  MIT — see ACKNOWLEDGEMENTS), itself adapted from "Star Nest" by Pablo
//  Roman Andrioli (Kali), https://www.shadertoy.com/view/XlfGRj, MIT.
//
//  A fully procedural deep-space nebula: a fixed camera flies through a
//  3D space-folded fractal field. Each pixel's ray is marched in volume
//  slices; at every slice the sample point is folded into a repeating tile
//  and run through the Star Nest "magic formula" `p = abs(p)/dot(p,p) -
//  formuparam`, accumulating fractal detail.
//
//  Ported, loudness sets the drift speed and the beat shifts the hue ramp.
//  Nothing zooms or pans the camera: every band-driven size change eases back
//  when the band does, and that reads as the field rewinding. The fly-through
//  is continuous and monotonic instead, and the brightness is held low because
//  the fractal accumulation is cubed before it tints anything.
//  Brightness follows the overall level.
//

#include "KumoneShaderTypes.h"
using namespace metal;

// GLSL `mod(x, y) = x - y * floor(x / y)` — the result takes the sign of y, so
// for positive y it is always non-negative, unlike Metal's `fmod`, which
// truncates toward zero and returns a negative result for negative inputs.
// Star Nest's camera origin has negative components, so the tiling fold MUST
// use this GLSL-semantics version or the nebula tears apart. Do not use fmod.
static float3 starNestMod(float3 x, float3 y) {
    return x - y * floor(x / y);
}

fragment float4 kumone_fragment_star_nest(Varying in [[stage_in]],
                                          constant Uniforms& u [[buffer(0)]]) {
    float2 position = in.uv * u.resolution.y;
    float2 size = u.resolution;

    // Star Nest fixed tuning constants, kept at their original values.
    const float formuparam = 0.53;
    const float stepsize   = 0.1;
    const float tile       = 0.850;

    // No zoom, no band-driven rescaling: anything that multiplies the field's
    // size eases back when the band does, and that reads as the animation
    // rewinding. The spin stays continuous and monotonic; the beat is the only
    // thing allowed to shake the field.
    float zoom = 0.5;
    float speed = 0.4 + u.loudness * 0.8;
    float brightness = 1.0 + 0.35 * u.level;

    float2 uv = position / size - 0.5;
    uv.y *= size.y / size.x;

    float3 dir = float3(uv * zoom, 1.0);

    float t = u.time * speed + 0.25;

    float a1 = 0.5;
    float a2 = 0.8;

    // GLSL `mat2(cos, sin, -sin, cos)` is column-major; Metal's
    // float2x2(col0, col1) matches it.
    float2x2 rot1 = float2x2(float2(cos(a1), sin(a1)), float2(-sin(a1), cos(a1)));
    float2x2 rot2 = float2x2(float2(cos(a2), sin(a2)), float2(-sin(a2), cos(a2)));

    float2 dxz = rot1 * float2(dir.x, dir.z);
    dir.x = dxz.x; dir.z = dxz.y;
    float2 dxy = rot2 * float2(dir.x, dir.y);
    dir.x = dxy.x; dir.y = dxy.y;

    float3 from = float3(1.0, 0.5, 0.5);
    from += float3(t * 2.0, t, -2.0);
    float2 fxz = rot1 * float2(from.x, from.z);
    from.x = fxz.x; from.z = fxz.y;
    float2 fxy = rot2 * float2(from.x, from.y);
    from.x = fxy.x; from.y = fxy.y;

    float s = 0.1;
    float fade = 1.0;
    float3 v = float3(0.0);

    // The inner accumulation is cubed before it tints anything, so the counts
    // stay at the original Shadertoy scale: a couple of extra iterations costs
    // far more brightness (and fill rate) than detail it returns.
    int vsteps = 12;
    int iters = 6;

    for (int r = 0; r < vsteps; r++) {
        float3 p = from + s * dir * 0.5;
        p = abs(float3(tile) - starNestMod(p, float3(tile * 2.0)));

        float pa = 0.0;
        float a  = 0.0;
        for (int i = 0; i < iters; i++) {
            p = abs(p) / max(dot(p, p), 1e-5) - formuparam;
            a += abs(length(p) - pa);
            pa = length(p);
        }

        float dm = max(0.0, 0.35 - a * a * 0.001);
        a *= a * a;
        if (r > 6) { fade *= 1.0 - dm; }

        v += fade;
        // Per-slice color: the (s, s^2, s^4) ramp tints near-to-far slices, so
        // depth reads as a hue shift across the nebula - the original's own
        // coloring, kept intact.
        v += float3(s, s * s, s * s * s * s) * a * brightness * fade;
        fade *= 0.75;
        s += stepsize;
    }

    float3 col = v * 0.01;
    // The cubed accumulation can still spike past 1 on a bright slice; bound
    // the highlights without flattening the hue, the same as the other ports.
    col = col / (1.0 + col);
    col *= 0.75;
    // A light palette wash keyed to brightness, so the nebula belongs to the
    // current artwork without flattening the depth ramp.
    float lum = clamp(dot(col, float3(0.333)) * 3.0, 0.0, 1.0);
    col += mix(u.paletteBackground.rgb, u.paletteAccent.rgb, lum) * lum * 0.16;

    return float4(col, 1.0);
}
