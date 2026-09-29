import ComposableArchitecture
import KumoneCore
import SwiftUI

public struct MainWindow: View {
    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    @SwiftUI.Bindable var store: StoreOf<AppFeature>
    @Environment(\.colorScheme) private var colorScheme

    #if os(macOS)
    @StateObject private var artworkStore = NowPlayingArtworkStore()
    #else
    @EnvironmentObject private var artworkStore: NowPlayingArtworkStore
    #endif
    @State private var detailWidth: CGFloat = 0
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var visibilityBeforeNowPlaying: NavigationSplitViewVisibility?

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
        .navigationSplitViewStyle(.balanced)
        .overlay(alignment: .trailing) {
            if store.settings.showMainWindowAmbientBackground, detailWidth > 0 {
                MainWindowAmbientBackground(
                    colors: artworkStore.colors,
                    intensity: store.settings.mainWindowAmbientBackgroundIntensity
                )
                    .frame(width: detailWidth)
            }
        }
        .toolbar {
            if #available(macOS 26.0, iOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) {
                    SearchFieldView { query in
                        store.send(.openDestination(.search(query)))
                    }
                }
                // Hide the Liquid Glass shared toolbar background behind the
                // custom capsule search field, else it double-backgrounds on
                // macOS 26 (dropped by #86's toolbar rewrite, restored here).
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) {
                    SearchFieldView { query in
                        store.send(.openDestination(.search(query)))
                    }
                }
            }
        }
        #if os(macOS)
        // Immersive now-playing page: hide the whole window toolbar
        // (sidebar toggle, navigation title, search field).
        .toolbar(store.isNowPlayingPresented ? .hidden : .automatic, for: .windowToolbar)
        // Keep the single main window alive on Cmd+W / red button so the Dock
        // icon can always bring it back (#60/#63/#66/#70).
        .background(
            MainWindowConfigurator(
                ambientConfiguration: MainWindowAmbientConfiguration(
                    showsAmbientBackground: store.settings.showMainWindowAmbientBackground,
                    showsTitlebarAmbientBackground: !store.isNowPlayingPresented,
                    colors: artworkStore.colors,
                    mainColumnWidth: detailWidth,
                    intensity: store.settings.mainWindowAmbientBackgroundIntensity,
                    isDark: isDarkAppearance
                )
            )
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
        .onChange(of: store.settings.showDesktopLyrics) { _, enabled in
            DesktopLyricsController.shared.sync(with: enabled, store: store)
        }
        #if os(macOS)
        .onChange(of: store.settings.showMainWindowAmbientBackground) { _, _ in
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
            if isPresented {
                visibilityBeforeNowPlaying = columnVisibility
                columnVisibility = .detailOnly
            } else {
                columnVisibility = visibilityBeforeNowPlaying ?? .all
                visibilityBeforeNowPlaying = nil
                flyBackToMiniPlayer()
            }
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
                    // Resolve the slide at the page boundary, including artwork
                    // inserted asynchronously while the transition is running.
                    .geometryGroup()
                    // The hero flight owns the spatial animation (the artwork
                    // flying from the PlayerBar to the header); a slide-in
                    // here would race it and the hero gate would lock onto the
                    // off-screen slide start as the target.
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
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { store.isLoginPresented },
            set: { store.send($0 ? .presentLogin : .dismissLogin) }
        )
    }

    private var detailStack: some View {
        NavigationStack(path: $store.scope(\.path, action: \.path)) {
            rootView
        } destination: { pathStore in
            Self.destinationView(pathStore, appStore: store)
        }
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
                content = .artwork(url: store.player.currentTrack?.album.picUrl?.resizedImageURL(128), cornerRadius: Theme.Radius.small)
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
                // The return flight's stand-in wears the mini bar's style —
                // the marquee's 13pt medium label-colour text — so it hands
                // off to the real title as it lands.
                content = .text(
                    store.player.currentTrack?.name ?? String(localized: "未在播放"),
                    color: .primary, fontSize: 13, weight: .medium
                )
            case HeroID.nowPlayingVIP:
                guard store.player.currentTrack?.fee == 1 else { continue }
                content = .vipBadge
            case HeroID.nowPlayingArtist:
                content = .text(
                    store.player.currentTrack?.artistNames ?? "miumiu",
                    color: .secondary, fontSize: 11
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
            store.send(.openDestination(destination))
            return
        }

        withAnimation(AppAnimation.smooth, completionCriteria: .removed) {
            _ = store.send(.dismissNowPlaying)
        } completion: {
            store.send(.openDestination(destination))
        }
        #else
        store.send(.dismissNowPlaying)
        store.send(.openDestination(destination))
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
        store.settings.showMainWindowAmbientBackground || store.isNowPlayingPresented
    }

    private var isDarkAppearance: Bool {
        (store.settings.appearance.brightnessIntent.colorScheme ?? colorScheme) == .dark
    }
    #endif
}

#if os(macOS)
// MARK: - Main window configurator

/// Grabs the single main `NSWindow` once it exists and installs a close
/// interceptor: Cmd+W / the red button *hide* the window (`orderOut`) instead
/// of destroying it. The native AppKit shell retains the window controller
/// and restores the window on a Dock click. Every other window-delegate
/// callback is forwarded untouched to the existing delegate.
struct MainWindowConfigurator: NSViewRepresentable {
    let ambientConfiguration: MainWindowAmbientConfiguration

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.requestAmbientBackgroundConfiguration(
                from: view,
                ambientConfiguration: ambientConfiguration
            )
        }
        return view
    }

    func updateNSView(_ nsview: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.requestAmbientBackgroundConfiguration(
                from: nsview,
                ambientConfiguration: ambientConfiguration
            )
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private(set) weak var window: NSWindow?
        private weak var forwardee: NSWindowDelegate?
        private let ambientAppearance = MainWindowAmbientAppearanceController()
        private weak var configurationHost: NSView?
        private var pendingAmbientConfiguration: MainWindowAmbientConfiguration?
        private var hasScheduledAmbientConfiguration = false

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

        func requestAmbientBackgroundConfiguration(
            from host: NSView,
            ambientConfiguration: MainWindowAmbientConfiguration
        ) {
            configurationHost = host
            pendingAmbientConfiguration = ambientConfiguration
            guard !hasScheduledAmbientConfiguration else { return }
            hasScheduledAmbientConfiguration = true

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hasScheduledAmbientConfiguration = false
                guard let configuration = self.pendingAmbientConfiguration else { return }
                self.pendingAmbientConfiguration = nil
                self.attach(to: self.configurationHost?.window)
                guard let window = self.window else { return }
                self.ambientAppearance.configure(configuration, in: window)
            }
        }

        func windowDidUpdate(_ notification: Notification) {
            if let window {
                ambientAppearance.updateLayout(in: window)
            }
            forwardee?.windowDidUpdate?(notification)
        }

        // Hide instead of close; keep the scene alive.
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.orderOut(nil)
            return false
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

struct SearchFieldView: View {
    let onSubmit: (String) -> Void

    @State private var text = ""
    @State private var placeholder = "搜索音乐、歌手、专辑"
    @FocusState private var focused: Bool

    var body: some View {
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
        // Keep the capsule off the window's rounded top-right corner (#88).
        .padding(.trailing, 8)
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
