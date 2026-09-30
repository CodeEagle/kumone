import AppKit
import KumoneCore
import SwiftUI
import ComposableArchitecture
import KumoneTCA

@MainActor
final class MainContainerViewController: NSViewController {
    let shaderLayer = ShaderLayerView()
    private let store: StoreOf<AppFeature>

    init(store: StoreOf<AppFeature>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
