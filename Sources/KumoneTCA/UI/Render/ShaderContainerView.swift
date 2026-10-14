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
    /// Whether the shader reacts to the live PCM analysis. Off keeps the
    /// shader's own time-driven motion and feeds the audio uniforms silence.
    var pcmSync: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Platform plumbing

    #if os(macOS)
    func makeNSView(context: Context) -> ShaderLayerView {
        makeMetalView()
    }

    func updateNSView(_ nsView: ShaderLayerView, context: Context) {
        updateMetalView(nsView)
    }

    static func dismantleNSView(_ nsView: ShaderLayerView, coordinator: Coordinator) {
        nsView.tearDown()
    }
    #else
    func makeUIView(context: Context) -> ShaderLayerView {
        makeMetalView()
    }

    func updateUIView(_ uiView: ShaderLayerView, context: Context) {
        updateMetalView(uiView)
    }

    static func dismantleUIView(_ uiView: ShaderLayerView, coordinator: Coordinator) {
        uiView.tearDown()
    }
    #endif

    private func makeMetalView() -> ShaderLayerView {
        let view = ShaderLayerView()
        updateMetalView(view)
        return view
    }

    private func updateMetalView(_ view: ShaderLayerView) {
        view.apply(
            shader: shader,
            isPlaying: isPlaying,
            palette: palette,
            pcmSync: pcmSync
        )
    }

    // MARK: - Coordinator

    /// Both the native window and SwiftUI use ShaderLayerView's lifecycle.
    /// Keep a coordinator for representable dismantling, not a second renderer.
    @MainActor
    final class Coordinator {
    }
}

/// Mount an enabled backdrop with a fresh native presentation host. Keeping a
/// hidden, device-less Metal view in SwiftUI's background can leave its old
/// composition cached when it is enabled again; startup already creates an
/// active host, which is why restarting appears to repair that state.
struct ShaderBackdropView: View {
    let shader: ShaderDescriptor?
    let isPlaying: Bool
    let palette: ShaderPalette
    var pcmSync: Bool = true
    var intensity: Double = 1

    var body: some View {
        if let shader {
            ShaderContainerView(shader: shader, isPlaying: isPlaying,
                                palette: palette, pcmSync: pcmSync)
                .id(shader.id)
                .opacity(min(max(intensity, 0), 1))
        }
    }
}
