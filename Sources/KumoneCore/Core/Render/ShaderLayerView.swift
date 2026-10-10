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
    private var renderer: ShaderRenderer?

    /// Tracks the shader currently loaded into `renderer` so the pipeline is
    /// rebuilt only on an actual change; rebuilding it every frame would stall
    /// the render loop.
    private var currentShaderID: String?

    /// `init(frame:device:)` is `MTKView`'s designated initializer (`init(frame:)`
    /// is only a convenience initializer on MetalKit's view, so it cannot be
    /// overridden; the zero-argument and `init(frame:)` forms stay available
    /// through initializer inheritance.
    public override init(frame frameRect: CGRect, device: MTLDevice?) {
        // Do not allocate GPU resources for a background that starts disabled.
        // The optional caller-supplied device is installed on the first enable.
        requestedDevice = device
        super.init(frame: frameRect, device: nil)
        self.device = nil

        colorPixelFormat = .bgra8Unorm_srgb
        preferredFramesPerSecond = 60
        isPaused = true
        isHidden = true
        enableSetNeedsDisplay = false
        framebufferOnly = !ArtworkLifetimeDiagnostics.isEnabled
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.maximumDrawableCount = 2
        }
        // Disable automatic sizing before clamping, including while bounds are zero.
        autoResizeDrawable = false
        drawableSize = CGSize(width: 1, height: 1)

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
    }

    private let requestedDevice: (any MTLDevice)?

    var hasRenderer: Bool { renderer != nil }

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
        #elseif os(visionOS)
        // visionOS has no UIScreen; fall back to the view's own scale factor.
        return window?.contentScaleFactor ?? 2
        #else
        return window?.screen.scale ?? UIScreen.main.scale
        #endif
    }

    private func clampDrawableSize() {
        guard device != nil else { return }
        guard let target = ShaderDrawableBudget.clamped(from: bounds.size, scale: scaleForClamping) else { return }
        guard drawableSize != target else { return }
        drawableSize = target
    }

    /// Pushes store-derived state into the renderer. The pipeline is reloaded
    /// only when the shader id changes; `palette` and playback liveness are
    /// cheap to set every time.
    ///
    /// - Parameter pcmSync: Whether the shader should react to the live PCM
    ///   analysis. Off means the shader keeps its own time-driven motion and
    ///   the audio uniforms read as silence.
    public func apply(shader: ShaderDescriptor?, isPlaying: Bool, palette: ShaderPalette, pcmSync: Bool = true) {
        guard let shader else {
            tearDown()
            ShaderLayerView.logApply(
                "shaderId=nil isPlaying=\(isPlaying) released=true"
                    + " renderer=\(hasRenderer ? 1 : 0) device=\(device == nil ? 0 : 1)"
                    + " cachedLibraries=\(ShaderDiscovery.shared.cachedLibraryCount)"
            )
            return
        }
        if renderer == nil {
            device = requestedDevice ?? MTLCreateSystemDefaultDevice()
            renderer = ShaderRenderer(device: device)
            delegate = renderer
        }
        clampDrawableSize()
        guard let renderer else {
            ShaderLayerView.logApply("no-renderer shaderId=\(shader.id) isPlaying=\(isPlaying)")
            return
        }
        ShaderLayerView.logApply("shaderId=\(shader.id) isPlaying=\(isPlaying) pcmSync=\(pcmSync) isPaused=\(isPaused)")

        if shader.id != currentShaderID {
            currentShaderID = shader.id
            // A shader that fails to build must not leave the previous
            // shader's last frame on the layer either.
            if !renderer.load(shader) {
                ShaderLayerView.logApply("load-failed shaderId=\(shader.id) error=\(renderer.lastError ?? "unknown")")
                renderer.clearOnce(in: self)
            }
        }

        isHidden = false

        renderer.palette = palette
        renderer.isAudioPlaying = isPlaying
        renderer.isAudioReactive = pcmSync && !shader.usesOriginalAnimation
        // Restore visibility and uniforms before restarting MetalKit's display
        // link. After releasing drawables/device, explicitly seed a new frame
        // rather than relying on a resize or playback change to wake it up.
        isPaused = !isPlaying && !shader.usesOriginalAnimation
        draw()
    }

    /// Disables the background without destroying its layout shell. Renderer,
    /// queue, attachments and this view's library leases are released; another
    /// apply(shader:) lazily rebuilds them. Also used by representable dismantle.
    public func tearDown() {
        isPaused = true
        isHidden = true
        delegate = nil
        renderer?.unload()
        renderer = nil
        currentShaderID = nil
        releaseDrawables()
        // MTKView's attachments and CAMetalLayer's last full-size surface must
        // not stay warm while disabled. No transparent clear frame is submitted:
        // hiding immediately reveals the backdrop without acquiring a drawable.
        drawableSize = CGSize(width: 1, height: 1)
        device = nil
        #if os(macOS)
        layer?.contents = nil
        #else
        layer.contents = nil
        #endif
    }
    /// Triage probe for headless runs: `apply` decisions land in
    /// /tmp/kumone-apply.log so a script can prove which shader id the store
    /// actually pushed, without a GUI. Keep until the window-shader triage on
    /// workmini is closed.
    private static func logApply(_ message: String) {
        let line = "SHADER APPLY \(message)"
        KumoneLogger.app.notice("\(line, privacy: .public)")
        BoundedLogFile.append(line, to: URL(fileURLWithPath: "/tmp/kumone-apply.log"))
    }

}
