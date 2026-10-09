# Acknowledgements

## Bundled visualizers

The bundled shaders in `Sources/KumoneShaders/Shaders/` are derived from
[ShipSwift](https://github.com/signerlabs/ShipSwift)
by SignerLabs, used under the MIT license below.

Each port keeps the original algorithm and retargets it to kumone's fragment
stage. Algorithms and initializer defaults are restored from the supplied
ShipSwift SWMetal source: fixed original colors, parameters and independent
time-driven animation, including while playback is paused. Bundled presets do
not use PCM, artwork palettes, parameter wander or beat-spawned copies.
Imported shaders keep the host's audio and artwork uniforms.
Named SwiftUI colors are resolved for the app's dark appearance. Original
nonlinear color math is preserved; only the final output is decoded to linear
RGB for the host's sRGB drawable, avoiding double gamma conversion.

Run `swift Scripts/check-original-shaders.swift /path/to/ShipSwift/SWMetal`
to audit algorithm parity, compile all eleven presets and verify that PCM and
artwork inputs cannot change their output.

The bundled visualizers are the ShipSwift presets the project ships. ShipSwift's
"Dot Sphere" is Canvas-rendered rather than a `.metal` file and cannot travel to
this pipeline, so `DotShape.metal` stands in for it (the `plasma` style of the
SWDots family).

| kumone shader | ShipSwift source |
|---|---|
| `AnimatedLoop.metal` — Animated_loop | `SWAnimatedLoop.metal` (`Shape` style, fixed to the circle metric) |
| `ColorPanels.metal` — Color_panels | `SWColorPanels.metal` |
| `DotOrbit.metal` — Dot_orbit | `SWDotOrbit.metal` |
| `DotShape.metal` — Dot_shape | `SWDotsPlasma.metal` (stands in for the Canvas-only "Dot Sphere") |
| `InkSmoke.metal` — Ink_smoke | `SWInkSmoke.metal` |
| `Metaballs.metal` — Metaballs | `SWMetaballs.metal` |
| `NeuroNoise.metal` — Neuro_noise | `SWNeuroNoise.metal` |
| `SimplexNoise.metal` — Simplex_noise | `SWSimplexNoise.metal` |
| `SmokeRing.metal` — Smoke_ring | `SWSmokeRing.metal` |
| `Swirl.metal` — Swirl | `SWSwirl.metal` |
| `Voronoi.metal` | `SWVoronoi.metal` |

`SimplexNoise.metal` and `Swirl.metal` embed Ashima Arts'
2D simplex noise (public domain), carried over from their ShipSwift sources.

---

    MIT License

    Copyright (c) 2026 SignerLabs

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
