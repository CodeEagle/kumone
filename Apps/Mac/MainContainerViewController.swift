import AppKit
import Combine
import KumoneCore
import SwiftUI
import ComposableArchitecture
import KumoneTCA

@MainActor
final class MainContainerViewController: NSViewController, NSToolbarDelegate {
    let shaderLayer = ShaderLayerView()
    private var lastShaderStackID: String?

    func logShaderStack(shaderID: String?) {
        let key = shaderID ?? "disabled"
        guard lastShaderStackID != key else { return }
        lastShaderStackID = key
        let metal = shaderLayer.layer
        let drawableLayer = shaderID == nil ? nil : shaderLayer.currentDrawable?.layer
        let layerLine = "SHADER LAYER viewLayer=\(metal.map { NSStringFromClass(type(of: $0)) } ?? "nil") drawableMatches=\(metal === drawableLayer) attached=\(metal?.superlayer != nil) drawableAttached=\(drawableLayer?.superlayer != nil) siblingLayers=\(view.layer?.sublayers?.map { NSStringFromClass(type(of: $0)) }.joined(separator: ",") ?? "nil")"
        KumoneLogger.app.notice("\(layerLine, privacy: .public)")
        func inspect(_ candidate: NSView, depth: Int) {
            guard depth <= 8 else { return }
            let background = candidate.layer?.backgroundColor?.components?.map { String(format: "%.2f", $0) }.joined(separator: ",") ?? "nil"
            let effect = (candidate as? NSVisualEffectView).map { " blend=\($0.blendingMode.rawValue) material=\($0.material.rawValue)" } ?? ""
            let line = "SHADER STACK depth=\(depth) type=\(NSStringFromClass(type(of: candidate))) frame=\(candidate.frame) hidden=\(candidate.isHidden) alpha=\(candidate.alphaValue) opaque=\(candidate.isOpaque) bg=\(background) children=\(candidate.subviews.count)\(effect)"
            KumoneLogger.app.notice("\(line, privacy: .public)")
            for child in candidate.subviews { inspect(child, depth: depth + 1) }
        }
        inspect(view, depth: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let layers = self.view.layer?.sublayers?.map { layer in
                let name = self.view.subviews.first(where: { $0.layer === layer }).map { NSStringFromClass(type(of: $0)) } ?? NSStringFromClass(type(of: layer))
                return "\(name):z=\(layer.zPosition):hidden=\(layer.isHidden):frame=\(layer.frame)"
            }.joined(separator: ";") ?? "nil"
            let line = "SHADER ATTACH settled rootWantsLayer=\(self.view.wantsLayer) rootLayer=\(self.view.layer != nil) rootWindow=\(self.view.window != nil) metalWindow=\(self.shaderLayer.window != nil) metalParent=\(self.shaderLayer.layer?.superlayer != nil) metalWantsLayer=\(self.shaderLayer.wantsLayer) layers=\(layers)"
            KumoneLogger.app.notice("\(line, privacy: .public)")
        }
    }
    private let store: StoreOf<AppFeature>
    private var nowPlayingSubscription: AnyCancellable?
    private var toolbarObservation: NSKeyValueObservation?
    private var toolbarToRestore: NSToolbar?
    private var titlebarAccessoriesToRestore: [NSTitlebarAccessoryViewController] = []
    private let toolbarAnimationDuration: TimeInterval = 0.22
    private var trafficLightsPresented = false
    private var trafficLightsEnabled: [ObjectIdentifier: Bool] = [:]
    /// Mirrors the main window's `columnVisibility` for the one decision the
    /// toolbar cares about: with the sidebar collapsed the toolbar's leading
    /// slot slides onto the traffic-light-row toggle and the back button's
    /// glyph needs its margin; with the sidebar open the slot already sits
    /// past the sidebar — the main window's side — and the margin only pushes
    /// the button right of where it belongs.
    private var sidebarCollapsed = false
    private var sidebarToggleObserver: NSObjectProtocol?

    // The shell-owned toolbar that pins the search field top-right:
    // [back?, flexibleSpace, search]. See installSearchToolbar().
    private static let searchItemIdentifier = NSToolbarItem.Identifier("im.missuo.Kumone.search")
    private static let backItemIdentifier = NSToolbarItem.Identifier("im.missuo.Kumone.navigate-back")
    private var searchToolbar: NSToolbar?
    /// The sidebar toggle button in the traffic-light row (see
    /// installSidebarToggle). Faded with the system buttons.
    private var sidebarToggleButton: NSButton?
    private var pathSubscription: AnyCancellable?

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
        installSearchToolbar()
        installSidebarToggle()
        syncToolbarVisibility()
        sidebarToggleObserver = NotificationCenter.default.addObserver(
            forName: .kumoneToggleSidebar, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sidebarCollapsed.toggle()
                self.applyBackButtonLayout(animating: true)
            }
        }
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
            Task { @MainActor [weak self] in
                self?.syncToolbarVisibility()
            }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if let sidebarToggleObserver {
            NotificationCenter.default.removeObserver(sidebarToggleObserver)
            self.sidebarToggleObserver = nil
        }
        nowPlayingSubscription = nil
        toolbarObservation = nil
        pathSubscription = nil
    }

    private func syncToolbarVisibility() {
        rearmTitlebarButtons()
        guard let window = view.window else {
            logToolbar("no-window")
            return
        }
        let isVisible = !store.isNowPlayingPresented
        fadeTrafficLights(on: window, presented: !isVisible)
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
            let hasHiddenItems = toolbar.items.contains { item in
                guard let view = item.view else { return false }
                return view.isHidden || view.alphaValue < 0.99
            }
            if !toolbar.isVisible || hasHiddenItems {
                animateToolbarItems(toolbar, visible: true)
            } else {
                toolbar.isVisible = true
            }
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
            // Keep its height reserved through both directions of the flight.
            // The immersive controls sit below the native titlebar hit region.
        } else {
            logToolbar("hasToolbar=false presented=true target=false")
        }
    }

    /// The titlebar can rebuild its button container (style changes,
    /// fullscreen transitions) and drop the toggle with it; re-install it
    /// wherever the synchronization points run.
    private func rearmTitlebarButtons() {
        if sidebarToggleButton?.superview == nil {
            installSidebarToggle()
        }
    }

    private func fadeTrafficLights(on window: NSWindow, presented: Bool) {
        guard trafficLightsPresented != presented else { return }
        trafficLightsPresented = presented
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            + (sidebarToggleButton.map { [$0] } ?? [])
        for button in buttons {
            if presented {
                trafficLightsEnabled[ObjectIdentifier(button)] = button.isEnabled
                button.isEnabled = false
            } else {
                button.isEnabled = trafficLightsEnabled[ObjectIdentifier(button)] ?? true
            }
        }
        // Alpha only: retain the titlebar slots and Hero coordinate space.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = toolbarAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            buttons.forEach { $0.animator().alphaValue = presented ? 0 : 1 }
        }
        KumoneLogger.hero.notice("TRAFFIC LIGHTS presented=\(presented) targetAlpha=\(presented ? 0 : 1) buttons=\(buttons.count)")
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
        accessories.forEach { $0.view.isHidden = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = toolbarAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            accessories.forEach { $0.view.animator().alphaValue = 1 }
        }
    }

    private func logToolbar(_ message: String) {
        let line = "TOOLBAR SYNC \(message)"
        KumoneLogger.hero.notice("\(line, privacy: .public)")
        BoundedLogFile.append(line, to: URL(fileURLWithPath: "/tmp/kumone-toolbar.log"))
    }

    /// Installs the sidebar toggle among the window's standard titlebar
    /// buttons: on the traffic lights' row, to their right, above the
    /// sidebar — the slot the system NavigationSplitView toggle used to fill
    /// before d1bcd89 dropped the bridged toolbar. The toolbar's own items
    /// land centered over the detail column, and the titlebar-accessory API
    /// is unusable on macOS 27 (the property's setter no longer exists — an
    // ObjC exception swallowed by the run loop that silently kills the rest
    /// of viewDidAppear — and `addTitlebarAccessoryViewController:` breaks
    /// the window's accessibility surface), so the buttons' container is the
    /// one deterministic slot left. Window-level: the button survives the
    /// sidebar's own collapse and can bring the column back.
    private func installSidebarToggle() {
        if let existing = sidebarToggleButton, existing.superview != nil { return }
        guard let window = view.window,
              let closeButton = window.standardWindowButton(.closeButton),
              let container = closeButton.superview else { return }
        let symbol = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "边栏")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        let button = NSButton(image: symbol ?? NSImage(),
                              target: self, action: #selector(toggleSidebar))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = "边栏"
        // The container shares the system buttons' bottom-left origin, so
        // aligning on the close button keeps the glyph on their row whatever
        // the titlebar height; the leading offset parks it one gap past the
        // last of the three.
        let last = [window.standardWindowButton(.closeButton),
                    window.standardWindowButton(.miniaturizeButton),
                    window.standardWindowButton(.zoomButton)]
            .compactMap({ $0 })
            .max(by: { $0.frame.maxX < $1.frame.maxX })
        button.frame = NSRect(
            x: (last ?? closeButton).frame.maxX + 14,
            y: closeButton.frame.minY - 2,
            width: 22,
            height: 18
        )
        container.addSubview(button)
        sidebarToggleButton = button
    }

    /// Detail pages push onto the navigation stack; a back button belongs on
    /// the main window's side. SwiftUI's own back button lived in the bridged
    /// toolbar which the shell no longer bridges (there is no trailing
    /// placement to park the search field in), so the shell provides it
    /// directly. The item's view carries a deliberate leading margin: with
    /// the sidebar collapsed the toolbar's leading slot lands on the
    /// titlebar-row sidebar toggle, and the margin parks the glyph clear of
    /// it in both column states.
    private func makeBackItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.backItemIdentifier)
        item.label = "返回"
        // NSToolbar re-lays out a custom item's view to its standard height
        // (22pt inside a 38pt row, origin y=8) — measured live via lldb as
        // frame={0,8,62,22} — so the container cannot assume its own 38pt
        // frame, and neither can the button's position. The button is hidden
        // from the container's `layout()` until the item is inserted, so the
        // centering happens both here and on every later layout pass.
        let container = BackItemContainer(frame: NSRect(x: 0, y: 0, width: 62, height: 38))
        let button = NSButton(
            image: NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "返回")!,
            target: self, action: #selector(navigateBack)
        )
        button.isBordered = false
        button.imagePosition = .imageOnly
        container.addSubview(button)
        item.view = container
        // The leading margin parks the glyph clear of the titlebar-row
        // sidebar toggle in both column states (see `sidebarCollapsed`).
        container.leadingOffset = sidebarCollapsed ? 40 : 8
        // An initial frame for the first paint; `layout()` re-centers once
        // NSToolbar resizes the container to its standard 22pt height.
        button.frame = NSRect(
            x: container.leadingOffset,
            y: (container.bounds.height - 26) / 2,
            width: 22,
            height: 26
        )
        return item
    }

    /// Positions the back button's glyph inside its item view: vertically
    /// centered in the toolbar's row (the row is 38pt tall but NSToolbar
    /// resizes the item's container to 22pt at y=8 — see
    /// `BackItemContainer`), and leading-offset per the sidebar state (see
    /// `sidebarCollapsed`). Animated when the sidebar flips so the button
    /// rides into place instead of jumping.
    private func applyBackButtonLayout(animating: Bool) {
        guard let container = searchToolbar?.items
            .first(where: { $0.itemIdentifier == Self.backItemIdentifier })?.view
            as? BackItemContainer,
            let button = container.subviews.first else { return }
        container.leadingOffset = sidebarCollapsed ? 40 : 8
        let frame = NSRect(
            x: container.leadingOffset,
            y: (container.bounds.height - 26) / 2,
            width: 22,
            height: 26
        )
        if animating {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = toolbarAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                button.animator().frame = frame
            }
        } else {
            button.frame = frame
        }
    }

    /// The main window's toolbar is assembled here, not bridged from SwiftUI:
    /// macOS exposes no trailing `ToolbarItemPlacement`, and the split-view
    /// bridge silently dropped the flexible spacer, so a SwiftUI-side search
    /// item could never be parked top-right. Owning the `NSToolbar` directly
    /// makes the item order literal: `[flexibleSpace, search]` pins the field
    /// to the toolbar's right edge regardless of window width or pushed pages.
    private func installSearchToolbar() {
        guard searchToolbar == nil, view.window?.toolbar == nil else { return }
        // The identifier version pins the layout: NSToolbar autosaves the
        // item order per identifier, so a reorder needs a fresh one to escape
        // the previously persisted order (v4 drops the back item, which sits
        // in the traffic-light row now).
        let toolbar = NSToolbar(identifier: "im.missuo.Kumone.main.v5")
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        // Setting the delegate first: NSToolbar populates its items from
        // toolbarDefaultItemIdentifiers on attach, which is the documented
        // path. Manual insertItem(withItemIdentifier:at:) tripped an AppKit
        // assertion (NSToolbar.m:1708).
        toolbar.delegate = self
        view.window?.toolbar = toolbar
        searchToolbar = toolbar
        // Follow the path so the back button appears only while there is
        // a pushed page to pop, as the system's own back button does.
        pathSubscription = store.publisher.path
            .sink { [weak self] path in
                self?.updateBackItem(present: !path.isEmpty)
            }
        updateBackItem(present: !store.path.isEmpty)
        // Self-verifying: the item order is what parks the field right.
        KumoneLogger.app.notice(
            "SEARCH toolbar items=\(toolbar.items.map { $0.itemIdentifier.rawValue }.joined(separator: ","), privacy: .public)"
        )
        // The frame lands only after the toolbar lays out; sample it once.
        // A run-loop timer, not GCD: this machine's main dispatch queue
        // never fires its asyncAfter (SF-0111).
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      let toolbar = self.view.window?.toolbar,
                      let searchView = toolbar.items
                        .first { $0.itemIdentifier == Self.searchItemIdentifier }?.view else { return }
                let frameInWindow = searchView.convert(searchView.bounds, to: nil)
                KumoneLogger.app.notice(
                    "SEARCH settled windowFrame=\(String(format: "x=%.0f y=%.0f w=%.0f h=%.0f", frameInWindow.origin.x, frameInWindow.origin.y, frameInWindow.size.width, frameInWindow.size.height), privacy: .public) windowWidth=\(self.view.window?.frame.width ?? 0, privacy: .public)"
                )
            }
        }
    }

    /// One `NSToolbarItem` hosting `SearchFieldView`, fixed-size so the
    /// toolbar cannot stretch the capsule.
    private func makeSearchItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.searchItemIdentifier)
        item.label = "搜索"
        let hosting = NSHostingView(rootView: SearchFieldView { [weak self] query in
            self?.store.send(.openDestination(.search(query)))
        })
        // Let the system measure the item from constraints (minSize/maxSize
        // are deprecated and triggered an insertion assertion).
        item.view = hosting
        return item
    }

    @objc private func navigateBack() {
        guard let id = store.path.ids.last else { return }
        store.send(.path(.popFrom(id: id)))
    }

    /// Inserts the back button at the leading edge while the stack has a page
    /// to pop, and removes it when the stack empties — both as fades, like
    /// the system back button, and positioned per the sidebar state.
    private func updateBackItem(present: Bool) {
        guard let toolbar = searchToolbar else { return }
        let existing = toolbar.items
            .firstIndex { $0.itemIdentifier == Self.backItemIdentifier }
        if present {
            if existing == nil {
                toolbar.insertItem(withItemIdentifier: Self.backItemIdentifier, at: 0)
            }
            guard let view = toolbar.items
                .first(where: { $0.itemIdentifier == Self.backItemIdentifier })?.view else { return }
            applyBackButtonLayout(animating: false)
            // A fade-out can still be in flight when the next page is pushed
            // before the removal lands (back, then straight into another
            // detail). The item is already in the toolbar, so instead of
            // skipping — which leaves it at the fade's alpha, and lets the
            // pending removal delete it from under the new page — restore it.
            guard view.alphaValue != 1 else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = toolbarAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                view.animator().alphaValue = 1
            }
        } else if let existing {
            guard let view = toolbar.items[existing].view else {
                toolbar.removeItem(at: existing)
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = toolbarAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                view.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // A page pushed while the fade-out was in flight needs the
                    // item: keep it and make sure it is visible rather than
                    // removing it from under the new page.
                    if !self.store.path.isEmpty {
                        if let view = self.searchToolbar?.items
                            .first(where: { $0.itemIdentifier == Self.backItemIdentifier })?.view {
                            view.alphaValue = 1
                        }
                        return
                    }
                    let index = self.searchToolbar?.items
                        .firstIndex { $0.itemIdentifier == Self.backItemIdentifier } ?? existing
                    self.searchToolbar?.removeItem(at: index)
                }
            }
        }
    }

    /// The sidebar toggle: the window toolbar's own items render centered
    /// over the detail column (d1bcd89 removed the bridged `.toolbars`
    /// option whose system toggle sat at the leading edge), so the toggle
    /// sits in the traffic-light row instead. Window-level, so it survives the
    /// sidebar's own collapse and can bring the column back.
    @objc private func toggleSidebar() {
        NotificationCenter.default.post(name: .kumoneToggleSidebar, object: nil)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.searchItemIdentifier: return makeSearchItem()
        case Self.backItemIdentifier: return makeBackItem()
        default: return nil
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.backItemIdentifier, .flexibleSpace, Self.searchItemIdentifier]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The toolbar's leading cluster lands over the detail column — the
        // main window's side — not over the sidebar, and it slides left past
        // the titlebar-row sidebar toggle when the sidebar collapses, so the
        // back item's view carries the margin that clears it. The default
        // chrome is the search field pinned right; the back button is *not*
        // in the defaults: it is inserted only while the navigation stack
        // holds a pushed page, like the system back button it replaces.
        [.flexibleSpace, Self.searchItemIdentifier]
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
        // The SwiftUI bridge installs its own toolbar items when `.toolbars`
        // is bridged, and on macOS there is no trailing placement to park
        // the search field right — the split-view bridge dropped the flexible
        // spacer and the item drifted left. The shell owns the toolbar now:
        // [flexibleSpace, search] pins the field to the top-right edge.
        hosting.sceneBridgingOptions = [.title]
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

/// The back button's item view. NSToolbar re-lays out a custom item view to
/// its standard 22pt height inside the 38pt row (live measurement:
/// frame={0,8,62,22}), so the button cannot be positioned once at build time
/// against the container's nominal 38pt frame — after the resize the stored
/// y would put the glyph 8pt above the row's visual centre. Re-centering on
/// every `layout()` keeps the glyph at the traffic lights' height whatever
/// height AppKit settles on, and `leadingOffset` keeps the clear-of-toggle
/// margin across the sidebar's collapse animation.
final class BackItemContainer: NSView {
    var leadingOffset: CGFloat = 8
    private let buttonSize: NSSize = NSSize(width: 22, height: 26)

    override func layout() {
        super.layout()
        guard let button = subviews.first else { return }
        button.frame = NSRect(
            x: leadingOffset,
            y: round((bounds.height - buttonSize.height) / 2),
            width: buttonSize.width,
            height: buttonSize.height
        )
    }
}
