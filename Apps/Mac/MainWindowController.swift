import AppKit
import ComposableArchitecture
import KumoneTCA

@MainActor
final class MainWindowController: NSWindowController {
    /// Creates the main window programmatically with the shared application store.
    init(store: StoreOf<AppFeature>) {
        let window = NSWindow(
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
