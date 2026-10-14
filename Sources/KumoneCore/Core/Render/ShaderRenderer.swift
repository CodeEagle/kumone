import Foundation
import Metal
import MetalKit
import simd

/// A uniquely owned readback buffer: CPU access occurs only in Metal's
/// completion handler after GPU writes finish, and no CPU writer exists.
/// Remove the wrapper once the SDK marks MTLBuffer Sendable.
private struct ShaderReadbackBuffer: @unchecked Sendable {
    let buffer: any MTLBuffer
}

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

    private var regionBlur: ShaderRegionBlur?
    private var pipelineState: (any MTLRenderPipelineState)?
    private var uniformBuffer: any MTLBuffer?
    private var needsPixelProbe = false
    private let libraryOwner = UUID()
    private let uniformStride: Int

    private var bridge = ShaderAudioBridge()
    /// Birth times of the arrow patterns spawned by the last four beats
    /// (-1 = never born), rotating so the oldest is evicted, not the newest.
    private var beatBirthTs: [Float] = [-1, -1, -1, -1]
    private var paletteMixer = ShaderPaletteMixer()
    private var startTime: CFTimeInterval = 0
    /// Timestamp of the previous drawn frame, for the palette ease and the
    /// audio bridge's step. Zero until the first frame lands.
    private var lastFrameTime: CFTimeInterval = 0
    /// Throttles the diagnostic probe in `draw`.
    private var lastProbeTime: CFTimeInterval = 0
    private static let probeLogURL = URL(fileURLWithPath: "/tmp/kumone-shader.log")
    private static func writeFile(_ line: String) {
        BoundedLogFile.append(line, to: probeLogURL)
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

    deinit {
        // A renderer that dies without an explicit unload() must not strand
        // its library leases in ShaderDiscovery: every current owner calls
        // tearDown()/unload(), but that is a convention, not a guarantee.
        // The owner token is a value, and deinit is nonisolated, so the
        // release is deferred to a MainActor task that captures nothing of
        // this instance but the token itself.
        let owner = libraryOwner
        Task { @MainActor in
            ShaderDiscovery.shared.releaseLibraries(ownedBy: owner)
        }
    }

    // MARK: - Shader loading

    /// Compiles `descriptor` and rebuilds the pipeline. Returns false on failure
    /// and records `lastError`.
    @discardableResult
    public func load(_ descriptor: ShaderDescriptor) -> Bool {
        unload()
        // Failed compilation must release partial leases while retaining the
        // useful diagnostic. A successful load owns both fragment and vertex.
        defer {
            if pipelineState == nil { releasePipelineResources() }
        }
        guard let library = ShaderDiscovery.shared.library(for: descriptor, owner: libraryOwner) else {
            lastError = String(localized: "无法编译 shader：\(descriptor.name)")
            pipelineState = nil
            return false
        }

        let fragmentName = ShaderDiscovery.shared.fragmentFunctionName(for: descriptor)
        guard let fragment = library.makeFunction(name: fragmentName) else {
            lastError = String(localized: "shader \(descriptor.name) 缺少入口函数 \(fragmentName)")
            pipelineState = nil
            return false
        }

        // The vertex stage always comes from the shared types library, so every
        // shader — bundled or user-supplied — gets the same UV contract.
        guard let vertexLibrary = ShaderDiscovery.shared.library(for: sharedTypesDescriptor, owner: libraryOwner) else {
            lastError = String(localized: "无法加载宿主 vertex stage")
            pipelineState = nil
            return false
        }
        guard let vertex = vertexLibrary.makeFunction(name: "kumone_vertex") else {
            lastError = String(localized: "宿主缺少 kumone_vertex")
            pipelineState = nil
            return false
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "Kumone.\(descriptor.name)"
        pipelineDescriptor.vertexFunction = vertex
        pipelineDescriptor.fragmentFunction = fragment
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        // Original presets already composite their own background. Only
        // imported shaders retain the host's historical additive contract.
        let color = pipelineDescriptor.colorAttachments[0]!
        color.isBlendingEnabled = !descriptor.usesOriginalAnimation
        color.rgbBlendOperation = .add
        color.alphaBlendOperation = .add
        color.sourceRGBBlendFactor = .sourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .one
        color.destinationAlphaBlendFactor = .one

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            prepareUniformBuffer()
            needsPixelProbe = ArtworkLifetimeDiagnostics.isEnabled
            if descriptor.usesOriginalAnimation {
                startTime = 0
                lastFrameTime = 0
            }
            lastError = nil
            return true
        } catch {
            lastError = String(localized: "管线创建失败：\(error.localizedDescription)")
            pipelineState = nil
            return false
        }
    }

    public func unload() {
        releasePipelineResources()
        startTime = 0
        lastFrameTime = 0
        lastProbeTime = 0
        lastError = nil
    }

    private func releasePipelineResources() {
        pipelineState = nil
        uniformBuffer = nil
        regionBlur = nil
        ShaderDiscovery.shared.releaseLibraries(ownedBy: libraryOwner)
    }

    var hasPipelineResources: Bool { pipelineState != nil || uniformBuffer != nil }

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

        // Stamp a birth time on the rising edge of each beat. The ring of
        // timestamps is the only place the pattern copies live: the shader is
        // stateless, so a copy has to be identified by the moment it was born.
        // A silent frame never stamps one, so with no track playing the field
        // holds only the standing pattern.
        if frame.beatJustHit && isAudioLive {
            beatBirthTs.removeFirst()
            beatBirthTs.append(time)
        }

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
        uniforms.beatBirthTs = (beatBirthTs[0], beatBirthTs[1], beatBirthTs[2], beatBirthTs[3])

        buffer.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<ShaderUniforms>.stride)
        #if os(macOS)
        let blurRegions = ShaderBlurRegions.regions(in: view)
        let regions = blurRegions.map(\.rectangle)
        let feathers = blurRegions.map(\.feather)
        #else
        let regions: [SIMD4<Float>] = []
        let feathers: [SIMD2<Float>] = []
        #endif
        var shaderPass = descriptor
        if !regions.isEmpty {
            if regionBlur == nil { regionBlur = try? ShaderRegionBlur(device: device) }
            if let texture = regionBlur?.renderTarget(width: drawable.texture.width, height: drawable.texture.height),
               let pass = descriptor.copy() as? MTLRenderPassDescriptor {
                pass.colorAttachments[0].texture = texture
                pass.colorAttachments[0].storeAction = .store
                shaderPass = pass
            }
        }
        let targetMatches = descriptor.colorAttachments[0].texture === drawable.texture
        descriptor.colorAttachments[0].storeAction = .store

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: shaderPass) else {
            return
        }
        encoder.label = "Kumone.shader"
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        if shaderPass !== descriptor {
            regionBlur?.composite(command: commandBuffer, destination: descriptor, regions: regions, feathers: feathers)
        }
        commandBuffer.present(drawable)
        if needsPixelProbe, !view.framebufferOnly, drawable.texture.width >= 600 {
            needsPixelProbe = false
            if let samples = device.makeBuffer(length: 64 * 256, options: .storageModeShared),
               let blit = commandBuffer.makeBlitCommandEncoder() {
                for index in 0..<64 {
                    let x = (index % 8 * 2 + 1) * drawable.texture.width / 16
                    let y = (index / 8 * 2 + 1) * drawable.texture.height / 16
                    blit.copy(from: drawable.texture, sourceSlice: 0, sourceLevel: 0,
                              sourceOrigin: MTLOrigin(x: x, y: y, z: 0), sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                              to: samples, destinationOffset: index * 256, destinationBytesPerRow: 256, destinationBytesPerImage: 256)
                }
                blit.endEncoding()
                let readback = ShaderReadbackBuffer(buffer: samples)
                commandBuffer.addCompletedHandler { completed in
                    let bytes = readback.buffer.contents().assumingMemoryBound(to: UInt8.self)
                    var minimum = 255, maximum = 0, lit = 0, alpha = 0
                    for index in 0..<64 {
                        let offset = index * 256
                        let value = max(Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
                        minimum = min(minimum, value)
                        maximum = max(maximum, value)
                        if value > 8 { lit += 1 }
                        alpha = max(alpha, Int(bytes[offset + 3]))
                    }
                    let line = "SHADER GPU completed=\(completed.status == .completed) targetMatches=\(targetMatches) lit=\(lit)/64 min=\(minimum) max=\(maximum) alpha=\(alpha) error=\(completed.error?.localizedDescription ?? "nil")"
                    KumoneLogger.app.notice("\(line, privacy: .public)")
                }
            }
        }
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
                format: "SHADER PROBE live=%d playing=%d reactive=%d tapState=%d loud=%.3f lvl=%.3f low=%.3f mid=%.3f high=%.3f beat=%.3f palPri=(%.2f,%.2f,%.2f) palSec=(%.2f,%.2f,%.2f) palAcc=(%.2f,%.2f,%.2f) palBg=(%.2f,%.2f,%.2f)",
                isAudioLive ? 1 : 0, isAudioPlaying ? 1 : 0, isAudioReactive ? 1 : 0,
                AudioSpectrum.shared.tapState.rawValue,
                frame.loudness, frame.level, frame.low, frame.mid, frame.high, frame.beat,
                p.primary.x, p.primary.y, p.primary.z,
                p.secondary.x, p.secondary.y, p.secondary.z,
                p.accent.x, p.accent.y, p.accent.z,
                p.background.x, p.background.y, p.background.z)
            KumoneLogger.hero.notice("\(line, privacy: .public)")
            Self.writeFile(line)
            #if os(macOS)
            let surface = "SHADER SURFACE drawable=\(drawable.texture.width)x\(drawable.texture.height) hidden=\(view.isHiddenOrHasHiddenAncestor) opacity=\(view.layer?.opacity ?? 0) window=\(view.window != nil)"
            KumoneLogger.app.notice("\(surface, privacy: .public)")
            Self.writeFile(surface)
            #endif
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
