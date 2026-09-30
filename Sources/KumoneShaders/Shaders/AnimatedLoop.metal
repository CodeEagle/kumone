//
//  AnimatedLoop.metal
//
//  Ripple pool: concentric waves expand from the centre outwards, forever.
//  Each wave is born bright and narrow at the centre, widens and dims as it
//  travels, and dissolves at the rim — the water-drop ring field the original
//  ShipSwift recipe tends toward, made explicit.
//
//  A beat does two things, which is what makes the rhythm legible as water
//  rather than as a metronome:
//   - it flashes the existing waves (the pool flinches when it is hit), and
//   - it births one fresh ring at the very centre, pure white, which then
//     rides the beat envelope outward and fades with it. Every kick reads as
//     an extra wave appearing out of nowhere.
//
//  Colours come from the artwork palette, cycled across the waves; the
//  beat-born ring stays white because it is a flash of energy, not a colour.
//

#include "KumoneShaderTypes.h"
using namespace metal;

fragment float4 kumone_fragment_animated_loop(Varying in [[stage_in]],
                                              constant Uniforms& u [[buffer(0)]]) {
    // The pool. Wave count, outward speed, reach and stroke width.
    constexpr int   RINGS  = 6;
    constexpr float SPEED  = 0.075;   // phase per second: how fast the field breathes
    constexpr float MAX_R  = 1.65;    // how far a wave travels before it dissolves
    constexpr float STROKE = 0.055;   // half-width of the soft band, in uv units

    float2 position = in.uv * u.resolution.y;
    float2 size = u.resolution;

    float2 uv = (position * 2.0 - size) / min(size.x, size.y);
    float d = length(uv);

    float3 ch[3] = { u.palettePrimary.rgb, u.paletteSecondary.rgb, u.paletteAccent.rgb };

    float beat   = audio_pulse(u.beat);
    float energy = audio_energy(u.loudness);

    float3 col = float3(0.0);

    // 1. The standing waves. Golden-ratio phase offsets spread the births
    //    evenly without a visible pattern, and per-wave speed drift keeps the
    //    field from ticking like a clock. Each wave brightens as it is born
    //    and fades as it nears the rim, where it also widens — a real ripple
    //    flattens as it runs out of energy.
    for (int k = 0; k < RINGS; k++) {
        float waveSpeed = SPEED * (0.8 + 0.4 * fract(float(k) * 0.37));
        float phase     = fract(u.time * waveSpeed + fract(float(k) * 0.618034));
        float r         = phase * MAX_R;

        float age   = phase;                       // 0 fresh at the centre, 1 at the rim
        float width = STROKE * (0.35 + 1.3 * age); // flattens as it expands
        // A soft band, not a laser line: full strength in the middle of the
        // stroke, feathered on both edges, dead outside.
        float band  = 1.0 - smoothstep(0.0, width, abs(d - r));
        float amp   = pow(1.0 - age, 1.25);        // dims with travel
        // The pool flinches on a hit: every standing wave flashes once.
        amp *= 1.0 + beat * 0.9;

        col += ch[k % 3] * band * amp;
    }

    // 2. The beat-born ring. It exists only while the beat envelope is alive:
    //    age runs backwards against the envelope, so beat = 1 plants it at the
    //    centre at full brightness, and as the envelope decays the ring flies
    //    outward and dims with it. The next hit births the next one — one
    //    extra wave per kick, exactly the "dropping another stone in" motion.
    float beatAge = 1.0 - u.beat;
    float rB      = beatAge * MAX_R * 0.9;
    float widthB  = STROKE * (0.5 + 1.4 * beatAge);
    float bandB   = 1.0 - smoothstep(0.0, widthB, abs(d - rB));
    // Never born at zero brightness: fades its way in and out, so the flash
    // is a ripple's slap rather than a strobe.
    float ampB    = u.beat * smoothstep(0.0, 0.2, u.beat);
    col += float3(1.0) * bandB * ampB * 1.35;

    // Everything bounded: the field stays an ambience behind the UI, and the
    // overall lift rides the slow loudness swell so a fuller mix glows.
    col = col / (1.0 + col);
    col *= 0.8 + energy * 0.35;
    col = beat_flash(col, u.beat, 0.25);

    float3 bg = u.paletteBackground.rgb;
    return float4(bg + col, 1.0);
}
