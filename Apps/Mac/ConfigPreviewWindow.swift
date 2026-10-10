import Combine
import KumoneUI
import SwiftUI

/// A window that renders a parsed screen, on the geometry the screen asks
/// for.
///
/// The screen's `window:` block (sizes, title) is applied on open and
/// re-applied live when the file watcher reloads it — editing the YAML
/// resizes and retitles the open window, the same immediacy the tree
/// inside it already has. The source of truth is always the YAML: nothing
/// here caches geometry.
@MainActor
final class ConfigPreviewWindow: NSWindow {
    private weak var configStore: ConfigStore?
    private var subscriptions: Set<AnyCancellable> = []
    private let screenName: String

    init(screen name: String,
         screenWindow: ConfigParser.ScreenWindow,
         configStore: ConfigStore,
         resolver: BindingResolver?,
         dispatcher: ActionDispatcher?) {
        self.configStore = configStore
        self.screenName = name

        // The window's content view is driven by an ObservableObject, so
        // re-rendering on `screens` changes happens through SwiftUI itself.
        let content = ConfigPreviewContent(name: name, configStore: configStore)
            .environment(\.bindingResolver, resolver)
            .environment(\.actionDispatcher, dispatcher)
        let hosting = NSHostingController(rootView: content)

        super.init(
            contentRect: NSRect(
                x: 0, y: 0,
                width: screenWindow.width ?? 420,
                height: screenWindow.height ?? 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        title = screenWindow.title ?? "配置预览 — \(name)"
        contentView = hosting.view
        // Closing drops the window from the owner's registry (its
        // willClose observer), which is what releases it — reopening the
        // screen builds a new window rather than reusing this one.
        isReleasedWhenClosed = false
        applyMinSize(screenWindow)

        // Live geometry: a window block edit reaches the open window the
        // moment the watcher reloads the file, without reopening anything.
        configStore.$screens
            .map { [weak self] screens in
                screens[self?.screenName ?? ""]?.window ?? ConfigParser.ScreenWindow()
            }
            .removeDuplicates()
            .sink { [weak self] window in self?.applyWindow(window) }
            .store(in: &subscriptions)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func applyWindow(_ window: ConfigParser.ScreenWindow) {
        applyMinSize(window)
        if let width = window.width, let height = window.height,
           width > 0, height > 0 {
            // Keep the top-left corner where the user left it; screens grow
            // down and right in the coordinate system AppKit uses.
            let frame = self.frame
            let newFrame = NSRect(
                x: frame.minX,
                y: frame.maxY - height,
                width: width,
                height: height)
            setFrame(newFrame, display: true, animate: false)
        }
        if let title = window.title {
            self.title = title
        }
    }

    private func applyMinSize(_ window: ConfigParser.ScreenWindow) {
        let minWidth = window.minWidth ?? 0
        let minHeight = window.minHeight ?? 0
        guard minWidth > 0 || minHeight > 0 else { return }
        minSize = NSSize(width: max(minWidth, 1), height: max(minHeight, 1))
    }
}

/// The SwiftUI content that reads the current screen and rebuilds when the
/// config files change.
private struct ConfigPreviewContent: View {
    let name: String
    @ObservedObject var configStore: ConfigStore

    var body: some View {
        Group {
            if let screen = configStore.screens[name] {
                ScreenView(root: screen.root, stylesheet: screen.stylesheet)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No screen named \(name)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(configStore.diagnostics.isEmpty
                        ? "Add a screens/\(name).yaml"
                        : configStore.diagnostics.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}
