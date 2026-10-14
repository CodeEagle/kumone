import AppKit
import ComposableArchitecture
import KumoneCore
import KumoneTCA

@MainActor
final class MainWindowController: NSWindowController {
    /// Creates the main window programmatically with the shared application store.
    init(store: StoreOf<AppFeature>) {
        let window = KumoneWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 703),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        super.init(window: window)
        window.title = "MiuMiu"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.contentViewController = MainContainerViewController(store: store)
        window.setContentSize(NSSize(width: 1080, height: 703))
        // This AppKit shell does not use KumoneApp's SwiftUI Window scene,
        // so enforce its content minimum on the native window directly.
        // Keep it stable when the sidebar or now-playing page changes.
        window.contentMinSize = NSSize(width: ThemeTokens.Layout.minWindowWidth,
                                       height: ThemeTokens.Layout.minWindowHeight)
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// The main window corrects its own title as writes arrive. The SwiftUI scene
/// bridge (`hosting.sceneBridgingOptions = [.title]` in
/// `MainContainerViewController`) keeps rewriting `window.title` with the root
/// view's `navigationTitle` — the pushed pages render as overlays outside any
/// navigation container, so their titles never become the scene title and the
/// bridge's writes would strand the window on the root's name. Every write
/// funnels through `setTitle:`, so mapping the value here corrects the
/// bridge's writes synchronously (the correction is always the last write):
/// while the detail stack is up the title follows the topmost page, and when
/// the stack is empty the correction is nil and the bridge's own value — the
/// root's title — stands.
final class KumoneWindow: NSWindow {
    /// Maps an about-to-be-set title to the one that should actually show.
    /// `nil` passes the original through unchanged.
    var titleCorrection: ((String) -> String?)?
    var isImmersiveChromeHidden = false

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if isImmersiveChromeHidden,
           menuItem.action == #selector(NSWindow.performClose(_:)),
           styleMask.contains(.closable) {
            return true
        }
        return super.validateMenuItem(menuItem)
    }

    override func performClose(_ sender: Any?) {
        guard isImmersiveChromeHidden,
              styleMask.contains(.closable),
              let close = standardWindowButton(.closeButton) else {
            super.performClose(sender)
            return
        }
        // AppKit also rejects a fully transparent close button. Restore its
        // alpha only during the synchronous command/delegate dispatch; no
        // rendered frame exposes the button, and windowShouldClose still runs.
        let alpha = close.alphaValue
        close.alphaValue = 1
        close.isEnabled = true
        defer { close.alphaValue = alpha }
        super.performClose(sender)
    }

    override var title: String {
        get { super.title }
        set { super.title = titleCorrection?(newValue) ?? newValue }
    }
}
