// ShipSwift original algorithm and Swift initializer defaults. MIT; see ACKNOWLEDGEMENTS.
// Only the entry-point/coordinate adapter differs. No artwork, wander or PCM modulation.
#include "KumoneShaderTypes.h"
namespace OriginalSmokeRing {
//
//  SWSmokeRing.metal
//  ShipSwift
//
//  Smoke-ring procedural background as a SwiftUI Metal `colorEffect`.
//
//  Algorithm: a polar-coordinate ring shape (`length(uv)` + `atan2`)
//  is distorted by two layers of value-noise FBM. The two layers are
//  phase-shifted in time and cross-faded so the smoke perpetually
//  re-rolls instead of looping visibly. The ring's radius, thickness
//  and inner-fill are user controls; the distorted shape mask drives
//  the alpha and a 1...10 color gradient.
//
//  Uses a procedural `hash21` so the shader is fully self-contained
//  (no sampler / no resource binding).
//


using namespace metal;

namespace SWSmokeRingImpl {
    constant float TWO_PI = 6.28318530718;
    constant float PI     = 3.14159265358979;

    inline float hash21(float2 p) {
        p = fract(p * float2(0.3183099, 0.3678794)) + 0.1;
        p += dot(p, p.yx + 19.19);
        return fract(p.x * p.y);
    }

    // `randomR` quantizes the input by /100 and wraps to keep the noise
    // tileable.
    inline float randomR(float2 p) {
        float2 uv = floor(p) / 100.0 + 0.5;
        return hash21(fract(uv));
    }

    inline float valueNoise(float2 st) {
        float2 i = floor(st);
        float2 f = fract(st);
        float a = randomR(i);
        float b = randomR(i + float2(1.0, 0.0));
        float c = randomR(i + float2(0.0, 1.0));
        float d = randomR(i + float2(1.0, 1.0));
        float2 u = f * f * (3.0 - 2.0 * f);
        float x1 = mix(a, b, u.x);
        float x2 = mix(c, d, u.x);
        return mix(x1, x2, u.y);
    }

    inline float2 fbm(float2 n0, float2 n1, int iterations) {
        float2 total = float2(0.0);
        float  amplitude = 0.4;
        for (int i = 0; i < 8; i++) {
            if (i >= iterations) break;
            total.x += valueNoise(n0) * amplitude;
            total.y += valueNoise(n1) * amplitude;
            n0 *= 1.99;
            n1 *= 1.99;
            amplitude *= 0.65;
        }
        return total;
    }

    inline float getNoise(float2 uv,
                          float2 pUv,
                          float  t,
                          float  noiseScale,
                          int    iterations)
    {
        float2 pUvLeft  = pUv + 0.03 * t;
        float  period   = max(abs(noiseScale * TWO_PI), 1e-6);
        float2 pUvRight = float2(fract(pUv.x / period) * period, pUv.y) + 0.03 * t;
        float2 n = fbm(pUvLeft, pUvRight, iterations);
        return mix(n.y, n.x, smoothstep(-0.25, 0.25, uv.x));
    }

    inline float getRingShape(float2 uv,
                              float radius,
                              float thickness,
                              float innerShape)
    {
        float d = length(uv);
        float ring = 1.0 - smoothstep(radius, radius + thickness, d);
        float inner = pow(innerShape, 3.0) * thickness;
        ring *= smoothstep(radius - inner, radius, d);
        return ring;
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

// Smoke-Ring procedural background.
//
// Parameters:
//   - position         : pixel position (`SwiftUI::Layer`-relative).
//   - currentColor     : source color from `.colorEffect` (unused).
//   - boundingRect     : `(x, y, w, h)` of the view's bounding rect.
//   - time             : seconds since the renderer started.
//   - scale            : overall zoom (smaller = ring fills more).
//   - colorsCountF     : number of active palette entries, 1...10.
//   - thickness        : ring thickness, 0.01...1.
//   - radius           : ring radius, 0...1.
//   - innerShape       : inner-fill amount, 0...4 (cubed before use).
//   - noiseScale       : noise frequency, 0.01...5.
//   - noiseIterationsF : FBM layer count, 1...8.
//   - colorBack        : background color.
//   - c0...c9          : up to 10 ring gradient colors.
static inline half4 swSmokeRing(
    float2 position,
    half4  currentColor,
    float4 boundingRect,
    float  time,
    float  scale,
    float  colorsCountF,
    float  thickness,
    float  radius,
    float  innerShape,
    float  noiseScale,
    float  noiseIterationsF,
    half4  colorBack,
    half4  c0, half4 c1, half4 c2, half4 c3, half4 c4,
    half4  c5, half4 c6, half4 c7, half4 c8, half4 c9
) {
    using namespace SWSmokeRingImpl;

    float2 size   = boundingRect.zw;
    float  maxDim = max(max(size.x, size.y), 1.0);

    // Centered, normalized so the ring fits the longest edge.
    float2 uv = (position - 0.5 * size) / (0.5 * maxDim);
    uv /= max(scale, 0.001);

    float t = time;

    // Two phase-shifted time loops + cross-fade weight so the smoke
    // never visibly repeats.
    float cycleDuration = 3.0;
    float timeBlend     = 0.5 + 0.5 * sin(0.1 * t * PI / cycleDuration - 0.5 * PI);

    float period2    = 2.0 * cycleDuration;
    float localTime1 = fract((0.1 * t + cycleDuration) / period2) * period2;
    float localTime2 = fract((0.1 * t) / period2) * period2;

    float atg = atan2(uv.y, uv.x) + 0.001;
    float l   = length(uv);
    float radialOffset = 0.5 * l - rsqrt(max(1e-4, l));

    float2 polar1 = float2(atg, localTime1 - radialOffset) * noiseScale;
    float2 polar2 = float2(atg, localTime2 - radialOffset) * noiseScale;

    int   iter   = clamp(int(noiseIterationsF), 1, 8);
    float noise1 = getNoise(uv, polar1, t, noiseScale, iter);
    float noise2 = getNoise(uv, polar2, t, noiseScale, iter);
    float noise  = mix(noise1, noise2, timeBlend);

    // Noise warps the polar UV so the ring's silhouette billows.
    float2 shapeUV = uv * (0.8 + 1.2 * noise);

    float ringShape = getRingShape(shapeUV, radius, thickness, innerShape);

    int colorsCount = clamp(int(colorsCountF), 1, 10);
    int idxLast = colorsCount - 1;

    float mixer = ringShape * ringShape * float(colorsCount - 1);

    half4 gradient = pickColor(idxLast,
                                c0, c1, c2, c3, c4, c5, c6, c7, c8, c9);
    gradient.rgb *= gradient.a;
    for (int i = 8; i >= 0; i--) {
        if (i >= idxLast) continue;
        float localT = clamp(mixer - float(idxLast - i - 1), 0.0, 1.0);
        half4 c = pickColor(i, c0, c1, c2, c3, c4, c5, c6, c7, c8, c9);
        c.rgb *= c.a;
        gradient = mix(gradient, c, half(localT));
    }

    float3 color   = float3(gradient.rgb) * ringShape;
    float  opacity = float(gradient.a) * ringShape;

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

fragment float4 kumone_fragment_smoke_ring(Varying in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    using namespace OriginalSmokeRing;
    // Host UV is measured in height units. SwiftUI position has a top-left origin.
    float2 position = float2(in.uv.x * u.resolution.y, u.resolution.y - in.uv.y * u.resolution.y);
    half4 original = swSmokeRing(position, half4(1.0h), float4(0.0, 0.0, u.resolution), u.time,
        0.80000000,
        2.00000000,
        0.40000000,
        0.40000000,
        1.00000000,
        2.80000000,
        8.00000000,
        originalColor(0.04000000, 0.02500000, 0.07000000),
        originalColor(1.00000000, 1.00000000, 1.00000000),
        originalColor(1.00000000, 1.00000000, 1.00000000),
        originalColor(1.00000000, 1.00000000, 1.00000000),
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
