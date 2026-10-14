import Metal
import MetalPerformanceShaders

/// Blurs the existing shader frame and composites only the marked regions.
/// No tint or opacity is added; a uniform white input stays white.
@MainActor
final class ShaderRegionBlur {
    private let device: any MTLDevice
    private let gaussian: MPSImageGaussianBlur
    private let pipeline: any MTLRenderPipelineState
    private var original: (any MTLTexture)?
    private var blurred: (any MTLTexture)?

    init(device: any MTLDevice) throws {
        self.device = device
        gaussian = MPSImageGaussianBlur(device: device, sigma: 12)
        gaussian.edgeMode = .clamp
        let library = try device.makeLibrary(source: Self.source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "region_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "region_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    func renderTarget(width: Int, height: Int) -> (any MTLTexture)? {
        if original?.width != width || original?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
                width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            original = device.makeTexture(descriptor: descriptor)
            descriptor.pixelFormat = .rgba16Float
            descriptor.usage = [.shaderRead, .shaderWrite]
            blurred = device.makeTexture(descriptor: descriptor)
        }
        return original
    }

    func composite(command: any MTLCommandBuffer, destination: MTLRenderPassDescriptor,
                   regions: [SIMD4<Float>], feathers: [SIMD2<Float>] = []) {
        guard let original, let blurred else { return }
        gaussian.encode(commandBuffer: command, sourceTexture: original, destinationTexture: blurred)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: destination) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(original, index: 0)
        encoder.setFragmentTexture(blurred, index: 1)
        var count = UInt32(min(regions.count, 16))
        var rects = Array(regions.prefix(16))
        encoder.setFragmentBytes(&count, length: MemoryLayout<UInt32>.size, index: 0)
        rects.withUnsafeMutableBytes { bytes in
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 1)
        }
        let edgeWidths = (0..<Int(count)).map { index in
            index < feathers.count ? feathers[index] : SIMD2<Float>(0.12, 0.16)
        }
        edgeWidths.withUnsafeBytes { bytes in
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 2)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Out { float4 position [[position]]; float2 uv; };
    vertex Out region_vertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        return {float4(p * 2.0 - 1.0, 0, 1), float2(p.x, 1.0 - p.y)};
    }
    fragment float4 region_fragment(Out in [[stage_in]], texture2d<float> original [[texture(0)]],
        texture2d<float> blurred [[texture(1)]], constant uint &count [[buffer(0)]],
        constant float4 *rects [[buffer(1)]], constant float2 *feathers [[buffer(2)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float mask = 0;
        for (uint i = 0; i < count; ++i) {
            float2 q = (in.uv - rects[i].xy) / rects[i].zw;
            float2 edge = min(q, 1.0 - q);
            float2 fade = smoothstep(float2(0), feathers[i], edge);
            mask = max(mask, fade.x * fade.y);
        }
        return mix(original.sample(s, in.uv), blurred.sample(s, in.uv), mask);
    }
    """
}
