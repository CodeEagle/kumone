import AppKit
import ComposableArchitecture
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
        window.title = "Kumone"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.contentViewController = MainContainerViewController(store: store)
        window.setContentSize(NSSize(width: 1080, height: 703))
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

    override var title: String {
        get { super.title }
        set { super.title = titleCorrection?(newValue) ?? newValue }
    }
}
