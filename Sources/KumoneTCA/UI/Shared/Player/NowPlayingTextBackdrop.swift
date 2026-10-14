import SwiftUI
#if os(macOS)
import AppKit
import KumoneCore
#endif

/// Marks an untinted, feathered blur region in the live Metal backdrop.
/// Rendering it in Metal avoids material tint and compositor isolation.
struct NowPlayingTextBackdrop: View {
    var feather: SIMD2<Float> = SIMD2(0.12, 0.16)
    var body: some View {
        #if os(macOS)
        ColorlessBackdropBlur(feather: feather)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        #else
        Color.clear
        #endif
    }
}

#if os(macOS)
private struct ColorlessBackdropBlur: NSViewRepresentable {
    let feather: SIMD2<Float>
    func makeNSView(context: Context) -> ColorlessBackdropBlurView {
        ColorlessBackdropBlurView(feather: feather)
    }
    func updateNSView(_ view: ColorlessBackdropBlurView, context: Context) {
        ShaderBlurRegions.register(view, feather: feather)
    }
    static func dismantleNSView(_ view: ColorlessBackdropBlurView, coordinator: ()) {
        ShaderBlurRegions.unregister(view)
    }
}

final class ColorlessBackdropBlurView: NSView {
    override var isOpaque: Bool { false }
    init(feather: SIMD2<Float> = SIMD2(0.12, 0.16)) {
        super.init(frame: .zero)
        ShaderBlurRegions.register(self, feather: feather)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
