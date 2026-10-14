#if os(macOS)
import AppKit
import ComposableArchitecture
import KumoneTCA
@testable import KumoneMac
import XCTest

@MainActor
final class ImmersiveWindowControlsTests: XCTestCase {
    private final class CloseDelegate: NSObject, NSWindowDelegate {
        var receivedClose = false
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            receivedClose = true
            return false
        }
    }

    func testFadedTrafficLightsStillAllowAppKitCloseCommand() async throws {
        let window = KumoneWindow(contentRect: CGRect(x: 100, y: 100, width: 600, height: 400),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let delegate = CloseDelegate()
        window.delegate = delegate
        window.orderFront(nil)
        let store = Store(initialState: AppFeature.State()) {
            Reduce<AppFeature.State, AppFeature.Action> { _, _ in .none }
        }
        let controller = MainContainerViewController(store: store)
        controller.fadeTrafficLights(on: window, presented: true)
        XCTAssertTrue(window.isImmersiveChromeHidden)
        try await Task.sleep(nanoseconds: 300_000_000)
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        XCTAssertTrue(close.isEnabled)
        // Standalone AppKit titlebars can repaint alpha during a hover. Keep
        // this test's visual condition fixed while exercising the real command.
        close.alphaValue = 0
        let menuItem = NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        XCTAssertTrue(window.isImmersiveChromeHidden)
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.validateMenuItem(menuItem))
        // This is the responder action used by the menu's Cmd+W binding.
        window.performClose(nil)
        XCTAssertTrue(delegate.receivedClose)
        controller.fadeTrafficLights(on: window, presented: false)
        XCTAssertTrue(close.isEnabled)
    }
}
#endif
