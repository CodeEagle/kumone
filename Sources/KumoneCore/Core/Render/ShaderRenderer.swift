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
public final class ShaderRenderer: NSObject, MTKViewDelegate {
    /// Provides band levels each frame. Defaulted to the shared spectrum; tests
    /// substitute their own sampler.
    public var bandSampler: (Int) -> Float = { AudioSpectrum.shared.level(at: $0) }

    /// Whether the transport is playing, pushed in by the container. Liveness
    /// itself is re-derived every frame in `draw`.
    public var isAudioPlaying = false

    /// Whether the shader reacts to the live PCM analysis. Off feeds the audio
    /// uniforms silence so the shader falls back to its own time-driven motion.
    /// Pushed in by whichever host owns the renderer.
    public var isAudioReactive = true

    public var palette: ShaderPalette = .fallback

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue

    private var pipelineState: (any MTLRenderPipelineState)?
    private var uniformBuffer: any MTLBuffer?
    private let uniformStride: Int

    private var bridge = ShaderAudioBridge()
    private var paletteMixer = ShaderPaletteMixer()
    private var startTime: CFTimeInterval = 0
    /// Timestamp of the previous drawn frame, for the palette ease and the
    /// audio bridge's step. Zero until the first frame lands.
    private var lastFrameTime: CFTimeInterval = 0
    /// Throttles the diagnostic probe in `draw`.
    private var lastProbeTime: CFTimeInterval = 0
    private static let probeLogURL = URL(fileURLWithPath: "/tmp/kumone-shader.log")
    private static func writeFile(_ line: String) {
        let payload = (line + "\n").data(using: .utf8) ?? Data()
        if let handle = try? FileHandle(forWritingTo: probeLogURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
            try? handle.close()
        } else {
            try? payload.write(to: probeLogURL, options: [.atomic])
        }
    }

    /// Set when a shader fails to build, so the host can show why instead of a
    /// black screen with no explanation.
    public private(set) var lastError: String?

    public init?(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) {
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
    public func load(_ descriptor: ShaderDescriptor) -> Bool {
        guard let library = ShaderDiscovery.shared.library(for: descriptor) else {
            lastError = "无法编译 shader：\(descriptor.name)"
            pipelineState = nil
            return false
        }

        let fragmentName = ShaderDiscovery.shared.fragmentFunctionName(for: descriptor)
        guard let fragment = library.makeFunction(name: fragmentName) else {
            lastError = "shader \(descriptor.name) 缺少入口函数 \(fragmentName)"
            pipelineState = nil
            return false
        }

        // The vertex stage always comes from the shared types library, so every
        // shader — bundled or user-supplied — gets the same UV contract.
        guard let vertexLibrary = ShaderDiscovery.shared.library(for: sharedTypesDescriptor) else {
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
            lastError = nil
            return true
        } catch {
            lastError = "管线创建失败：\(error.localizedDescription)"
            pipelineState = nil
            return false
        }
    }

    public func unload() {
        pipelineState = nil
        lastError = nil
    }

    /// Submits a single frame cleared to the view's clear color.
    ///
    /// `draw` early-returns while `pipelineState` is nil, so an unloaded shader
    /// would otherwise leave its last rendered frame on the layer forever. The
    /// host calls this right after `unload` (or a failed `load`) so the layer
    /// actually goes transparent and whatever sits beneath it shows through.
    public func clearOnce(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // The uniforms carry the resolution; nothing to resize here.
    }

    public func draw(in view: MTKView) {
        guard let pipelineState,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let buffer = uniformBuffer
        else { return }

        let now = CACurrentMediaTime()
        if startTime == 0 { startTime = now }
        let time = Float(now - startTime)
        let dt: Float = lastFrameTime == 0 ? 0 : Float(min(max(now - lastFrameTime, 0), 0.25))
        lastFrameTime = now

        // The palette is re-derived from the cover on every track change, and
        // assigning it outright makes the whole backdrop snap at the exact
        // moment the eye is on the new artwork. Ease it instead; the very
        // first frame has nothing to fade from and snaps by itself.
        paletteMixer.step(toward: palette, dt: dt)
        let palette = paletteMixer.current

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
        //
        // `isAudioReactive` is the shader list's PCM switch. It belongs in the
        // same test rather than in a branch of its own: turning it off has to
        // feel like the music stopped being read, so the bridge keeps running
        // and its envelopes unwind to rest over about half a second. Skipping
        // the call instead would freeze the last loud frame on screen, which
        // reads as a stuck shader rather than as an intentional switch.
        let spectrum = AudioSpectrum.shared
        let isAudioLive = isAudioReactive && isAudioPlaying
            && spectrum.tapState == .tapped && spectrum.isLive
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

        // Shader diagnostic probe: every 2s log the palette slots and the audio
        // frame values so a "washed out / doesn't match the cover" report can
        // be split into "palette wrong" vs "audio driving it dark" without a
        // GUI. See /tmp/kumone-shader.log. (TEMPORARY: released unconditionally
        // while the palette/conformance issue is being triaged on workmini.)
        if now - lastProbeTime >= 2.0 {
            lastProbeTime = now
            let p = paletteMixer.current
            let line = String(
                format: "SHADER PROBE live=%d playing=%d reactive=%d loud=%.3f lvl=%.3f low=%.3f mid=%.3f high=%.3f beat=%.3f palPri=(%.2f,%.2f,%.2f) palSec=(%.2f,%.2f,%.2f) palAcc=(%.2f,%.2f,%.2f) palBg=(%.2f,%.2f,%.2f)",
                isAudioLive ? 1 : 0, isAudioPlaying ? 1 : 0, isAudioReactive ? 1 : 0,
                frame.loudness, frame.level, frame.low, frame.mid, frame.high, frame.beat,
                p.primary.x, p.primary.y, p.primary.z,
                p.secondary.x, p.secondary.y, p.secondary.z,
                p.accent.x, p.accent.y, p.accent.z,
                p.background.x, p.background.y, p.background.z)
            KumoneLogger.hero.notice("\(line, privacy: .public)")
            Self.writeFile(line)
        }
    }

    // MARK: - Shared types library

    /// A descriptor standing in for the host's own vertex stage + helpers,
    /// which live in the bundled types header and ride along in the default
    /// library with every bundled shader.
    private var sharedTypesDescriptor: ShaderDescriptor {
        ShaderDescriptor(id: "bundled.__host__", name: "__host__", origin: .bundled)
    }

    /// Lazily created uniform buffer, aligned for the constant address space.
    public func prepareUniformBuffer() {
        guard uniformBuffer == nil else { return }
        uniformBuffer = device.makeBuffer(
            length: uniformStride,
            options: [.storageModeShared]
        )
        uniformBuffer?.label = "Kumone.uniforms"
    }
}
