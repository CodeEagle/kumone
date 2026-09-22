//
//  Swirl.metal
//
//  Ported from ShipSwift's `SWSwirl.metal` (github.com/signerlabs/ShipSwift,
//  MIT — see ACKNOWLEDGEMENTS). The 2D simplex noise it uses for distortion is
//  Ashima Arts' implementation (public domain), carried over unchanged.
//
//  Pixel position becomes polar coordinates; the angle is multiplied by the
//  band count and spun by time; `pow(length, -twist)` bends straight sectoral
//  bands into spirals; the result folds to a triangular wave so each band has
//  two edges, then maps across up to ten colours with `fwidth()`-based
//  anti-aliasing at every boundary.
//
//  Ported, loudness sets the spin rate and the beat shakes the spiral — a
//  fast small jitter on the angle, plus simplex noise on the band edges. The
//  geometry itself (scale, band count, twist, centre radius) is fixed: every
//  band-driven size eases back when the band does, which reads as the spiral
//  unwinding, so only monotonic motion and the beat's trembling are allowed.
//  The palette is the host's four colours stretched across the original's
//  ten slots.
//

#include "KumoneShaderTypes.h"
using namespace metal;

static float2 swirlMod289_2(float2 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}
static float3 swirlMod289_3(float3 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}
static float3 swirlPermute289(float3 x) {
    return swirlMod289_3((x * 34.0 + 1.0) * x);
}

// 2D simplex noise (Ashima Arts, public domain).
static float swirlSNoise(float2 v) {
    const float4 C = float4(0.211324865405187,
                            0.366025403784439,
                            -0.577350269189626,
                            0.024390243902439);
    float2 i  = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = swirlMod289_2(i);
    float3 p = swirlPermute289(swirlPermute289(i.y + float3(0.0, i1.y, 1.0))
                               + i.x + float3(0.0, i1.x, 1.0));
    float3 m = max(0.5 - float3(dot(x0, x0),
                                 dot(x12.xy, x12.xy),
                                 dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;
    float3 x  = 2.0 * fract(p * C.www) - 1.0;
    float3 h  = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    float3 g;
    g.x  = a0.x  * x0.x  + h.x  * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

fragment float4 kumone_fragment_swirl(Varying in [[stage_in]],
                                      constant Uniforms& u [[buffer(0)]]) {
    float2 position = in.uv * u.resolution.y;
    float2 size = u.resolution;

    // The spiral's geometry is fixed. Anything the bands drove here — scale,
    // band count, twist, centre radius — eases back when the band does, and
    // that reads as the spiral unwinding or pumping, i.e. running in reverse.
    // The spin below is monotonic, so it can never rewind; the beat is the
    // only audio input allowed to move anything, and only to shake it.
    float scale = 1.0;
    float bandCount = 7.0;
    float twistRaw = 0.55;
    float center = 0.45;
    float noiseStrength = 0.5 * u.beat;
    const float noiseFrequency = 0.5;
    const float softness = 0.35;
    const float proportion = 0.5;

    const float TWO_PI = 6.28318530718;

    float maxDim = max(max(size.x, size.y), 1.0);
    float2 uv = (position - 0.5 * size) / (0.5 * maxDim);
    uv /= max(scale, 0.001);

    // Continuous spin: `t` only ever grows, so the spiral turns one way
    // forever. A firm base rate keeps it visibly advancing even when the music
    // is quiet — a slow spin reads as drifting, not turning — and loudness
    // rides the rate without ever reversing it.
    float t = u.time * (0.45 + u.loudness * 0.5);

    // An inward phase flow: a slow monotonic term on the band offset makes the
    // arms travel along the gradient instead of only rotating in place, so the
    // field reads as a vortex pulling inward. Monotonic, so it cannot rewind.
    float flow = u.time * 0.03;

    // The beat shakes the spiral: a fast, small, back-and-forth jitter on the
    // angle. The amplitude stays well under the per-frame spin, otherwise the
    // trembling swamps the rotation and the whole field reads as oscillating
    // in place rather than turning.
    float jitter = u.beat * sin(u.time * 15.0) * 0.18;

    float l = max(1e-4, length(uv));

    float angle = ceil(bandCount) * atan2(uv.y, uv.x) + t + jitter;
    float angleNorm = angle / TWO_PI;
    float twist  = 3.0 * clamp(twistRaw, 0.0, 1.0);
    float offset = pow(l, -twist) + angleNorm + flow;

    // Triangular wave so each band has two symmetric edges.
    float shape = fract(offset);
    shape = 1.0 - abs(2.0 * shape - 1.0);

    // Optional simplex distortion, driven by the beat.
    shape += noiseStrength * swirlSNoise(15.0 * pow(noiseFrequency, 2.0) * uv);

    // Mask out a tiny disc at the origin (the atan2(0,0) singularity).
    float lPosTwist = pow(l, twist);
    float holeCutoff = 0.005;
    float mid = smoothstep(holeCutoff, holeCutoff + 0.8 * center, lPosTwist);
    shape = mix(0.0, shape, mid);

    // `proportion` warps the gradient distribution between colours.
    float p = clamp(proportion, 0.0, 1.0);
    float exponent = mix(0.25, 1.0, p * 2.0);
    exponent = mix(exponent, 10.0, max(0.0, p * 2.0 - 1.0));
    shape = pow(max(shape, 0.0), exponent);

    // The host palette in the original's ten slots.
    float3 colors[10] = {
        u.paletteSecondary.rgb,
        u.palettePrimary.rgb,
        mix(u.paletteSecondary.rgb, u.palettePrimary.rgb, 0.5),
        u.paletteAccent.rgb,
        mix(u.palettePrimary.rgb, u.paletteAccent.rgb, 0.5),
        mix(u.paletteBackground.rgb, u.paletteSecondary.rgb, 0.5),
        u.palettePrimary.rgb,
        mix(u.paletteSecondary.rgb, u.paletteAccent.rgb, 0.5),
        mix(u.palettePrimary.rgb, u.paletteBackground.rgb, 0.5),
        u.paletteAccent.rgb,
    };
    int colorsCount = 6;
    float mixer = shape * float(colorsCount);

    float3 gradient = colors[0];
    float outerShape = 0.0;
    for (int i = 1; i <= 10; i++) {
        if (i > colorsCount) break;
        float m = clamp(mixer - float(i - 1), 0.0, 1.0);
        float aa = fwidth(m);
        m = smoothstep(0.5 - 0.5 * softness - aa,
                       0.5 + 0.5 * softness + aa, m);
        if (i == 1) outerShape = m;
        gradient = mix(gradient, colors[i - 1], m);
    }

    // Smoothly fade the outermost band against the tiny centre disc.
    float midAA    = 0.1 * fwidth(pow(l, -twist));
    float outerMid = smoothstep(holeCutoff, holeCutoff + midAA, lPosTwist);
    outerShape    *= outerMid;

    float3 color   = gradient * outerShape;
    float3 bgRGB = u.paletteBackground.rgb;
    color = color + bgRGB * (1.0 - outerShape);

    // Sub-pixel dither against banding.
    float dither = fract(sin(dot(0.014 * position,
                                 float2(12.9898, 78.233))) * 43758.5453123) - 0.5;
    color += float3(dither / 256.0);

    return float4(color, 1.0);
}
