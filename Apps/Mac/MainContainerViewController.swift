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
        let toolbar = window.toolbar
        let isVisible = !store.isNowPlayingPresented
        logToolbar("hasToolbar=\(toolbar != nil) presented=\(store.isNowPlayingPresented) target=\(isVisible) current=\(toolbar?.isVisible ?? false)")
        guard let toolbar, toolbar.isVisible != isVisible else { return }
        toolbar.isVisible = isVisible
        logToolbar("set isVisible -> \(isVisible)")
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
        root.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: root.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
    }
}
