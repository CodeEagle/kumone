#if os(macOS)
import AppKit
import KumoneCore
import Testing
@testable import KumoneTCA

@Suite("Untinted backdrop regions")
@MainActor
struct ColorlessBackdropTests {
    @Test func markersFollowLayoutAndDisappearWhenDismantled() {
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 240, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let surface = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 100))
        window.contentView = surface
        let marker = ColorlessBackdropBlurView()
        marker.frame = CGRect(x: 60, y: 25, width: 120, height: 50)
        surface.addSubview(marker)
        let rects = ShaderBlurRegions.rectangles(in: surface)
        #expect(rects == [SIMD4<Float>(0.25, 0.25, 0.5, 0.5)])
        #expect(marker.hitTest(.zero) == nil)
        ShaderBlurRegions.unregister(marker)
        #expect(ShaderBlurRegions.rectangles(in: surface).isEmpty)
    }
}
#endif
