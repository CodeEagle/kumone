import AppKit
import Combine
import KumoneCore
import SwiftUI
import ComposableArchitecture
import KumoneTCA

@MainActor
final class MainContainerViewController: NSViewController {
    let shaderLayer = ShaderLayerView()
    private let store: StoreOf<AppFeature>
    private var nowPlayingSubscription: AnyCancellable?
    private var toolbarObservation: NSKeyValueObservation?
    private var toolbarToRestore: NSToolbar?
    private var titlebarAccessoriesToRestore: [NSTitlebarAccessoryViewController] = []
    private let toolbarAnimationDuration: TimeInterval = 0.22

    init(store: StoreOf<AppFeature>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // SwiftUI's toolbar visibility preference is not always applied to a
        // toolbar bridged into a programmatically created AppKit window.
        syncToolbarVisibility()
        nowPlayingSubscription = store.publisher.isNowPlayingPresented
            .removeDuplicates()
            .sink { [weak self] _ in
                // Synchronous: deferring the sync let the bridged toolbar render
                // one visible frame, which read as the search field flickering
                // in and out between presentations.
                self?.syncToolbarVisibility()
            }
        // Bridging can install or replace the toolbar after the view appears;
        // re-sync in place (no async hop) so a freshly installed toolbar can
        // never land visible while the immersive page is up.
        toolbarObservation = view.window?.observe(\.toolbar, options: [.new]) { [weak self] _, _ in
            self?.syncToolbarVisibility()
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        nowPlayingSubscription = nil
        toolbarObservation = nil
    }

    private func syncToolbarVisibility() {
        guard let window = view.window else {
            logToolbar("no-window")
            return
        }
        let isVisible = !store.isNowPlayingPresented
        if isVisible {
            restoreTitlebarAccessories(on: window)
            if window.toolbar == nil, let toolbarToRestore {
                window.toolbar = toolbarToRestore
                self.toolbarToRestore = nil
                animateToolbarItems(toolbarToRestore, visible: true)
            }
            guard let toolbar = window.toolbar else {
                logToolbar("hasToolbar=false presented=false target=true")
                return
            }
            toolbarToRestore = nil
            logToolbar("hasToolbar=true presented=false target=true current=\(toolbar.isVisible)")
            if !toolbar.isVisible { toolbar.isVisible = true }
            return
        }

        hideTitlebarAccessories(on: window)
        if let toolbar = window.toolbar {
            toolbarToRestore = toolbar
            logToolbar("hasToolbar=true presented=true target=false current=\(toolbar.isVisible)")
            // Keep the toolbar installed while Hero measures and animates.
            // Removing it changes the content rect/titlebar height and moves
            // every now-playing target during the flight, which reads as a
            // visible jitter. Its item views are enough to hide the chrome.
            animateToolbarItems(toolbar, visible: false)
        } else {
            logToolbar("hasToolbar=false presented=true target=false")
        }
    }

    private func animateToolbarItems(
        _ toolbar: NSToolbar,
        visible: Bool,
        completion: (() -> Void)? = nil
    ) {
        let itemViews = toolbar.items.compactMap(\NSToolbarItem.view)
        if visible {
            toolbar.isVisible = true
            itemViews.forEach { $0.alphaValue = 0 }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = toolbarAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            itemViews.forEach { $0.animator().alphaValue = visible ? 1 : 0 }
        } completionHandler: {
            completion?()
        }
    }

    private func hideTitlebarAccessories(on window: NSWindow) {
        guard titlebarAccessoriesToRestore.isEmpty,
              !window.titlebarAccessoryViewControllers.isEmpty else { return }
        titlebarAccessoriesToRestore = window.titlebarAccessoryViewControllers
        let views = titlebarAccessoriesToRestore.map(\NSTitlebarAccessoryViewController.view)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = toolbarAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            views.forEach { $0.animator().alphaValue = 0 }
        }
    }

    private func restoreTitlebarAccessories(on window: NSWindow) {
        guard !titlebarAccessoriesToRestore.isEmpty else { return }
        let accessories = titlebarAccessoriesToRestore
        titlebarAccessoriesToRestore = []
        NSAnimationContext.runAnimationGroup { context in
            context.duration = toolbarAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            accessories.forEach { $0.view.animator().alphaValue = 1 }
        }
    }

    private func logToolbar(_ message: String) {
        let line = "TOOLBAR SYNC \(message)"
        KumoneLogger.hero.notice("\(line, privacy: .public)")
        let url = URL(fileURLWithPath: "/tmp/kumone-toolbar.log")
        if let data = (line + "\n").data(using: .utf8),
           let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? (line + "\n").data(using: .utf8)?.write(to: url, options: [.atomic])
        }
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        view = root

        let backdrop = NSVisualEffectView()
        backdrop.material = .sidebar
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active

        // Keep the backdrop beneath the transparent shader and foreground UI.
        for layerView in [backdrop, shaderLayer] {
            layerView.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(layerView)
            NSLayoutConstraint.activate([
                layerView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                layerView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                layerView.topAnchor.constraint(equalTo: root.topAnchor),
                layerView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
            ])
        }

        let hosting = NSHostingController(rootView: MainWindow(store: store))
        // The hosting controller is nested inside this container instead of
        // being the window's own content view, so SwiftUI does *not*
        // automatically bridge `.toolbar` items into the window's NSToolbar —
        // the window was left with an empty titlebar strip and no search field.
        // Bridging explicitly installs the toolbar (and titles) again.
        hosting.sceneBridgingOptions = [.title, .toolbars]
        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.wantsLayer = true
        hosting.view.layer?.isOpaque = false
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        root.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: root.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
    }
}
