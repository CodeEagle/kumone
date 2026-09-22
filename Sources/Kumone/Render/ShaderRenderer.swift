import Foundation
import Metal
import MetalKit
import simd

/// Draws a single shader full-screen.
///
/// The host (this class) owns the vertex stage, the uniform buffer, and the
/// per-frame bookkeeping. A shader contributes one fragment function and
/// nothing else, so loading a new one is a pipeline rebuild — no mesh, no
/// buffer juggling on the shader's side.
@MainActor
final class ShaderRenderer: NSObject, MTKViewDelegate {
    /// Provides band levels each frame. Defaulted to the shared spectrum; tests
    /// substitute their own sampler.
    var bandSampler: (Int) -> Float = { AudioSpectrum.shared.level(at: $0) }

    /// Whether the transport is playing, pushed in by the container. Liveness
    /// itself is re-derived every frame in `draw`.
    var isAudioPlaying = false

    var palette: ShaderPalette = .fallback

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue

    private var pipelineState: (any MTLRenderPipelineState)?
    private var currentDescriptor: ShaderDescriptor?
    private var uniformBuffer: any MTLBuffer?
    private let uniformStride: Int

    private var bridge = ShaderAudioBridge()
    private var startTime: CFTimeInterval = 0
    private var lastDrawableTime: CFTimeInterval = 0

    /// Set when a shader fails to build, so the host can show why instead of a
    /// black screen with no explanation.
    private(set) var lastError: String?

    init?(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) {
        guard let device else { return nil }
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        // Buffer-backed uniforms need 256-byte alignment for the constant
        // address space on some GPUs; round the stride up.
        let raw = MemoryLayout<ShaderUniforms>.stride
        self.uniformStride = ((raw + 255) / 256) * 256
        super.init()
    }

    // MARK: - Shader loading

    /// Compiles `descriptor` and rebuilds the pipeline. Returns false on failure
    /// and records `lastError`.
    @discardableResult
    func load(_ descriptor: ShaderDescriptor) -> Bool {
        guard let library = ShaderLibrary.shared.library(for: descriptor) else {
            lastError = "无法编译 shader：\(descriptor.name)"
            pipelineState = nil
            return false
        }

        let fragmentName = ShaderLibrary.shared.fragmentFunctionName(for: descriptor)
        guard let fragment = library.makeFunction(name: fragmentName) else {
            lastError = "shader \(descriptor.name) 缺少入口函数 \(fragmentName)"
            pipelineState = nil
            return false
        }

        // The vertex stage always comes from the shared types library, so every
        // shader — bundled or user-supplied — gets the same UV contract.
        guard let vertexLibrary = ShaderLibrary.shared.library(for: sharedTypesDescriptor) else {
            lastError = "无法加载宿主 vertex stage"
            pipelineState = nil
            return false
        }
        guard let vertex = vertexLibrary.makeFunction(name: "kumone_vertex") else {
            lastError = "宿主缺少 kumone_vertex"
            pipelineState = nil
            return false
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "Kumone.\(descriptor.name)"
        pipelineDescriptor.vertexFunction = vertex
        pipelineDescriptor.fragmentFunction = fragment
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        // Additive: shaders emit glow that accumulates over the background.
        let color = pipelineDescriptor.colorAttachments[0]!
        color.isBlendingEnabled = true
        color.rgbBlendOperation = .add
        color.alphaBlendOperation = .add
        color.sourceRGBBlendFactor = .sourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .one
        color.destinationAlphaBlendFactor = .one

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            currentDescriptor = descriptor
            lastError = nil
            return true
        } catch {
            lastError = "管线创建失败：\(error.localizedDescription)"
            pipelineState = nil
            return false
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // The uniforms carry the resolution; nothing to resize here.
    }

    func draw(in view: MTKView) {
        guard let pipelineState,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let buffer = uniformBuffer
        else { return }

        let now = CACurrentMediaTime()
        if startTime == 0 { startTime = now }
        let time = Float(now - startTime)

        // Feed the bridge real levels only while the tap is live; otherwise
        // silence so envelopes decay to rest instead of holding a stale frame.
        //
        // Liveness is re-derived here every frame because the spectrum's tap
        // state changes on the audio thread — `preparing` becomes `tapped`
        // once the render graph is pulling samples, which happens after the
        // container's last SwiftUI update — and the container only pushes in
        // when its own inputs change. A flag set once would stick at the value
        // that happened to hold on the last update and the shader would run on
        // silence for the whole track.
        let spectrum = AudioSpectrum.shared
        let isAudioLive = isAudioPlaying && spectrum.tapState == .tapped && spectrum.isLive
        let frame = isAudioLive
            ? bridge.frame(sampler: bandSampler)
            : bridge.frame(sampler: { _ in 0 })

        var uniforms = ShaderUniforms()
        uniforms.time = time
        uniforms.resolution = SIMD2(Float(view.drawableSize.width),
                                    Float(view.drawableSize.height))
        uniforms.bands = frame.bands
        uniforms.level = frame.level
        uniforms.low = frame.low
        uniforms.mid = frame.mid
        uniforms.high = frame.high
        uniforms.beat = frame.beat
        uniforms.loudness = frame.loudness
        uniforms.palettePrimary = palette.primary
        uniforms.paletteSecondary = palette.secondary
        uniforms.paletteAccent = palette.accent
        uniforms.paletteBackground = palette.background

        buffer.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<ShaderUniforms>.stride)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        encoder.label = "Kumone.shader"
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Shared types library

    /// A descriptor standing in for the host's own vertex stage + helpers,
    /// which live in the bundled types header and ride along in the default
    /// library with every bundled shader.
    private var sharedTypesDescriptor: ShaderDescriptor {
        ShaderDescriptor(id: "bundled.__host__", name: "__host__", origin: .bundled)
    }

    /// Lazily created uniform buffer, aligned for the constant address space.
    func prepareUniformBuffer() {
        guard uniformBuffer == nil else { return }
        uniformBuffer = device.makeBuffer(
            length: uniformStride,
            options: [.storageModeShared]
        )
        uniformBuffer?.label = "Kumone.uniforms"
    }
}
