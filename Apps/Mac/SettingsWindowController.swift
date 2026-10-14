import AppKit
import ComposableArchitecture
import KumoneTCA
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(store: StoreOf<AppFeature>) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.title = String(localized: "设置")
        window.contentViewController = NSHostingController(
            rootView: SettingsView(
                store: store.scope(state: \.settings, action: \.settings),
                appStore: store))
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
