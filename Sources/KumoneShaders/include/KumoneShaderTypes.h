#include <metal_stdlib>
using namespace metal;

#pragma once

// MARK: - Host contract
//
// A custom shader is a single fragment function with this signature:
//
//     fragment float4 kumone_fragment(Varying in [[stage_in]],
//                                     constant Uniforms& u [[buffer(0)]]);
//
// The host supplies the full-screen vertex stage and every uniform; the shader
// only decides a color per pixel. `Varying.uv` is already aspect-corrected to
// the longest edge, so a shader written against a square travels correctly to
// a wide screen (centered, not stretched).

struct Uniforms {
    float   time;
    float2  resolution;
    float   bands[4];       // AudioSpectrum, 0...1, smoothed
    float   level;          // mean of the four bands
    float   low, mid, high; // derived from bands
    float   beat;           // derived envelope peak, 0...1
    float   loudness;       // derived slow RMS proxy, 0...1
    float   _pad;
    float4  palettePrimary;
    float4  paletteSecondary;
    float4  paletteAccent;
    float4  paletteBackground;
};

struct Varying {
    float4 position [[position]];
    float2 uv;
};


// MARK: - Common noise helpers
//
// `static inline` so each translation unit gets its own copy. Without that,
// linking every shader into one library reports `fbm` as a duplicate symbol.

static inline float hash21(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

static inline float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static inline float fbm(float2 p) {
    float v = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 4; ++i) {
        v += vnoise(p) * amp;
        p = p * 2.07 + float2(13.1, 9.7);
        amp *= 0.5;
    }
    return v;
}

// Self-driven wander: `fbm` read along a line that advances with `t`. The
// underlying value noise is smoothstep-interpolated, so a parameter keyed on
// this eases slowly between random levels — organic random motion that never
// reacts to the audio. `seed` offsets the sampling line so each parameter
// wanders independently of the others.
static inline float wander(float t, float seed) {
    return fbm(float2(t, seed));
}


// MARK: - Audio reactivity helpers
//
// The host derives these four slots from the playing PCM every frame:
//
//     u.bands[0..3]  per-band levels, already smoothed on the audio thread
//     u.level        mean of the four bands
//     u.beat         beat envelope, snaps up on a transient and decays
//     u.loudness     slow swell over the whole mix
//
// With PCM sync switched off the host feeds silence instead, so every helper
// below keeps working — the shader just runs on its own `wander` motion again.
// That is deliberate: a shader must never have to know whether audio is live.
//
// Three shapes of modulation, so audio rides on top of the shader's own motion
// instead of replacing it:
//
//     audio_gain(base, amount, k)    multiplicative — counts, scales, densities
//     audio_offset(base, amount, k)  additive — angles, positions, thicknesses
//     audio_shaped(...)               amount put through a musical curve first
//
// `k` is how far the audio may push that one parameter. Keep it small for
// structural values (0.1...0.3 reads as breathing) and larger for brightness or
// glow (0.5...1.5), where the ear forgives the movement.

// One band, lifted into a range where quiet music still moves. The high band
// sits far below the low one on real material, so an un-shaped read leaves the
// shimmer-driven parameters dead while the bass-driven ones twitch.
static inline float audio_band(float band) {
    return saturate(band * 1.45);
}

// The beat as a punch rather than a glow: squaring snaps the attack tighter so
// one hit reads as a single thump instead of a swell that never quite lands.
static inline float audio_pulse(float beat) {
    return saturate(beat * beat * 1.6);
}

// The slow swell, lifted so a modest mix reaches the top of its range.
static inline float audio_energy(float loudness) {
    return saturate(loudness * 1.7);
}

// Multiplicative modulation for counts, scales and densities.
static inline float audio_gain(float base, float amount, float k) {
    return base * (1.0 + amount * k);
}

// Additive modulation for angles, offsets and line widths.
static inline float audio_offset(float base, float amount, float k) {
    return base + amount * k;
}

// Brightness and glow: audio raises the light rather than moving the geometry,
// which is what a spectrum display does and what the eye reads as "reacting".
static inline float audio_glow(float base, float amount, float k) {
    return base + amount * k * 0.5;
}

// The kick: a beat punches the whole colour up for a frame or two. Unlike
// `audio_glow` (which rides the slow loudness sway), this is a sharp flash on
// top of whatever the shader already composed — the ease of the sway followed
// by the hit of the beat is what makes the rhythm legible. Additive on the
// final colour so a vivid palette stays vivid instead of washing grey.
static inline float3 beat_flash(float3 col, float beat, float k) {
    return col + col * audio_pulse(beat) * k;
}

// Standard fast RGB <-> HSV (hue 0...1, saturation 0...1, value 0...1) so the
// bands can shape colour directly: saturation, hue rotation and lightness are
// the three axes a visualizer actually wants, and every reference pipeline
// (WebAudio/shadertoy) maps bands into HSL/HSV rather than fighting RGB.
static inline float3 rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, 1.0 / 3.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + 1e-10)), d / (q.x + 1e-10), q.x);
}

static inline float3 hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, saturate(p - K.xxx), c.y);
}

// The kick as light, not geometry: a beat punches value and saturation up and
// pushes the colour slightly toward white (a touch of over-exposure, the way a
// camera flash reads on a lit stage). Replaces `beat_flash` where the flash
// alone still left the rhythm invisible in the palette.
static inline float3 audio_fire(float3 col, float beat, float k) {
    float punch = audio_pulse(beat);
    float3 hsv = rgb2hsv(col);
    hsv.z = saturate(hsv.z + punch * k * 0.7);
    hsv.y = saturate(hsv.y * (1.0 + punch * k * 0.4));
    float3 hot = mix(col, float3(1.0, 1.0, 1.0), punch * k * 0.25);
    return mix(hot, hsv2rgb(hsv), 0.5);
}

// The bands as colour: bass deepens saturation, mid nudges the hue around so
// the palette never sits frozen, treble lifts the light. This is the mapping
// every reference visualizer converges on (bass warm/structural, highs
// bright/shimmer) — the appkit shaders were feeding the bands to geometry
// alone, which read as "everything just zooms".
static inline float3 audio_bands_color(float3 col, float low, float mid, float high) {
    float3 hsv = rgb2hsv(col);
    hsv.y = saturate(hsv.y * (1.0 + audio_band(low) * 0.5));
    hsv.x = fract(hsv.x + audio_band(mid) * 0.06);
    hsv.z = saturate(hsv.z * (1.0 + audio_band(high) * 0.4));
    return hsv2rgb(hsv);
}
