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
//  Self-driven wander eases ring count, width, channel separation, scale,
//  pattern modulation and the origin excursion. Rotation and phase rates
//  stay positive. The three channel colours come from the palette.
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

    // Independent slow wander keeps the field self-driven.
    // The ring phase creeps (a full out-and-back takes ~15–20s), so the field
    // evolves continuously instead of visibly cycling.
    float lines = 8.0 + (wander(u.time * 0.04, 0.0) - 0.5) * 2.0 * 1.0;
    // Bass adds rings on top of the wander, so a loud low end reads as a
    // denser field rather than a faster one.
    lines = audio_gain(lines, audio_band(u.bands[0]), 0.25);
    float lineWidth = 0.0033 + (wander(u.time * 0.04, 1.7) - 0.5) * 2.0 * 0.0008;
    // Air band thickens the strokes; kept tiny because the base width is too.
    lineWidth = audio_offset(lineWidth, audio_band(u.bands[3]), 0.0012);
    float channelOffset = 0.0225 + (wander(u.time * 0.04, 3.3) - 0.5) * 2.0 * 0.0075;
    // The three channels start almost on top of each other at the shipped
    // 0.0225 offset, so their colours add up to white-ish grey instead of
    // staying separate. Widening the split keeps the palette's colours —
    // macaron rings — legible against each other instead of merging.
    channelOffset = 0.09 + channelOffset * 0.25;
    // Additive phase flow: amp = base / (0.05 * 8.0) keeps velocity positive; no reversal.
    float rotation = 0.05 * (u.time * 0.7 + wander(u.time * 0.05, 5.9) * 1.75);
    float scale = 1.025 + (wander(u.time * 0.04, 8.1) - 0.5) * 2.0 * 0.025;
    // A beat punches the field scale briefly, on top of the slow wander.
    scale = audio_gain(scale, audio_pulse(u.beat), 0.12);
    // How far a ring travels from the origin before it turns back. The field
    // spans roughly ±1, so a span well past 1 lets rings cross it fully.
    float spacing = 1.7;
    float patternMod = 0.4 + (wander(u.time * 0.04, 13.3) - 0.5) * 2.0 * 0.05;

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
    // and never jumps; slow wander eases how far the light roams.
    float2 samplePoint = float2(u.time * 0.08, u.time * 0.05);
    float2 origin = float2(fbm(samplePoint + float2(3.7, 1.2)),
                           fbm(samplePoint + float2(91.2, 47.3)));
    origin = (origin - 0.5) * 2.0 * (0.29 + (wander(u.time * 0.04, 17.9) - 0.5) * 2.0 * 0.05);
    uv -= origin;

    // Additive phase flow: amp = base / (0.05 * 8.0) keeps velocity positive; no reversal.
    float t = u.time * 0.06 + wander(u.time * 0.05, 10.7) * 0.15;
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
    // cap keeps the field as an ambience rather than a glare. Loudness eases
    // that cap up, so a fuller mix glows brighter without ever clipping.
    //
    // Desaturation here is not repaired with a saturation boost: rgb2hsv's hue
    // is unstable on a near-grey result, so forcing saturation back in invents
    // a random hue (which read as “weird colour”). The macaron character has
    // to live in the palette itself, not in a post pass.
    col = col / (1.0 + col);
    col *= audio_glow(0.85, audio_energy(u.loudness), 0.5);

    float3 bg = u.paletteBackground.rgb;
    col = audio_bands_color(col, u.low, u.mid, u.high);
    col = audio_fire(col, u.beat, 0.5);
    return float4(bg + col, 1.0);
}
