import ComposableArchitecture
@_spi(Internals) import ComposableArchitecture
import KumoneCore
import SwiftUI

#if os(macOS)
import AppKit
#endif

public struct MainWindow: View {
    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    @SwiftUI.Bindable var store: StoreOf<AppFeature>

    #if os(macOS)
    @StateObject private var artworkStore = NowPlayingArtworkStore()
    @ObservedObject private var imageLoading = ImageLoadingControl.shared
    @ObservedObject private var shaderSettings = ShaderSettings.shared
    @ObservedObject private var shaderLibrary = ShaderLibrary.shared
    #else
    @EnvironmentObject private var artworkStore: NowPlayingArtworkStore
    #endif
    @State private var detailWidth: CGFloat = 0
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var visibilityBeforeNowPlaying: NavigationSplitViewVisibility?
    #if os(macOS)
    @StateObject private var topScrollProgress = TopScrollProgress()
    #endif

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 200, ideal: Theme.Layout.sidebarWidth, max: 280)
        } detail: {
            detailStack
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    detailWidth = width
                }
        }
        #if os(macOS)
        // NavigationSplitView installs private Liquid Glass views inside the
        // hosting hierarchy. The shader lives below that hierarchy at the
        // AppKit window level, so leave the SwiftUI surfaces transparent and
        // keep the AppKit backdrop underneath as the fallback background.
        .background(WindowGlassDisabler())
        .background(TopScrollProgressProbe(progress: topScrollProgress))
        #endif
        .navigationSplitViewStyle(.balanced)
        // Blurred top fade: content softens out before it reaches the window
        // titlebar instead of colliding with the Liquid Glass toolbar. Fades
        // out with the rest of the navigation chrome while now-playing is up.
        .topFadeBlur(
            progress: {
                #if os(macOS)
                topScrollProgress.value
                #else
                0
                #endif
            }()
        )
        // The immersive page is the only visible surface while it is up: the
        // underlying navigation content fades out (layout and frames survive,
        // so the hero anchors on the mini player keep measuring) and the
        // window-level shader shows through the page's thin readability veil.
        // The fade is quicker than the page's spring: clearing the stage fast
        // lets the hero flight's bounce read as the entrance.
        .opacity(store.isNowPlayingPresented ? 0 : 1)
        .animation(AppAnimation.quick, value: store.isNowPlayingPresented)
        .toolbar {
            // macOS: the search field is owned by the AppKit shell
            // (MainContainerViewController's own NSToolbar item), NOT by
            // SwiftUI. macOS has no trailing toolbar placement and the
            // bridged spacer was dropped by the split-view bridge, so the
            // SwiftUI item drifted to the left edge and could not be parked
            // top-right. iOS keeps the SwiftUI item: `.primaryAction` is the
            // trailing edge there.
            #if os(iOS)
            ToolbarItem(placement: searchToolbarPlacement) {
                SearchFieldView { query in
                    store.animateOpen(.search(query))
                }
                .opacity(store.isNowPlayingPresented ? 0 : 1)
                .allowsHitTesting(!store.isNowPlayingPresented)
                .transaction { transaction in
                    transaction.animation = nil
                }
            }
            #endif
        }
        #if os(macOS)
        // Keep the single main window alive on Cmd+W / red button so the Dock
        // icon can always bring it back (#60/#63/#66/#70).
        .background(
            MainWindowConfigurator()
        )
        #endif
        .playerChrome(appStore: store, detailWidth: detailWidth)
        .environment(\.openLogin, { store.send(.presentLogin) })
        .environment(\.openDestination, openDestination)
        .environment(\.appStore, store)
        #if os(macOS)
        .environmentObject(artworkStore)
        #endif
        .task {
            store.send(.onAppear)
#if os(macOS)
            artworkStore.setArtworkNeeded(needsCurrentArtwork)
#endif
            DesktopLyricsController.shared.sync(with: store.settings.showDesktopLyrics, store: store)
        }
        #if os(macOS)
        // The sidebar toggle: the shell installs it as a borderless
        // button in the traffic-light row (MainContainerViewController).
        .onReceive(NotificationCenter.default.publisher(for: .kumoneToggleSidebar)) { _ in
            withAnimation(AppAnimation.smooth) {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
        }
        #endif
        .onChange(of: store.settings.showDesktopLyrics) { _, enabled in
            DesktopLyricsController.shared.sync(with: enabled, store: store)
        }
        #if os(macOS)
        .onChange(of: store.settings.showMainWindowAmbientBackground) { _, _ in
            artworkStore.setArtworkNeeded(needsCurrentArtwork)
        }
        // The immersive page is the bigger artwork consumer: dismissing it
        // without this lets the store keep the last decoded 768pt cover
        // alive forever (memory never drops after closing the page).
        .onChange(of: store.isNowPlayingPresented) { _, _ in
            artworkStore.setArtworkNeeded(needsCurrentArtwork)
        }
        .onChange(of: store.shaderID) { _, _ in
            artworkStore.setArtworkNeeded(needsCurrentArtwork)
        }
        .onChange(of: store.settings.disableImageLoading) { _, _ in
            artworkStore.setArtworkNeeded(needsCurrentArtwork)
        }
        .onChange(of: imageLoading.isDisabled) { _, _ in
            artworkStore.setArtworkNeeded(needsCurrentArtwork)
        }
        #endif
        // Collapse the sidebar while the immersive page is open: the split
        // view's divider keeps its resize-cursor rect active even underneath
        // an overlay, leaking the drag cursor onto the now-playing page (#6).
        .onChange(of: store.isNowPlayingPresented) { _, isPresented in
            #if os(macOS)
            artworkStore.setArtworkNeeded(needsCurrentArtwork)
            #endif
            // Capture the outgoing page before restoring the split layout.
            if !isPresented {
                flyBackToMiniPlayer()
            }
            var layoutTransaction = Transaction()
            layoutTransaction.disablesAnimations = true
            withTransaction(layoutTransaction) {
                if isPresented {
                    visibilityBeforeNowPlaying = columnVisibility
                    columnVisibility = .detailOnly
                } else {
                    columnVisibility = visibilityBeforeNowPlaying ?? .all
                    visibilityBeforeNowPlaying = nil
                }
            }
        }
        .task(id: store.isNowPlayingPresented) {
            await ArtworkLifetimeDiagnostics.sampleAfterTransition(
                reason: store.isNowPlayingPresented ? "detail-open" : "detail-closed")
        }
        .onChange(of: store.player.currentTrack) { _, track in
            artworkStore.update(trackID: track?.id, artworkURL: track?.album.picUrl)
        }
        .sheet(isPresented: loginBinding) {
            LoginSheet(store: store.scope(state: \.login, action: \.login), appStore: store)
        }
        .overlay {
            if store.isNowPlayingPresented {
                #if os(macOS)
                NowPlayingView(
                    onOpenDestination: openDestination
                )
                    .environment(\.appStore, store)
                    .environmentObject(artworkStore)
                    // Resolve the page at the boundary, including artwork
                    // inserted asynchronously while the transition is running.
                    .geometryGroup()
                    // The Hero flight owns the spatial animation. A scale
                    // transition here changes every target's global frame
                    // after the flight has settled, causing a visible second
                    // snap. Keep the page transition non-geometric.
                    .transition(.opacity)
                #else
                NowPlayingView(
                    onOpenDestination: openDestination
                )
                    .environment(\.appStore, store)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                #endif
            }
        }
        // The page springs in (opacity plus a gentle scale): the underlying
        // content is already gone by the time this settles, so this spring is
        // the bounce of the entrance.
        .animation(AppAnimation.spring, value: store.isNowPlayingPresented)
        .overlay(alignment: .top) {
            if let toast = store.toasts.current {
                ToastView(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 12)
            }
        }
        .animation(AppAnimation.smooth, value: store.isNowPlayingPresented)
        .animation(.spring(duration: 0.3), value: store.toasts.current)
        .heroFlightOverlay()
        #if os(macOS)
        // Keep Metal in the same composition tree as the immersive overlay.
        // An external MTKView can draw successfully beneath an opaque SwiftUI
        // hosting surface without any of its pixels reaching the window.
        .background {
            ShaderContainerView(
                shader: store.settings.showMainWindowAmbientBackground
                    ? shaderLibrary.available.first(where: { $0.id == store.shaderID }) : nil,
                isPlaying: store.player.isPlaying,
                palette: ShaderPaletteBuilder.make(from: artworkStore.colors),
                pcmSync: shaderSettings.pcmSyncEnabled
            )
            .opacity(min(max(store.settings.mainWindowAmbientBackgroundIntensity, 0), 1))
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        #endif
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { store.isLoginPresented },
            set: { store.send($0 ? .presentLogin : .dismissLogin) }
        )
    }

    private var searchToolbarPlacement: ToolbarItemPlacement {
        // iOS only: macOS routes the search field through the AppKit shell
        // (see the toolbar above and MainContainerViewController).
        .primaryAction
    }

    private var detailStack: some View {
        // The detail pages render above the root, not pushed into a
        // NavigationStack. SwiftUI's macOS push is a slide transition whose
        // travelling container is opaque, so the moment the push starts a
        // black sheet covers the feed while the hero cover is still flying
        // over it — the `isFlying` opacity gate cannot fix it, because a
        // transparent page over a black container still reads as black.
        // Rendering the stack as overlays gives the pages the same
        // non-geometric presentation NowPlayingView already uses (its own
        // comment: "Keep the page transition non-geometric"): the root stays
        // put under the flying artwork, and each pushed page fades in once
        // its cover has landed. The multi-level stack still works — every
        // pushed page is its own overlay layer, and popping removes the top
        // one. Element stores come from the same `scope(component:)` helper
        // the library's NavigationStack destination uses.
        rootView
            .overlay(alignment: .topLeading) {
                // Scoping a stack state this way is what the library's own
                // NavigationStack destination does under the hood; every
                // component store is cached, so re-running this closure per
                // redraw is cheap.
                let pathStore = store.scope(state: \.path, action: \.path)
                let components = zip(store.path.ids, store.path)
                    .map { StackState<AppFeature.Path.State>.Component(id: $0, element: $1) }
                ForEach(components, id: \.id) { component in
                    Self.destinationView(
                        pathStore.scope(component: component),
                        appStore: store
                    )
                    // Insertion carries *no* opacity animation of its own:
                    // the transition engine drives the inserting view's
                    // opacity directly (0→1) for the animation's duration,
                    // which bypasses the page's own `hasAppeared` gate — the
                    // page would flash visible at the push and snap back to
                    // gated-invisible when the animation commits, before the
                    // cover's flight has launched. The page's arrival fade is
                    // owned entirely by that gated state, so insertion is
                    // identity; only the pop keeps a fade.
                    .transition(.asymmetric(insertion: .identity, removal: .detailFade))
                }
            }
            .animation(AppAnimation.smooth, value: store.path.count)
    }

    /// Flies the Now Playing artwork back to the mini player on dismiss, so the
    /// page does not merely fade out. Both frames are read from the frame store
    /// under their own ids, which survive until the dismiss; the stand-in lives
    /// in the topmost overlay, so it keeps flying after the page is gone and
    /// lands on the mini artwork, which reappears as the stand-in vanishes.
    private func flyBackToMiniPlayer() {
        for pair in HeroID.nowPlayingPairs {
            guard let sourceFrame = HeroFrameStore.shared.frame(for: pair.target),
                  let miniFrame = HeroFlightDirector.shared.miniHomeFrames[pair.source]
                    ?? HeroFrameStore.shared.frame(for: pair.source)
            else {
                // FM and non-FM button groups are mutually exclusive, so a pair
                // whose anchor never registered is skipped on purpose; this line
                // names it so a run missing a return flight is triageable from
                // the log alone.
                KumoneLogger.hero.notice(
                    "HERO flyback skip \(pair.source, privacy: .public) target=\(HeroFrameStore.shared.frame(for: pair.target) != nil, privacy: .public) miniHome=\(HeroFlightDirector.shared.miniHomeFrames[pair.source] != nil, privacy: .public) miniStore=\(HeroFrameStore.shared.frame(for: pair.source) != nil, privacy: .public)"
                )
                continue
            }
            let isArtwork = pair.source == HeroID.nowPlayingArtwork
            let content: HeroContent
            switch pair.source {
            case HeroID.nowPlayingArtwork:
                content = .artwork(url: store.player.currentTrack?.album.picUrl?.resizedImageURL(768), cornerRadius: Theme.Radius.small)
            case HeroID.nowPlayingPlayPause:
                content = .icon(name: store.player.isPlaying ? "pause.fill" : "play.fill",
                                tint: .white, background: .accent, diameter: 30, fontSize: 12.5)
            case HeroID.nowPlayingPrevious:
                guard !store.player.isFMMode else { continue }
                content = .icon(name: "backward.fill", tint: .primary, background: .none, diameter: 26, fontSize: 14, weight: .medium)
            case HeroID.nowPlayingNext:
                content = .icon(name: "forward.fill", tint: .primary, background: .none, diameter: 26, fontSize: 14, weight: .medium)
            case HeroID.nowPlayingLike:
                guard let track = store.player.currentTrack else { continue }
                let liked = store.account.isLiked(track.id)
                content = .icon(name: liked ? "heart.fill" : "heart", tint: liked ? Theme.accent : .primary,
                                background: .none, diameter: 26, fontSize: 13, weight: .medium)
            case HeroID.nowPlayingShuffle:
                guard !store.player.isFMMode else { continue }
                content = .icon(name: "shuffle", tint: store.player.shuffleEnabled ? Theme.accent : .primary,
                                background: .none, diameter: 26, fontSize: 12, weight: .medium)
            case HeroID.nowPlayingRepeat:
                guard !store.player.isFMMode else { continue }
                content = .icon(name: store.player.repeatMode == .one ? "repeat.1" : "repeat",
                                tint: store.player.repeatMode != .off ? Theme.accent : .primary,
                                background: .none, diameter: 26, fontSize: 12, weight: .medium)
            case HeroID.nowPlayingFMTrash:
                guard store.player.isFMMode else { continue }
                content = .icon(name: "trash", tint: .primary, background: .none, diameter: 26, fontSize: 12, weight: .medium)
            case HeroID.nowPlayingTitle:
                content = .playerTitle(
                    store.player.currentTrack?.name ?? String(localized: "未在播放")
                )
            case HeroID.nowPlayingVIP:
                guard store.player.currentTrack?.fee == 1 else { continue }
                content = .vipBadge
            case HeroID.nowPlayingArtist:
                content = .text(
                    store.player.currentTrack?.artistNames ?? "miumiu",
                    color: .secondary, fontSize: 11
                )
            case HeroID.nowPlayingLyrics:
                content = .icon(
                    name: "quote.bubble",
                    tint: store.player.activePanel == .lyrics ? Theme.accent : .primary,
                    background: .none, diameter: 26, fontSize: 13, weight: .medium
                )
            case HeroID.nowPlayingAirPlay:
                content = .routePicker(diameter: 26, glyphSize: 13,
                                       tint: .secondary, background: .clear)
            case HeroID.nowPlayingRoaming:
                content = .icon(
                    name: "wave.3.right.circle.fill",
                    tint: Theme.accent, background: .none,
                    diameter: 26, fontSize: 13, weight: .semibold
                )
            default:
                continue
            }
            HeroProbe.shared.begin(pair.source)
            HeroProbe.shared.recordSource(
                id: pair.source, frame: sourceFrame,
                scale: isArtwork && !store.player.isPlaying ? 0.95 : 1,
                cornerRadius: isArtwork ? 18 : (pair.source == HeroID.nowPlayingPlayPause ? 29 : 20)
            )
            HeroProbe.shared.recordTarget(
                id: pair.source, frame: miniFrame, scale: 1, cornerRadius: content.cornerRadius
            )
            HeroFlightDirector.shared.start(
                id: pair.source, content: content, targetFrame: miniFrame, targetScale: 1,
                targetAnchorID: pair.source
            )
        }
    }

    private func openDestination(_ destination: Destination) {
        #if os(macOS)
        guard store.isNowPlayingPresented else {
            store.animateOpen(destination)
            return
        }

        withAnimation(AppAnimation.smooth, completionCriteria: .removed) {
            _ = store.send(.dismissNowPlaying)
        } completion: {
            store.animateOpen(destination)
        }
        #else
        store.send(.dismissNowPlaying)
        store.animateOpen(destination)
        #endif
    }

    @ViewBuilder
    private var rootView: some View {
        switch store.selection {
        case .home:
            HomeView(store: store.scope(state: \.home, action: \.home), appStore: store)
        case .explore:
            ExploreView(store: store.scope(state: \.explore, action: \.explore), appStore: store)
        case .fm:
            FMView(appStore: store)
        case .search:
            // iPad search entry: SearchView's `.searchable` bar surfaces in the
            // detail nav bar (the desktop toolbar search field doesn't render on
            // iPad). (#59)
            SearchView(store: store.scope(state: \.search, action: \.search), appStore: store)
        case .likedSongs:
            if let playlist = store.account.likedSongsPlaylist {
                PlaylistDetailView(
                    store: store.scope(state: \.playlistRoot, action: \.playlistRoot),
                    appStore: store
                )
                .id(playlist.id)
            } else {
                loginPrompt
            }
        case .daily:
            DailySongsView(store: store.scope(state: \.daily, action: \.daily), appStore: store)
        case .recents:
            RecentsView(store: store.scope(state: \.recents, action: \.recents), appStore: store)
        case .collections:
            CollectionsView(store: store.scope(state: \.collections, action: \.collections), appStore: store)
        case .cloud:
            CloudView(store: store.scope(state: \.cloud, action: \.cloud), appStore: store)
        case .playlist:
            PlaylistDetailView(
                store: store.scope(state: \.playlistRoot, action: \.playlistRoot),
                appStore: store
            )
        }
    }

    @ViewBuilder
    static func destinationView(
        _ pathStore: StoreOf<AppFeature.Path>,
        appStore: StoreOf<AppFeature>
    ) -> some View {
        switch pathStore.case {
        case .playlist(let detail):
            PlaylistDetailView(store: detail, appStore: appStore)
        case .radarPlaylist(let detail):
            PlaylistDetailView(store: detail, appStore: appStore, recommendationContext: .radar)
        case .album(let album):
            AlbumDetailView(store: album, appStore: appStore)
        case .artist(let artist):
            ArtistDetailView(store: artist, appStore: appStore)
        case .search(let search):
            SearchView(store: search, appStore: appStore)
        case .daily(let daily):
            DailySongsView(store: daily, appStore: appStore)
        case .recents(let recents):
            RecentsView(store: recents, appStore: appStore)
        case .collections(let collections):
            CollectionsView(store: collections, appStore: appStore)
        case .cloud(let cloud):
            CloudView(store: cloud, appStore: appStore)
        case .toplists(let toplists):
            ToplistsView(store: toplists, appStore: appStore)
        }
    }

    private var loginPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart.circle")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("登录后查看你喜欢的音乐")
                .font(.headline)
            Button("登录") { store.send(.presentLogin) }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    #if os(macOS)
    private var needsCurrentArtwork: Bool {
        !store.settings.disableImageLoading && !imageLoading.isDisabled && NowPlayingArtworkStore.needsArtwork(
            backgroundEnabled: store.settings.showMainWindowAmbientBackground,
            shaderID: store.shaderID,
            isNowPlayingPresented: store.isNowPlayingPresented)
    }
    #endif
}

#if os(macOS)
/// Removes system background surfaces from the SwiftUI host without touching
/// the AppKit backdrop or the Metal shader behind it.
private struct WindowGlassDisabler: NSViewRepresentable {
    private final class ProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleApply()
        }

        override func layout() {
            super.layout()
            scheduleApply()
        }

        private func scheduleApply() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                WindowGlassDisabler.apply(from: self)
            }
        }
    }

    func makeNSView(context: Context) -> NSView {
        ProbeView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(from: nsView) }
    }

    private static func apply(from view: NSView) {
        guard let host = hostingView(above: view) else { return }
        host.layer?.backgroundColor = NSColor.clear.cgColor
        clearSurfaces(in: host)
    }

    private static func hostingView(above view: NSView) -> NSView? {
        var current: NSView? = view
        while let candidate = current {
            if NSStringFromClass(type(of: candidate)).contains("NSHostingView") {
                return candidate
            }
            current = candidate.superview
        }
        return view.window?.contentView?.subviews.first(where: {
            NSStringFromClass(type(of: $0)).contains("NSHostingView")
        })
    }

    private static func clearSurfaces(in view: NSView) {
        if let effect = view as? NSVisualEffectView {
            effect.material = .underWindowBackground
            // These effects sit ABOVE the native Metal layer. Behind-window
            // sampling ignores that layer and replaces it with desktop glass
            // when SwiftUI recreates a surface; sample our window instead.
            // Keep the view and its children alive (hiding it loses sidebar UI).
            effect.blendingMode = .withinWindow
            effect.state = .active
        }
        if let scroll = view as? NSScrollView {
            scroll.drawsBackground = false
            scroll.backgroundColor = .clear
            scroll.contentView.drawsBackground = false
            scroll.contentView.backgroundColor = .clear
        }
        // SwiftUI also uses backing layers for Circle/Shape fills. Clearing
        // every descendant layer erases button backgrounds until SwiftUI
        // redraws them, including controls outside the Hero transition.
        for child in view.subviews {
            clearSurfaces(in: child)
        }
    }
}
#endif

#if os(macOS)
// MARK: - Main window configurator

/// Grabs the single main `NSWindow` once it exists and installs a close
/// interceptor: Cmd+W / the red button *hide* the window (`orderOut`) instead
/// of destroying it. The native AppKit shell retains the window controller
/// and restores the window on a Dock click. Every other window-delegate
/// callback is forwarded untouched to the existing delegate.
struct MainWindowConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(from: view)
        }
        return view
    }

    func updateNSView(_ nsview: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(from: nsview)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private(set) weak var window: NSWindow?
        private weak var forwardee: NSWindowDelegate?
        private weak var attachHost: NSView?
        private var hasScheduledAttach = false

        func attach(to window: NSWindow?) {
            guard let window, self.window == nil else { return }
            self.window = window
            window.isReleasedWhenClosed = false
            // Insert ourselves as the delegate, forwarding to whatever
            // delegate SwiftUI installed.
            if window.delegate !== self {
                forwardee = window.delegate
                window.delegate = self
            }
        }

        func attach(from host: NSView) {
            attachHost = host
            guard !hasScheduledAttach else { return }
            hasScheduledAttach = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hasScheduledAttach = false
                guard let host = self.attachHost else { return }
                self.attach(to: host.window)
            }
        }

        // Hide instead of close; keep the scene alive.
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.orderOut(nil)
            return false
        }

        // Activation must not restore keyboard focus to the toolbar's search
        // capsule: AppKit brings the window back as key and reinstates its
        // saved first responder, so a field the user once typed into lights
        // up (focused stroke, caret) without any click. The same applies to
        // any text field in the content; only an explicit click should
        // focus one.
        func windowDidBecomeKey(_ notification: Notification) {
            guard let window, window.firstResponder is NSTextView else { return }
            window.makeFirstResponder(nil)
        }

        // Transparently forward every other delegate callback to SwiftUI.
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (forwardee?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if forwardee?.responds(to: aSelector) == true { return forwardee }
            return super.forwardingTarget(for: aSelector)
        }
    }
}
#endif

// MARK: - Search field

public struct SearchFieldView: View {
    public let onSubmit: (String) -> Void

    @State private var text = ""
    @State private var placeholder = "搜索音乐、歌手、专辑"
    @FocusState private var focused: Bool

    public init(onSubmit: @escaping (String) -> Void) {
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .frame(width: 168)
                .onSubmit {
                    let query = text.trimmingCharacters(in: .whitespaces)
                    let effective = query.isEmpty ? placeholderQuery : query
                    guard !effective.isEmpty else { return }
                    onSubmit(effective)
                    focused = false
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.primary.opacity(0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(focused ? 0.18 : 0.08), lineWidth: 1))
        #if os(macOS)
        // Keep the capsule off the window's rounded top-right corner (#88)
        // while keeping the visible gaps square: the toolbar adds a 4pt
        // inset on both axes, so trailing 7 + top 10 puts the capsule 11pt
        // from the window's right edge and 11pt from the top.
        .padding(.trailing, 7)
        .padding(.top, 10)
        #endif
        .animation(AppAnimation.quick, value: focused)
        .task {
            if let keyword = try? await NeteaseAPI.searchDefaultKeyword(), !keyword.isEmpty {
                placeholder = keyword
                placeholderQuery = keyword
            }
        }
    }

    @State private var placeholderQuery = ""
}

// MARK: - Toast

struct ToastView: View {
    let toast: Toast

    var body: some View {
        Text(toast.message)
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .compatGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

// MARK: - BrightnessIntent mapping

extension BrightnessIntent {
    /// The SwiftUI scheme to apply; `nil` follows the system.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Cross-object bridge for the shell toolbar's sidebar toggle: the toolbar
/// item lives in the AppKit container, the NavigationSplitView visibility
/// lives in SwiftUI, so the button posts this and the window answers.
public extension Notification.Name {
    static let kumoneToggleSidebar = Notification.Name("im.missuo.Kumone.toggleSidebar")
    static let kumoneDebugPushDetail = Notification.Name("im.missuo.Kumone.debugPushDetail")
    #if DEBUG
    static let kumoneDebugCapture = Notification.Name("im.missuo.Kumone.debugCapture")
    #endif
}

/// The detail overlay's own transition. A plain opacity fade in both
/// directions: the page — frosted background included — materialises as a
/// whole only after the cover lands (its content sits under an `isFlying`
/// gate in the detail views), and pops fade out the same way. Anything
/// fancier here — insertions that begin half-opaque, or splitting the
/// background out of that gate — put page chrome on screen ahead of the
/// landing cover or covered it, so keep it plain.
extension AnyTransition {
    static var detailFade: AnyTransition { .opacity }
}
