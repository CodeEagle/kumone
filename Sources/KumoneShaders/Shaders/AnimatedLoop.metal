//
//  AnimatedLoop.metal
//
//  ShipSwift's `SWAnimatedLoop.metal` (github.com/signerlabs/ShipSwift, MIT —
//  see ACKNOWLEDGEMENTS), `Shape` style fixed to its circle distance metric,
//  adjusted in three ways:
//
//   - the field turns around the screen centre, slowly and without end;
//   - the strokes are wider (they read as upright card-shaped bands rather
//     than hairlines) and the whole sum is dimmed so the bands stay separate
//     instead of merging into a glare;
//   - a beat spawns another whole copy of the pattern: each copy is stamped
//     with the moment of its birth on the host side, appears at the centre
//     and marches outward on the same march as the standing pattern, keeps
//     going, never fades — several copies are alive at once, and with no
//     track playing no copy exists at all.
//

#include "KumoneShaderTypes.h"
using namespace metal;

fragment float4 kumone_fragment_animated_loop(Varying in [[stage_in]],
                                              constant Uniforms& u [[buffer(0)]]) {
    // ShipSwift `SWAnimatedLoop(style: .shape)` defaults, widened.
    constexpr float SPEED          = 0.05;
    constexpr float LINE_WIDTH     = 0.006;   // wider strokes -> card-shaped bands
    constexpr int   LINES          = 5;
    constexpr float SPACING        = 5.0;
    constexpr float CHANNEL_OFFSET = 0.01;
    constexpr float PATTERN_MOD    = 0.2;
    // Endless slow turn around the centre. ~0.02 rad/s is a full revolution
    // every five minutes: motion you feel, not motion you watch.
    constexpr float ROTATE_SPEED   = 0.02;
    constexpr float SCALE          = 1.0;
    // The standing pattern's scale: the raw sum runs far past white where the
    // channels overlap, and every band merges into a glare. Kept low, the
    // bands read as individual cards — which is the look at rest.
    constexpr float DIM            = 0.22;
    // Beat-spawned copies: same pattern, born at the centre, alive for good.
    // WEIGHT is deliberately faint, because copies accumulate — four of them
    // may be crossing the field at once, and the picture must not end up
    // brighter than the standing pattern alone.
    constexpr float COPY_WEIGHT    = 0.1;

    float2 position = in.uv * u.resolution.y;
    float2 size = u.resolution;

    // `uv` is already centred on the view, so this rotation is around the
    // screen centre. It runs forever in one direction; the rings fall outward
    // through the turning frame instead of sliding along a fixed axis.
    float2 uv = (position * 2.0 - size) / min(size.x, size.y);
    uv = uv / max(SCALE, 0.0001);
    float rotation = ROTATE_SPEED * u.time;
    float c = cos(rotation);
    float s = sin(rotation);
    uv = float2(uv.x * c - uv.y * s, uv.x * s + uv.y * c);

    float t     = u.time * SPEED;
    int   count = max(1, LINES);

    float d = length(uv);                     // circle
    float pmm = max(PATTERN_MOD, 0.0001);
    float m   = fmod(uv.x + uv.y, pmm);

    float3 ch[3] = { u.palettePrimary.rgb, u.paletteSecondary.rgb, u.paletteAccent.rgb };

    float3 col = float3(0.0);

    // The standing pattern: the original recipe, dimmed after the sum.
    for (int j = 0; j < 3; j++) {
        float acc = 0.0;
        for (int i = 0; i < count; i++) {
            float f = fract(t - CHANNEL_OFFSET * float(j) + 0.01 * float(i)) * SPACING - d + m;
            acc += LINE_WIDTH * float(i * i) / max(abs(f), 0.00001);
        }
        col += ch[j] * acc;
    }
    col *= DIM;

    // One copy per stamped beat. Its own clock starts at its birth time, so
    // phase 0 (the centre) is where it comes into being, and it expands
    // outward on the same march as the standing pattern — no fade, no
    // disappearance, no speed-up of anything else. Slots never born (-1) sit
    // the whole loop out, which is the quiet picture.
    for (int n = 0; n < 4; n++) {
        float born = u.time - u.beatBirthTs[n];
        if (born < 0.0) continue;
        float tCopy = born * SPEED;

        float3 copyCol = float3(0.0);
        for (int j = 0; j < 3; j++) {
            float acc = 0.0;
            for (int i = 0; i < count; i++) {
                float f = fract(tCopy - CHANNEL_OFFSET * float(j) + 0.01 * float(i)) * SPACING - d + m;
                acc += LINE_WIDTH * float(i * i) / max(abs(f), 0.00001);
            }
            // Colour rotation offset per copy so stacked copies read as
            // different sets, not a brighter copy of the same one.
            copyCol += ch[(j + n) % 3] * acc;
        }
        col += copyCol * COPY_WEIGHT;
    }

    float3 bg = u.paletteBackground.rgb;
    return float4(bg + col, 1.0);
}
