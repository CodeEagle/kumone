import Combine
import KumoneUI
import SwiftUI

/// A small window that renders a parsed screen as a live preview.
///
/// The M0 vehicle: `ScreenView` renders the parsed node tree; this window
/// just puts it on screen. Built so config changes (from the file watcher)
/// appear immediately — the source of truth is the YAML, never the window.
@MainActor
final class ConfigPreviewWindow: NSWindow {
    private weak var configStore: ConfigStore?

    init(screen name: String, configStore: ConfigStore, resolver: BindingResolver?) {
        self.configStore = configStore

        // The window's content view is driven by an ObservableObject, so
        // re-rendering on `screens` changes happens through SwiftUI itself.
        let content = ConfigPreviewContent(name: name, configStore: configStore)
            .environment(\.bindingResolver, resolver)
        let hosting = NSHostingController(rootView: content)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        title = "配置预览 — \(name)"
        contentView = hosting.view
        isReleasedWhenClosed = false  // keep one instance alive per app

        // Simple lifecycle: re-rendering handled by SwiftUI on @Published
        // change. We forward the publisher through.
        // (KVO-style observation avoided; the content view observes
        //  configStore.screens directly.)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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
