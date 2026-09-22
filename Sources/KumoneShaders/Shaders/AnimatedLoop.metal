//
//  AnimatedLoop.metal
//
//  Ported from ShipSwift's `SWAnimatedLoop.metal` (github.com/signerlabs/ShipSwift,
//  MIT — see ACKNOWLEDGEMENTS).
//
//  The `Shape` style of the SWAnimatedLoop family, fixed to its circle
//  distance metric: concentric phase-ramped rings split into three
//  colour channels and additively composited. The other three styles
//  (Diamond / Neon / Warp) share the same per-line ramp and channel split
//  and differ only in the distance metric; one entry point keeps the
//  picker readable.
//
//  Ported, the mid band sets how many rings the field carries, the beat
//  widens and brightens the lines, the highs offset the RGB channels
//  against each other, the low band rotates the whole field, and loudness
//  sets the drift speed. The three channel colours come from the palette.
//
//  The band levels themselves bounce frame to frame, so anything they
//  multiply heavily twitches: the field's sway is carried by the smoothed
//  `loudness` and `beat`, and the raw bands only texture it through small
//  multipliers. A slow continuous turn keeps the field drifting instead of
//  staring.
//
//  Three adjustments over the original, made so the effect can live behind
//  the now-playing page without drowning it:
//   - the ring phase is a triangle wave, not a sawtooth, so the loop closes
//     seamlessly instead of snapping back to the centre once a cycle;
//   - the ring origin wanders on fractal value noise, an aperiodic smooth
//     meander rather than a closed Lissajous, so the light never repeats its
//     path and never jumps;
//   - the additive composite goes through a Reinhard tonemap and an
//     intensity cap, so squared line weights can no longer clip to white
//     and wash out the controls on top.
//

#include "KumoneShaderTypes.h"
using namespace metal;

fragment float4 kumone_fragment_animated_loop(Varying in [[stage_in]],
                                              constant Uniforms& u [[buffer(0)]]) {
    float2 position = in.uv * u.resolution.y;
    float2 size = u.resolution;

    // Audio drives the field gently. The raw band levels bounce frame to
    // frame, so the sway is carried by the smoothed `loudness` and `beat` and
    // the bands only texture it — heavy multipliers on raw bands make the
    // whole field twitch instead of breathing.
    //
    // Everything is tuned to an ambient drift rather than a pulse: the ring
    // phase creeps (a full out-and-back takes ~15–20s, not ~3s), so the field
    // evolves continuously instead of visibly cycling.
    float lines = 7.0 + u.loudness * 2.0;
    float lineWidth = 0.0025 + u.beat * 0.0016;
    float channelOffset = 0.015 + u.high * 0.015;
    // A slow continuous turn keeps the field drifting; the low band nudges it,
    // never yanks it the way a full-turn multiplier would.
    float rotation = u.time * 0.04 + u.low * 0.10;
    float scale = 1.0 + u.loudness * 0.05;
    float speed = 0.035 + u.loudness * 0.045;
    // How far a ring travels from the origin before it turns back. The field
    // spans roughly ±1, so a span well past 1 lets rings cross it fully.
    float spacing = 1.7;
    float patternMod = 0.35 + u.mid * 0.1;

    float2 uv = (position * 2.0 - size) / min(size.x, size.y);
    uv = uv / max(scale, 0.0001);
    float c = cos(rotation);
    float s = sin(rotation);
    uv = float2(uv.x * c - uv.y * s, uv.x * s + uv.y * c);

    // The light's origin wanders on fractal value noise. The sample point
    // itself drifts diagonally through the noise field — sampling along a
    // fixed line would stop dead at every lattice crossing, and the light
    // would visibly pause once per cell — so the value keeps flowing, and the
    // two channels' offsets keep x and y independent. The path never repeats
    // and never jumps; loudness widens how far the light roams.
    float2 samplePoint = float2(u.time * 0.08, u.time * 0.05);
    float2 origin = float2(fbm(samplePoint + float2(3.7, 1.2)),
                           fbm(samplePoint + float2(91.2, 47.3)));
    origin = (origin - 0.5) * 2.0 * (0.24 + 0.10 * u.loudness);
    uv -= origin;

    float t = u.time * speed;
    int count = max(1, int(lines));

    float d = length(uv);
    float pmm = max(patternMod, 0.0001);
    float m = fmod(uv.x + uv.y, pmm);

    float3 ch[3] = { u.palettePrimary.rgb, u.paletteSecondary.rgb, u.paletteAccent.rgb };

    float3 col = float3(0.0);
    for (int j = 0; j < 3; j++) {
        float acc = 0.0;
        for (int i = 0; i < count; i++) {
            float phase = fract(t - channelOffset * float(j) + 0.01 * float(i));
            // A sawtooth phase makes every ring fly out to its span and snap
            // back to the centre — the whole field visibly resets once per
            // cycle. A triangle wave visits the same span and reverses through
            // zero velocity at both ends, so the loop closes seamlessly.
            phase = 1.0 - abs(phase - 0.5) * 2.0;
            float f = phase * spacing - d + m;
            acc += lineWidth * float(i * i) / max(abs(f), 0.00001);
        }
        col += ch[j] * acc;
    }

    // Squared line weights on three additive channels push the sum far past 1,
    // which clips to white and blows out the UI sitting on top of the backdrop.
    // Reinhard bounds the highlights while keeping the hue, and the intensity
    // cap keeps the field as an ambience rather than a glare.
    col = col / (1.0 + col);
    col *= 0.7;

    float3 bg = u.paletteBackground.rgb;
    return float4(bg + col, 1.0);
}
