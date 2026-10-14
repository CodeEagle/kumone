#if os(macOS)
import AppKit
import Combine
import ComposableArchitecture
import KumoneCore
import MetalKit
import SwiftUI
import Testing
@testable import KumoneTCA

@Suite("Shader presentation attachment")
@MainActor
struct ShaderPresentationTests {
    @Test func nowPlayingAllowsWindowBackdropThrough() async throws {
        var state = AppFeature.State()
        state.isNowPlayingPresented = true
        state.settings.showMainWindowAmbientBackground = false
        let store = Store(initialState: state) {
            Reduce<AppFeature.State, AppFeature.Action> { _, _ in .none }
        }
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1080, height: 703),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MainWindow(store: store).background(Color.green))
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 250_000_000)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let x = Int(900 * Double(bitmap.pixelsWide) / host.bounds.width)
        let y = Int(200 * Double(bitmap.pixelsHigh) / host.bounds.height)
        let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        #expect(color.greenComponent > color.redComponent + 0.2 && color.greenComponent > color.blueComponent + 0.2,
                "the immersive page must not cover the window backdrop: \(color)")
    }

    @Test func enablingBackdropAttachesDrawableToVisibleMetalLayer() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        ShaderDiscovery.shared.reload()
        let shader = try #require(ShaderDiscovery.shared.availableDescriptors.first)
        let model = ShaderPresentationModel()
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ShaderPresentationFixture(model: model))
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 100_000_000)
        func metalView(in view: NSView) -> ShaderLayerView? {
            if let metal = view as? ShaderLayerView { return metal }
            return view.subviews.lazy.compactMap { metalView(in: $0) }.first
        }
        #expect(metalView(in: host) == nil, "disabled backdrop must not leave a hidden presentation host")
        var previousView: ShaderLayerView?
        for _ in 0..<3 {
            model.shader = shader
            try await Task.sleep(nanoseconds: 100_000_000)
            let view = try #require(metalView(in: host))
            #expect(view !== previousView, "enabling must create a fresh native view without restarting the window")
            previousView = view
            let drawable = try #require(view.currentDrawable)
            #expect(view.layer === drawable.layer,
                    "rendering to a detached CAMetalLayer cannot display the shader")
            #expect(drawable.layer.superlayer != nil)
            #expect(drawable.layer.bounds.width > 0 && drawable.layer.bounds.height > 0)
            #expect(!view.isHiddenOrHasHiddenAncestor)
            #expect(view.bounds.width == 400 && view.bounds.height == 300)
            model.shader = nil
            try await Task.sleep(nanoseconds: 50_000_000)
            #expect(metalView(in: host) == nil)
            #expect(view.device == nil && view.delegate == nil, "dismantling releases Metal resources")
        }
    }
}
@MainActor
private final class ShaderPresentationModel: ObservableObject {
    @Published var shader: ShaderDescriptor?
}
private struct ShaderPresentationFixture: View {
    @ObservedObject var model: ShaderPresentationModel
    var body: some View {
        Color.clear
            .background {
                ShaderBackdropView(shader: model.shader, isPlaying: true, palette: .fallback, intensity: 0.5)
            }
            .frame(width: 400, height: 300)
    }
}
#endif
