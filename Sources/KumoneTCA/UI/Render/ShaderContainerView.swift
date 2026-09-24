import KumoneCore
import MetalKit
import SwiftUI
#if os(iOS)
import KumoneCore
import UIKit
#endif

/// Renders a single shader full-screen behind a SwiftUI view.
///
/// This is the "container": it owns the Metal device, the renderer, and the
/// per-frame data plumbing, and exposes a `shader` the caller can switch at
/// will. A shader file needs only a fragment function named
/// `kumone_fragment`; everything else is provided.
///
/// Use `.background(ShaderContainerView(shader:))` or layer it in a `ZStack`
/// behind content. It is transparent where the shader doesn't draw, so it
/// composites over an app background.
struct ShaderContainerView: PlatformViewRepresentable {
    let shader: ShaderDescriptor?
    let isPlaying: Bool
    let palette: ShaderPalette

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Platform plumbing

    #if os(macOS)
    func makeNSView(context: Context) -> MTKView {
        makeMetalView(context: context)
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        updateMetalView(nsView, context: context)
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        coordinator.tearDown(nsView)
    }
    #else
    func makeUIView(context: Context) -> MTKView {
        makeMetalView(context: context)
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        updateMetalView(uiView, context: context)
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.tearDown(uiView)
    }
    #endif

    private func makeMetalView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = true
        // Shaders draw glow over the app's own backdrop; let it show through.
        #if os(macOS)
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = .clear
        #else
        view.layer.isOpaque = false
        view.layer.backgroundColor = UIColor.clear.cgColor
        #endif
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        let coordinator = context.coordinator
        coordinator.renderer = ShaderRenderer(device: view.device)
        coordinator.renderer?.prepareUniformBuffer()
        view.delegate = coordinator.renderer

        context.coordinator.apply(shader: shader, isPlaying: isPlaying, palette: palette)
        return view
    }

    private func updateMetalView(_ view: MTKView, context: Context) {
        context.coordinator.apply(
            shader: shader,
            isPlaying: isPlaying,
            palette: palette
        )
    }

    // MARK: - Coordinator

    /// Bridges SwiftUI updates to the renderer without recreating the Metal view.
    @MainActor
    final class Coordinator {
        var renderer: ShaderRenderer?
        private var currentShaderID: String?

        func apply(shader: ShaderDescriptor?, isPlaying: Bool, palette: ShaderPalette) {
            guard let renderer else { return }

            // Reload the pipeline only when the shader actually changes;
            // rebuilding it every frame would stall the render loop.
            if shader?.id != currentShaderID {
                currentShaderID = shader?.id
                if let shader {
                    renderer.load(shader)
                } else {
                    renderer.unload()
                }
            }

            renderer.palette = palette
            renderer.isAudioPlaying = isPlaying
        }

        func tearDown(_ view: MTKView) {
            view.delegate = nil
            renderer = nil
        }
    }
}
