import CoreGraphics
import MetalKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Absolute-pixel budget for the decorative shader backdrop.
/// Core Animation upscales the clamped drawable, so clamping only costs sharpness.
enum ShaderDrawableBudget {
    static let maxPixels = CGSize(width: 1920, height: 1080)

    /// Points × backing scale, clamped to the budget, quantized to whole pixels.
    /// Returns nil for empty or non-finite input (view not laid out yet).
    static func clamped(from size: CGSize, scale: CGFloat) -> CGSize? {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, scale.isFinite, scale > 0 else { return nil }
        var target = CGSize(width: size.width * scale, height: size.height * scale)
        let budget = maxPixels
        if target.width > budget.width || target.height > budget.height {
            let shrink = min(budget.width / target.width, budget.height / target.height)
            target = CGSize(width: target.width * shrink, height: target.height * shrink)
        }
        return CGSize(width: max(1, target.width.rounded(.down)),
                      height: max(1, target.height.rounded(.down)))
    }
}

/// A transparent, full-window Metal layer that renders the current shader.
///
/// The AppKit shell's counterpart of the old SwiftUI `ShaderContainerView`:
/// it owns the device, the renderer, and the per-frame plumbing, and exposes
/// `apply(shader:isPlaying:palette:)` for the app delegate to drive from store
/// state. Subclassing `MTKView` directly (rather than wrapping it) keeps it
/// usable from both AppKit and UIKit hosts with no representable scaffolding.
@MainActor
public final class ShaderLayerView: MTKView {
    /// Renders the loaded shader every frame. `nil` when the system has no
    /// Metal device, in which case the layer stays inert rather than crashing.
    private let renderer: ShaderRenderer?

    /// Tracks the shader currently loaded into `renderer` so the pipeline is
    /// rebuilt only on an actual change; rebuilding it every frame would stall
    /// the render loop.
    private var currentShaderID: String?

    /// `init(frame:device:)` is `MTKView`'s designated initializer (`init(frame:)`
    /// is only a convenience initializer on MetalKit's view, so it cannot be
    /// overridden; the zero-argument and `init(frame:)` forms stay available
    /// through initializer inheritance.
    public override init(frame frameRect: CGRect, device: MTLDevice?) {
        let device = device ?? MTLCreateSystemDefaultDevice()
        self.renderer = ShaderRenderer(device: device)
        super.init(frame: frameRect, device: device)

        colorPixelFormat = .bgra8Unorm_srgb
        preferredFramesPerSecond = 60
        isPaused = false
        enableSetNeedsDisplay = false
        framebufferOnly = true
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.maximumDrawableCount = 2
        }
        // Disable automatic sizing before clamping, including while bounds are zero.
        autoResizeDrawable = false
        clampDrawableSize()

        // Shaders emit glow that composites over the window's frosted backdrop,
        // so the layer itself must be transparent where they don't draw.
        #if os(macOS)
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        #else
        layer.isOpaque = false
        layer.backgroundColor = UIColor.clear.cgColor
        #endif
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        if let renderer {
            renderer.prepareUniformBuffer()
            self.delegate = renderer
        }
    }

    required public init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    #if os(macOS)
    public override func layout() {
        super.layout()
        clampDrawableSize()
    }
    #else
    public override func layoutSubviews() {
        super.layoutSubviews()
        clampDrawableSize()
    }
    #endif

    private var scaleForClamping: CGFloat {
        #if os(macOS)
        return window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 1
        #else
        return window?.screen.scale ?? UIScreen.main.scale
        #endif
    }

    private func clampDrawableSize() {
        guard let target = ShaderDrawableBudget.clamped(from: bounds.size, scale: scaleForClamping) else { return }
        guard drawableSize != target else { return }
        drawableSize = target
    }

    /// Pushes store-derived state into the renderer. The pipeline is reloaded
    /// only when the shader id changes; `palette` and playback liveness are
    /// cheap to set every time.
    public func apply(shader: ShaderDescriptor?, isPlaying: Bool, palette: ShaderPalette) {
        clampDrawableSize()
        isPaused = !isPlaying
        guard let renderer else { return }

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

    /// Stops rendering and releases GPU resources when the host discards this view.
    public func tearDown() {
        isPaused = true
        delegate = nil
        renderer?.unload()
        releaseDrawables()
    }
}
