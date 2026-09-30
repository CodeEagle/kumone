//
//  AnimatedLoop.metal
//
//  Faithful port of ShipSwift's `SWAnimatedLoop.metal` (github.com/signerlabs/
//  ShipSwift, MIT — see ACKNOWLEDGEMENTS), `Shape` style fixed to its circle
//  distance metric.
//
//  Everything is the original recipe, including the parameter values, which
//  come from `SWAnimatedLoop`'s `.shape` numericDefaults
//  (speed 0.05, lineWidth 0.002, lines 5, spacing 5.0, channelOffset 0.01,
//  patternMod 0.2) with rotation 0, scale 1 and the origin centred.
//
//  The only adaptation is the host: ShipSwift exposes it as a stitchable
//  SwiftUI color effect with explicit colour parameters, this build drives it
//  full-screen through the app's `Uniforms`, so colour1/2/3 and the background
//  come from the artwork palette. No wander, no triangle phase, no soft
//  compression, no tonemap, no audio post — the earlier variants piled those
//  on and kept drifting further from the look; the arrow shapes (the slanted
//  slices the diagonal modulo carves out of every ring) read as white in the
//  original purely because the three channels add up at those pixels.
//

#include "KumoneShaderTypes.h"
using namespace metal;

fragment float4 kumone_fragment_animated_loop(Varying in [[stage_in]],
                                              constant Uniforms& u [[buffer(0)]]) {
    // ShipSwift `SWAnimatedLoop(style: .shape)` defaults.
    constexpr float SPEED          = 0.05;
    constexpr float LINE_WIDTH     = 0.002;
    constexpr int   LINES          = 5;
    constexpr float SPACING        = 5.0;
    constexpr float CHANNEL_OFFSET = 0.01;
    constexpr float PATTERN_MOD    = 0.2;
    constexpr float ROTATION       = 0.0;
    constexpr float SCALE          = 1.0;
    // Main field brightness. The original adds the three channels with no
    // compression, so where they overlap the sum shoots far past white and the
    // separate strokes merge into a glare — nothing reads as individual lines
    // any more. Scaling the whole sum back down keeps every ring and every
    // arrow stroke distinct.
    constexpr float DIM            = 0.22;
    // The beat layer: a second, complete copy of the same arrow pattern,
    // offset in phase and colour start so it never winks on top of the first,
    // appearing with each hit and fading out with the envelope. Not a push of
    // the main phase (that reads as the picture speeding up / zooming), but
    // one extra whole pattern on the beat.
    constexpr float BEAT_PHASE     = 0.37;
    constexpr float BEAT_WEIGHT    = 0.5;

    float2 position = in.uv * u.resolution.y;
    float2 size = u.resolution;

    float2 uv = (position * 2.0 - size) / min(size.x, size.y);
    uv = uv / max(SCALE, 0.0001);
    float c = cos(ROTATION);
    float s = sin(ROTATION);
    uv = float2(uv.x * c - uv.y * s, uv.x * s + uv.y * c);

    // Time alone drives the outward march, exactly as in the original.
    float t     = u.time * SPEED;
    int   count = max(1, LINES);

    float d = length(uv);                     // circle
    float pmm = max(PATTERN_MOD, 0.0001);
    float m   = fmod(uv.x + uv.y, pmm);

    float3 ch[3] = { u.palettePrimary.rgb, u.paletteSecondary.rgb, u.paletteAccent.rgb };

    // Main pattern: unchanged recipe, summed and then dimmed so the strokes
    // stay separate instead of blowing out.
    float3 col = float3(0.0);
    for (int j = 0; j < 3; j++) {
        float acc = 0.0;
        for (int i = 0; i < count; i++) {
            float f = fract(t - CHANNEL_OFFSET * float(j) + 0.01 * float(i)) * SPACING - d + m;
            acc += LINE_WIDTH * float(i * i) / max(abs(f), 0.00001);
        }
        col += ch[j] * acc;
    }
    col *= DIM;

    // The beat's own copy: same recipe with the phase shifted and the colour
    // rotation offset, so it lands as a visibly second set of arrows rather
    // than doubling the first into more glare. Its weight follows the beat
    // envelope — on with the hit, gone with its decay, one extra pattern per
    // kick.
    float3 beatCol = float3(0.0);
    float  tBeat   = t + BEAT_PHASE;
    for (int j = 0; j < 3; j++) {
        float acc = 0.0;
        for (int i = 0; i < count; i++) {
            float f = fract(tBeat - CHANNEL_OFFSET * float(j) + 0.01 * float(i)) * SPACING - d + m;
            acc += LINE_WIDTH * float(i * i) / max(abs(f), 0.00001);
        }
        beatCol += ch[(j + 1) % 3] * acc;
    }
    col += beatCol * BEAT_WEIGHT * audio_pulse(u.beat);

    float3 bg = u.paletteBackground.rgb;
    return float4(bg + col, 1.0);
}
