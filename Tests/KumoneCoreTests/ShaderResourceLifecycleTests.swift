import MetalKit
import XCTest
#if os(macOS)
import AppKit
#endif
@testable import KumoneCore

final class ShaderResourceLifecycleTests: XCTestCase {
    private final class WeakRenderer {
        weak var value: ShaderRenderer?
        init(_ value: ShaderRenderer?) { self.value = value }
    }
    @MainActor
    private func preset() throws -> ShaderDescriptor {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        ShaderDiscovery.shared.reload()
        return try XCTUnwrap(ShaderDiscovery.shared.availableDescriptors.first { $0.name == "Animated_loop" })
    }

    @MainActor
    func testDisabledViewAllocatesNoRendererOrDevice() {
        let view = ShaderLayerView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700), device: nil)
        XCTAssertFalse(view.hasRenderer)
        XCTAssertNil(view.device)
        XCTAssertNil(view.delegate)
        XCTAssertTrue(view.isPaused)
        XCTAssertTrue(view.isHidden)
    }

    @MainActor
    func testRepeatedEnableDisableReleasesRendererAndRestoresSameShader() throws {
        let shader = try preset()
        let view = ShaderLayerView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700), device: nil)
        defer { view.tearDown() }
        for _ in 0..<10 {
            view.apply(shader: shader, isPlaying: true, palette: .fallback)
            let oldRenderer = WeakRenderer(view.delegate as? ShaderRenderer)
            XCTAssertNotNil(oldRenderer.value)
            XCTAssertTrue(oldRenderer.value?.hasPipelineResources == true)
            XCTAssertFalse(view.isPaused)
            XCTAssertFalse(view.isHidden)
            XCTAssertGreaterThan(view.drawableSize.width, 1)
            view.apply(shader: nil, isPlaying: true, palette: .fallback)
            XCTAssertNil(oldRenderer.value, "closed view must not retain the renderer/queue")
            XCTAssertFalse(view.hasRenderer)
            XCTAssertNil(view.device)
            XCTAssertNil(view.delegate)
            XCTAssertTrue(view.isPaused)
            XCTAssertTrue(view.isHidden)
            XCTAssertEqual(view.drawableSize, CGSize(width: 1, height: 1))
            XCTAssertEqual(ShaderDiscovery.shared.cachedLibraryCount, 0)
        }
    }

    @MainActor
    func testClosingOneViewPreservesOtherRenderersLibraries() throws {
        let shader = try preset()
        let first = ShaderLayerView()
        let second = ShaderLayerView()
        defer { first.tearDown(); second.tearDown() }
        first.apply(shader: shader, isPlaying: true, palette: .fallback)
        second.apply(shader: shader, isPlaying: true, palette: .fallback)
        let activeRenderer = try XCTUnwrap(second.delegate as? ShaderRenderer)
        let libraryCount = ShaderDiscovery.shared.cachedLibraryCount
        XCTAssertGreaterThan(libraryCount, 0)
        first.apply(shader: nil, isPlaying: true, palette: .fallback)
        XCTAssertTrue(second.hasRenderer)
        XCTAssertTrue(activeRenderer.hasPipelineResources)
        XCTAssertEqual(ShaderDiscovery.shared.cachedLibraryCount, libraryCount)
        second.apply(shader: nil, isPlaying: true, palette: .fallback)
        XCTAssertFalse(activeRenderer.hasPipelineResources, "unload releases buffers even with an external renderer reference")
        XCTAssertEqual(ShaderDiscovery.shared.cachedLibraryCount, 0)
    }

    @MainActor
    func testExplicitTeardownIsIdempotentAndCanReenable() throws {
        let shader = try preset()
        let view = ShaderLayerView()
        view.apply(shader: shader, isPlaying: false, palette: .fallback)
        XCTAssertFalse(view.isPaused, "original presets keep their original independent animation")
        view.tearDown()
        view.tearDown()
        view.apply(shader: shader, isPlaying: true, palette: .fallback)
        XCTAssertTrue((view.delegate as? ShaderRenderer)?.hasPipelineResources == true)
        view.tearDown()
    }

    @MainActor
    func testFailedLoadReleasesPartialLibraries() throws {
        _ = try preset()
        let renderer = try XCTUnwrap(ShaderRenderer())
        let missing = ShaderDescriptor(id: "bundled.missing", name: "not_a_shader", origin: .bundled)
        XCTAssertFalse(renderer.load(missing))
        XCTAssertNotNil(renderer.lastError)
        XCTAssertFalse(renderer.hasPipelineResources)
        XCTAssertEqual(ShaderDiscovery.shared.cachedLibraryCount, 0)
    }

    @MainActor
    func testDeallocatedRendererReleasesLibraryLease() async throws {
        let shader = try preset()
        // A renderer that dies *without* unload() must not strand its library
        // lease. Every current owner calls tearDown(); the deinit floor is
        // the guarantee for any future one.
        var renderer: ShaderRenderer? = try XCTUnwrap(ShaderRenderer())
        XCTAssertTrue(renderer?.load(shader) == true)
        XCTAssertGreaterThan(ShaderDiscovery.shared.cachedLibraryCount, 0)
        renderer = nil
        // The floor releases through a deferred MainActor task, so wait for
        // the count to drop instead of asserting synchronously.
        let start = Date()
        while ShaderDiscovery.shared.cachedLibraryCount > 0,
              Date().timeIntervalSince(start) < 5 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(ShaderDiscovery.shared.cachedLibraryCount, 0)
    }

    #if os(macOS)
    @MainActor
    func testDrawnWindowReleasesAndRecreatesActualDrawable() throws {
        let shader = try preset()
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = ShaderLayerView(frame: CGRect(x: 0, y: 0, width: 640, height: 400), device: nil)
        window.contentView = view
        window.orderFront(nil)
        defer { view.tearDown(); window.close() }
        for _ in 0..<3 {
            view.apply(shader: shader, isPlaying: true, palette: .fallback)
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertNotNil(view.device)
            // Allocate and present the actual surface, not just a mock renderer.
            try autoreleasepool {
                let drawable = try XCTUnwrap(view.currentDrawable)
                XCTAssertGreaterThan(drawable.texture.width, 1)
                view.draw()
            }
            // Disable while GPU work may still be in flight: dropping the
            // renderer is safe because Metal retains its command resources,
            // not the renderer, until the submitted command completes.
            let oldRenderer = WeakRenderer(view.delegate as? ShaderRenderer)
            view.apply(shader: nil, isPlaying: true, palette: .fallback)
            XCTAssertNil(oldRenderer.value)
            XCTAssertNil(view.device)
            XCTAssertNil(view.currentDrawable, "disabled view must not allocate a replacement surface")
            XCTAssertEqual(ShaderDiscovery.shared.cachedLibraryCount, 0)
        }
    }
    #endif
}
