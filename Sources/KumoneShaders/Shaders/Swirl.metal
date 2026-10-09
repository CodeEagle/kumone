// ShipSwift original algorithm and Swift initializer defaults. MIT; see ACKNOWLEDGEMENTS.
// Only the entry-point/coordinate adapter differs. No artwork, wander or PCM modulation.
#include "KumoneShaderTypes.h"
namespace OriginalSwirl {
//
//  SWSwirl.metal
//  ShipSwift
//
//  Swirl procedural background as a SwiftUI Metal `colorEffect`.
//
//  Algorithm: convert pixel position to polar coordinates, multiply
//  angle by `bandCount` and add time to spin; apply a radial twist via
//  `pow(length, -twist)` which bends straight sectoral bands into
//  spirals; fold to a triangular wave so each band has two edges;
//  optionally distort with simplex noise; mask out the very center;
//  finally map the resulting 0..1 shape value across 1...10 colors
//  with `fwidth()`-based anti-aliasing on each band boundary.
//


using namespace metal;

namespace SWSwirlImpl {
    constant float TWO_PI = 6.28318530718;

    inline float2 mod289_2(float2 x) {
        return x - floor(x * (1.0 / 289.0)) * 289.0;
    }
    inline float3 mod289_3(float3 x) {
        return x - floor(x * (1.0 / 289.0)) * 289.0;
    }
    inline float3 permute289(float3 x) {
        return mod289_3((x * 34.0 + 1.0) * x);
    }

    // 2D simplex noise (Ashima Arts, public domain).
    inline float snoise(float2 v) {
        const float4 C = float4( 0.211324865405187,
                                  0.366025403784439,
                                 -0.577350269189626,
                                  0.024390243902439);
        float2 i  = floor(v + dot(v, C.yy));
        float2 x0 = v - i + dot(i, C.xx);
        float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
        float4 x12 = x0.xyxy + C.xxzz;
        x12.xy -= i1;
        i = mod289_2(i);
        float3 p = permute289(permute289(i.y + float3(0.0, i1.y, 1.0))
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

    inline half4 pickColor(int i,
                           half4 c0, half4 c1, half4 c2, half4 c3, half4 c4,
                           half4 c5, half4 c6, half4 c7, half4 c8, half4 c9) {
        switch (i) {
            case 0: return c0;
            case 1: return c1;
            case 2: return c2;
            case 3: return c3;
            case 4: return c4;
            case 5: return c5;
            case 6: return c6;
            case 7: return c7;
            case 8: return c8;
            default: return c9;
        }
    }
}

// Swirl procedural background.
//
// Parameters:
//   - position       : pixel position (`SwiftUI::Layer`-relative).
//   - currentColor   : source color from `.colorEffect` (unused).
//   - boundingRect   : `(x, y, w, h)` of the view's bounding rect.
//   - time           : seconds since the renderer started.
//   - scale          : overall zoom (smaller = swirl fills more).
//   - colorsCountF   : number of active palette entries, 1...10.
//   - bandCount      : number of color bands, 0 = concentric ripples, 0...15.
//   - twist          : vortex power, 0 = straight sectoral shapes, 0...1.
//   - center         : how far from the center the colors begin, 0...1.
//   - proportion     : blend point between colors, 0.5 = equal, 0...1.
//   - softness       : color transition sharpness, 0 = hard, 1 = smooth.
//   - noise          : strength of noise distortion, 0...1.
//   - noiseFrequency : noise frequency, 0...1.
//   - colorBack      : background color.
//   - c0...c9        : up to 10 swirl band colors.
static inline half4 swSwirl(
    float2 position,
    half4  currentColor,
    float4 boundingRect,
    float  time,
    float  scale,
    float  colorsCountF,
    float  bandCount,
    float  twistRaw,
    float  center,
    float  proportion,
    float  softness,
    float  noiseStrength,
    float  noiseFrequency,
    half4  colorBack,
    half4  c0, half4 c1, half4 c2, half4 c3, half4 c4,
    half4  c5, half4 c6, half4 c7, half4 c8, half4 c9
) {
    using namespace SWSwirlImpl;

    float2 size   = boundingRect.zw;
    float  maxDim = max(max(size.x, size.y), 1.0);

    // Object UV: centered, normalized so the swirl fills the longest edge.
    float2 uv = (position - 0.5 * size) / (0.5 * maxDim);
    uv /= max(scale, 0.001);

    float t = time;

    float l = max(1e-4, length(uv));

    float angle = ceil(bandCount) * atan2(uv.y, uv.x) + t;
    float angleNorm = angle / TWO_PI;

    float twist  = 3.0 * clamp(twistRaw, 0.0, 1.0);
    float offset = pow(l, -twist) + angleNorm;

    // Triangular wave so each band has two symmetric edges.
    float shape = fract(offset);
    shape = 1.0 - abs(2.0 * shape - 1.0);

    // Optional simplex distortion.
    shape += noiseStrength *
             snoise(15.0 * pow(noiseFrequency, 2.0) * uv);

    // Mask out a tiny disc at the origin (the `atan2(0,0)` singularity).
    // Hard-coding 0.2 here would leave a visible black hole; we shrink
    // it to 0.005 so the swirl fills every visible pixel.
    float lPosTwist = pow(l, twist);
    float holeCutoff = 0.005;
    float mid = smoothstep(holeCutoff, holeCutoff + 0.8 * center, lPosTwist);
    shape = mix(0.0, shape, mid);

    // `proportion` warps the gradient distribution between colors.
    float p = clamp(proportion, 0.0, 1.0);
    float exponent = mix(0.25, 1.0, p * 2.0);
    exponent = mix(exponent, 10.0, max(0.0, p * 2.0 - 1.0));
    shape = pow(max(shape, 0.0), exponent);

    // Map `shape` across the palette.
    int colorsCount = clamp(int(colorsCountF), 1, 10);
    float mixer = shape * float(colorsCount);

    half4 gradient = c0;
    gradient.rgb *= gradient.a;

    float outerShape = 0.0;
    for (int i = 1; i <= 10; i++) {
        if (i > colorsCount) break;
        float m = clamp(mixer - float(i - 1), 0.0, 1.0);
        float aa = fwidth(m);
        m = smoothstep(0.5 - 0.5 * softness - aa,
                       0.5 + 0.5 * softness + aa, m);
        if (i == 1) outerShape = m;

        half4 c = pickColor(i - 1, c0, c1, c2, c3, c4, c5, c6, c7, c8, c9);
        c.rgb *= c.a;
        gradient = mix(gradient, c, half(m));
    }

    // Smoothly fade out the outermost band against the tiny center disc.
    float midAA    = 0.1 * fwidth(pow(l, -twist));
    float outerMid = smoothstep(holeCutoff, holeCutoff + midAA, lPosTwist);
    outerShape    *= outerMid;

    float3 color   = float3(gradient.rgb) * outerShape;
    float  opacity = float(gradient.a)    * outerShape;

    float3 bgRGB = float3(colorBack.rgb) * float(colorBack.a);
    color   = color + bgRGB * (1.0 - opacity);
    opacity = opacity + float(colorBack.a) * (1.0 - opacity);

    // Sub-pixel dither against banding.
    float dither = fract(sin(dot(0.014 * position,
                                 float2(12.9898, 78.233))) * 43758.5453123) - 0.5;
    color += float3(dither / 256.0);

    return half4(half3(color), half(opacity));
}

static inline half4 originalColor(float r, float g, float b) {
    // Original SwiftUI default (.nonLinear) working space, dark appearance.
    return half4(r, g, b, 1.0h);
}
}

fragment float4 kumone_fragment_swirl(Varying in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    using namespace OriginalSwirl;
    // Host UV is measured in height units. SwiftUI position has a top-left origin.
    float2 position = float2(in.uv.x * u.resolution.y, u.resolution.y - in.uv.y * u.resolution.y);
    half4 original = swSwirl(position, half4(1.0h), float4(0.0, 0.0, u.resolution), u.time,
        1.00000000,
        4.00000000,
        6.00000000,
        0.20000000,
        0.20000000,
        0.50000000,
        0.00000000,
        0.20000000,
        0.40000000,
        originalColor(0.04000000, 0.06000000, 0.10000000),
        originalColor(0.95000000, 0.30000000, 0.70000000),
        originalColor(0.30000000, 0.40000000, 0.95000000),
        originalColor(0.30000000, 0.85000000, 0.95000000),
        originalColor(1.00000000, 1.00000000, 1.00000000),
        originalColor(1.00000000, 1.00000000, 1.00000000),
        originalColor(1.00000000, 1.00000000, 1.00000000),
        originalColor(1.00000000, 1.00000000, 1.00000000),
        originalColor(1.00000000, 1.00000000, 1.00000000),
        originalColor(1.00000000, 1.00000000, 1.00000000),
        originalColor(1.00000000, 1.00000000, 1.00000000));
    // Encode only once: preserve the original nonlinear math, then adapt to
    // the host's sRGB drawable (which expects linear fragment output).
    float3 c = saturate(float3(original.rgb));
    float3 linear = select(pow((c + 0.055) / 1.055, float3(2.4)), c / 12.92, c <= 0.04045);
    return float4(linear, original.a);
}
