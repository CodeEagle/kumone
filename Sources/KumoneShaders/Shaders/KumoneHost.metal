#include <metal_stdlib>
using namespace metal;

// The host's vertex stage. Noise helpers live in KumoneShaderTypes.h as
// `static inline` so every shader sees them without a link-time duplicate.

#include "KumoneShaderTypes.h"

vertex Varying kumone_vertex(uint vid [[vertex_id]],
                             constant Uniforms& u [[buffer(0)]]) {
    // Two triangles covering the viewport, generated in the shader so a shader
    // file needs no mesh buffers of its own.
    float2 positions[4] = {
        { -1, -1 }, {  1, -1 }, { -1,  1 }, {  1,  1 }
    };
    float2 p = positions[vid];

    float2 aspect = u.resolution / max(u.resolution.y, 1.0);
    Varying out;
    out.position = float4(p, 0, 1);
    // Map to the centered square, then correct the aspect on the long axis so a
    // shader written against a square travels to a wide screen centered, not
    // stretched.
    out.uv = (p * 0.5 + 0.5) * aspect;
    return out;
}
