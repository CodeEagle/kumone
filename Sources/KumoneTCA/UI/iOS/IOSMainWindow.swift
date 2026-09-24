import ComposableArchitecture
import KumoneCore
import SwiftUI

#if os(iOS)
public struct IOSMainWindow: View {
    @SwiftUI.Bindable private var store = IOSAppStore.store
    @StateObject private var updater = IOSUpdater.shared
    @StateObject private var artworkStore = NowPlayingArtworkStore()
    @Namespace private var nowPlayingTransition
    @Environment(\.colorScheme) private var systemColorScheme

    /// An inert, empty stack store: non-selected tabs render a rooted stack
    /// without driving the app's shared detail path.
    private static let emptyPathStore = Store(
        initialState: StackState<AppFeature.Path.State>()
    ) {
        EmptyReducer<StackState<AppFeature.Path.State>, StackAction<AppFeature.Path.State, AppFeature.Path.Action>>()
    }

    /// The app's intended scheme, read on this ancestor so the search-active
    /// tab environment can't invert it (#31).
    private var resolvedColorScheme: ColorScheme {
        store.settings.appearance.brightnessIntent.colorScheme ?? systemColorScheme
    }

    @State private var selectedTab: IOSTab = .home

    public init() {}

    private var nowPlayingPresented: Binding<Bool> {
        Binding(
            get: { store.isNowPlayingPresented },
            set: { store.send($0 ? .presentNowPlaying : .dismissNowPlaying) }
        )
    }

    private var loginPresented: Binding<Bool> {
        Binding(
            get: { store.isLoginPresented },
            set: { store.send($0 ? .presentLogin : .dismissLogin) }
        )
    }

    public var body: some View {
        presentationRoot
            .environment(\.appStore, store)
            .tint(Theme.accent)
            .preferredColorScheme(store.settings.appearance.brightnessIntent.colorScheme)
            .environment(\.openLogin, { store.send(.presentLogin) })
            .environment(\.openDestination, openDestination)
            .task {
                // The iPad branch embeds `MainWindow`, which sends `onAppear`
                // itself; sending it here too would bootstrap the account twice.
                guard UIDevice.current.userInterfaceIdiom != .pad else { return }
                store.send(.onAppear)
                if store.settings.autoCheckUpdates {
                    IOSUpdater.shared.check(interactive: false)
                }
            }
            .task(id: store.settings.showMainWindowAmbientBackground) {
                artworkStore.setArtworkNeeded(store.settings.showMainWindowAmbientBackground)
            }
            .sheet(isPresented: $updater.showSheet) {
                IOSUpdaterSheet()
            }
            .sheet(isPresented: loginPresented) {
                LoginSheet(store: store.scope(state: \.login, action: \.login), appStore: store)
            }
            .overlay(alignment: .top) {
                if let toast = store.toasts.current {
                    ToastView(toast: toast)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 8)
                }
            }
            .animation(.spring(duration: 0.3), value: store.toasts.current)
    }

    @ViewBuilder
    private var presentationRoot: some View {
        if UIDevice.current.userInterfaceIdiom == .phone {
            if #available(iOS 18.0, *) {
                zoomNowPlayingRoot
            } else {
                legacyPresentationRoot
            }
        } else {
            systemNowPlayingRoot
        }
    }

    private var systemNowPlayingRoot: some View {
        appContent
            .fullScreenCover(isPresented: nowPlayingPresented) {
                systemNowPlayingPresentation
                    .environment(\.appStore, store)
            }
    }

    @available(iOS 18.0, *)
    private var zoomNowPlayingRoot: some View {
        appContent
            .fullScreenCover(isPresented: nowPlayingPresented) {
                systemNowPlayingPresentation
                    .environment(\.appStore, store)
                    .navigationTransition(
                        .zoom(
                            sourceID: NowPlayingTransitionID.surface,
                            in: nowPlayingTransition
                        )
                    )
            }
    }

    @ViewBuilder
    private var systemNowPlayingPresentation: some View {
        if #available(iOS 16.4, *) {
            nowPlayingPresentation(
                usesSystemInteractiveDismissal: true,
                dismissAnimation: nil
            )
            .presentationBackground(.clear)
        } else {
            nowPlayingPresentation(
                usesSystemInteractiveDismissal: true,
                dismissAnimation: nil
            )
        }
    }

    private var legacyPresentationRoot: some View {
        ZStack {
            appContent

            if store.isNowPlayingPresented {
                // Present full-screen with a bottom slide-up. A previous version
                // used `matchedGeometryEffect(.frame, isSource: false)` here to
                // zoom out of the mini player, but that copies the *source*
                // (mini-bar) frame onto this view — shrinking the whole
                // now-playing page to bar size, so on iOS 16/17 nothing
                // full-screen appeared (#28). The slide-up matches the
                // pull-down-to-dismiss gesture; iOS 18+ still gets the zoom.
                nowPlayingPresentation(
                    usesSystemInteractiveDismissal: false,
                    dismissAnimation: NowPlayingPresentationMetrics.presentationAnimation
                )
                .transition(.move(edge: .bottom))
                .zIndex(1)
            }
        }
        .animation(NowPlayingPresentationMetrics.presentationAnimation, value: store.isNowPlayingPresented)
    }

    @ViewBuilder
    private var appContent: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            MainWindow(store: store)
        } else {
            tabInterface
                .overlay {
                    if store.settings.showMainWindowAmbientBackground {
                        MainWindowAmbientBackground(
                            colors: artworkStore.colors,
                            intensity: store.settings.mainWindowAmbientBackgroundIntensity
                        )
                        .ignoresSafeArea()
                    }
                }
        }
    }

    private func nowPlayingPresentation(
        usesSystemInteractiveDismissal: Bool,
        dismissAnimation: Animation?
    ) -> some View {
        IOSNowPlayingPresentation(
            isPresented: nowPlayingPresented,
            mode: store.settings.nowPlayingMode,
            usesSystemInteractiveDismissal: usesSystemInteractiveDismissal,
            dismissAnimation: dismissAnimation
        ) {
            NowPlayingView(onOpenDestination: openDestination)
        }
    }

    @ViewBuilder
    private var tabInterface: some View {
        if #available(iOS 26.0, *) {
            iOS26TabInterface
        } else {
            customTabInterface
        }
    }

    /// Attach the bottom mini-player accessory only when something is playing.
    /// Leaving the modifier on with empty content still renders an empty,
    /// translucent accessory platter above the tab bar when idle (#35), so we
    /// apply it conditionally.
    @available(iOS 26.0, *)
    private var iOS26TabInterface: some View {
        iOS26TabView
            .tabBarMinimizeBehavior(.onScrollDown)
            // Apply the accessory through a ViewModifier so the TabView keeps a
            // single identity across the hasCurrentTrack toggle. An if/else here
            // churns the TabView identity, which detaches the accessory's
            // matchedTransitionSource and makes the now-playing zoom anchor at
            // the screen centre (#57); not applying it when idle keeps the empty
            // accessory platter gone (#35).
            .modifier(MiniPlayerAccessoryModifier(
                isActive: store.player.hasCurrentTrack,
                transitionNamespace: nowPlayingTransition,
                colorScheme: resolvedColorScheme
            ))
            .animation(AppAnimation.standard, value: store.player.hasCurrentTrack)
    }

    @available(iOS 26.0, *)
    private var iOS26TabView: some View {
        TabView(selection: $selectedTab) {
            Tab("推荐", systemImage: "house", value: .home) {
                tabStack(.home) {
                    HomeView(store: store.scope(state: \.home, action: \.home), appStore: store)
                }
            }

            Tab("精选", systemImage: "square.grid.2x2", value: .explore) {
                tabStack(.explore) {
                    ExploreView(store: store.scope(state: \.explore, action: \.explore), appStore: store)
                }
            }

            Tab("漫游", systemImage: "wave.3.right.circle", value: .fm) {
                tabStack(.fm) { FMView(appStore: store) }
            }

            Tab("我的", systemImage: "person.crop.circle", value: .library) {
                tabStack(.library) { IOSLibraryView(appStore: store) }
            }

            Tab(value: .search, role: .search) {
                tabStack(.search) {
                    SearchView(store: store.scope(state: \.search, action: \.search), appStore: store)
                }
            } label: {
                Label("搜索", systemImage: "magnifyingglass")
            }
        }
    }

    private var customTabInterface: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                page(.home) {
                    tabStack(.home) {
                        HomeView(store: store.scope(state: \.home, action: \.home), appStore: store)
                    }
                }
                page(.explore) {
                    tabStack(.explore) {
                        ExploreView(store: store.scope(state: \.explore, action: \.explore), appStore: store)
                    }
                }
                page(.fm) { tabStack(.fm) { FMView(appStore: store) } }
                page(.search) {
                    tabStack(.search) {
                        SearchView(store: store.scope(state: \.search, action: \.search), appStore: store)
                    }
                }
                page(.library) { tabStack(.library) { IOSLibraryView(appStore: store) } }
            }

            VStack(spacing: 8) {
                if store.player.hasCurrentTrack {
                    IOSMiniPlayerBar(presentation: .legacyOverlay)
                        .nowPlayingTransitionSource(in: nowPlayingTransition)
                        .padding(.horizontal, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                GlassTabBar(items: Self.tabItems, selection: $selectedTab) { tab in
                    popToRoot(tab)
                }
            }
            .padding(.bottom, 6)
        }
        .animation(AppAnimation.standard, value: store.player.hasCurrentTrack)
    }

    private func popToRoot(_ tab: IOSTab) {
        store.send(.clearPath)
    }

    private func openDestination(_ destination: Destination) {
        store.send(.dismissNowPlaying)
        store.send(.openDestination(destination))
    }

    @ViewBuilder
    private func tabStack<Content: View>(
        _ tab: IOSTab,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        // The five tab stacks all share the app's single detail path; only the
        // selected tab may drive it, so sibling tabs stay rooted.
        let path: Binding<Store<
            StackState<AppFeature.Path.State>, StackAction<AppFeature.Path.State, AppFeature.Path.Action>
        >> = selectedTab == tab
            ? $store.scope(\.path, action: \.path)
            : .constant(Self.emptyPathStore)
        NavigationStack(path: path) {
            content()
        } destination: { pathStore in
            MainWindow.destinationView(pathStore, appStore: store)
        }
    }

    @ViewBuilder
    private func page<Content: View>(
        _ tab: IOSTab,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .opacity(selectedTab == tab ? 1 : 0)
            .allowsHitTesting(selectedTab == tab)
            .zIndex(selectedTab == tab ? 1 : 0)
    }
}

enum IOSTab: Hashable {
    case home, explore, fm, search, library
}

extension IOSMainWindow {
    static let tabItems: [GlassTabBar.Item] = [
        .init(tab: .home, title: "推荐", icon: "house"),
        .init(tab: .explore, title: "精选", icon: "square.grid.2x2"),
        .init(tab: .fm, title: "漫游", icon: "dot.radiowaves.left.and.right"),
        .init(tab: .search, title: "搜索", icon: "magnifyingglass"),
        .init(tab: .library, title: "我的", icon: "person.crop.circle"),
    ]
}

private enum NowPlayingTransitionID {
    static let surface = "now-playing-surface"
}

// MARK: - Mini player bar for iOS

@available(iOS 26.0, *)
private struct MiniPlayerAccessoryModifier: ViewModifier {
    let isActive: Bool
    let transitionNamespace: Namespace.ID
    let colorScheme: ColorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            content.tabViewBottomAccessory {
                IOSMiniPlayerAccessory(transitionNamespace: transitionNamespace)
                    // Pin the scheme so the search-active tab environment
                    // doesn't flip the bar's text to white (#31).
                    .environment(\.colorScheme, colorScheme)
            }
        } else {
            content
        }
    }
}

@available(iOS 26.0, *)
private struct IOSMiniPlayerAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let transitionNamespace: Namespace.ID

    var body: some View {
        IOSMiniPlayerBar(presentation: presentation)
            // Match the complete system accessory, never only its artwork.
            .nowPlayingTransitionSource(in: transitionNamespace)
    }

    private var presentation: IOSMiniPlayerBar.Presentation {
        let placementIsInline = placement.map { $0 == .inline }
        return NowPlayingPresentationMetrics.shouldUseInlineMiniPlayerLayout(
            placementIsInline: placementIsInline
        ) ? .inlineAccessory : .bottomAccessory
    }
}

private extension View {
    @ViewBuilder
    func nowPlayingTransitionSource(in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            matchedTransitionSource(
                id: NowPlayingTransitionID.surface,
                in: namespace
            )
        } else {
            // Pre-18 presents full-screen with a slide transition (see
            // legacyPresentationRoot); no matched-geometry pairing needed.
            self
        }
    }
}

/// Renders mini-player content inside either a system-owned tab accessory or
/// the material-backed compatibility overlay used before iOS 26.
///
/// Do not add a background for `bottomAccessory` or `inlineAccessory`: the
/// tab view owns their Liquid Glass surface and adding another material creates
/// a visibly nested card.
struct IOSMiniPlayerBar: View {
    enum Presentation {
        case bottomAccessory
        case inlineAccessory
        case legacyOverlay

        var isInline: Bool { self == .inlineAccessory }
        var drawsBackground: Bool { self == .legacyOverlay }
    }

    @Environment(\.appStore) private var appStore: StoreOf<AppFeature>?
    let presentation: Presentation

    private var player: PlayerFeature.State { appStore?.player ?? .init() }

    var body: some View {
        playerBarSurface
            .simultaneousGesture(expandGesture)
    }

    @ViewBuilder
    private var playerBarSurface: some View {
        if presentation.drawsBackground {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 4) {
            Button(action: { appStore?.send(.presentNowPlaying) }) {
                trackSummary
            }
            .buttonStyle(.plain)
            .accessibilityLabel(nowPlayingAccessibilityLabel)
            .accessibilityHint("打开正在播放")

            if !presentation.isInline {
                Button(action: { appStore?.send(.player(.previous)) }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .disabled(player.isFMMode)
                .opacity(player.isFMMode ? 0.35 : 1)
                .accessibilityLabel("上一首")
            }

            Button(action: { appStore?.send(.player(.togglePlayPause)) }) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

            if !presentation.isInline {
                Button(action: { appStore?.send(.player(.next)) }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("下一首")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
    }

    private var trackSummary: some View {
        HStack(alignment: .top, spacing: 8) {
            CachedAsyncImage(url: player.currentTrack?.album.picUrl?.resizedImageURL(128))
                .frame(
                    width: artworkSize,
                    height: artworkSize
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 1)

            VStack(alignment: .leading, spacing: metadataSpacing) {
                Text(player.currentTrack?.name ?? "")
                    .font(titleFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(player.currentTrack?.artistNames ?? "")
                    .font(artistFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var artworkSize: CGFloat {
        presentation.isInline ? 28 : 32
    }

    private var titleFont: Font {
        .system(size: presentation.isInline ? 10 : 13, weight: .semibold)
    }

    private var artistFont: Font {
        .system(size: presentation.isInline ? 8 : 10)
    }

    private var metadataSpacing: CGFloat {
        presentation.isInline ? 2 : 3
    }

    private var nowPlayingAccessibilityLabel: String {
        let title = player.currentTrack?.name ?? String(localized: "正在播放")
        guard let artist = player.currentTrack?.artistNames, !artist.isEmpty else {
            return title
        }
        return "\(title)，\(artist)"
    }

    private var expandGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onEnded { value in
                guard NowPlayingPresentationMetrics.shouldExpandFromMiniPlayer(
                    translation: value.translation.height,
                    predictedTranslation: value.predictedEndTranslation.height
                ) else { return }
                appStore?.send(.presentNowPlaying)
            }
    }
}

// MARK: - iOS Library View

struct IOSLibraryView: View {
    let appStore: StoreOf<AppFeature>

    @Environment(\.openDestination) private var openDestination
    @State private var showSettings = false
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""

    private var account: AccountFeature.State { appStore.account }

    var body: some View {
        List {
            // Profile / Login header
            Section {
                if let profile = account.profile {
                    HStack(spacing: 14) {
                        CachedAsyncImage(url: profile.avatarUrl?.resizedImageURL(128))
                            .frame(width: 52, height: 52)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(profile.nickname)
                                    .font(.headline)
                                if profile.vipType > 0 {
                                    VIPBadge()
                                }
                            }
                            if let sig = profile.signature, !sig.isEmpty {
                                Text(sig)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Button {
                        appStore.send(.presentLogin)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(.system(size: 32))
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("登录网易云音乐")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("同步我喜欢的音乐、歌单与每日推荐")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }

            if account.hasAuthCookie {
                Section("我的音乐") {
                    if let liked = account.likedSongsPlaylist {
                        Button {
                            openDestination(.playlist(liked.id))
                        } label: {
                            Label("我喜欢的音乐", systemImage: "heart.fill")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Button {
                        openDestination(.daily)
                    } label: {
                        Label("每日推荐", systemImage: "calendar")
                    }
                    Button {
                        openDestination(.recents)
                    } label: {
                        Label("最近播放", systemImage: "clock.fill")
                    }
                    Button {
                        openDestination(.collections)
                    } label: {
                        Label("我的收藏", systemImage: "star.fill")
                    }
                    Button {
                        openDestination(.cloud)
                    } label: {
                        Label("音乐云盘", systemImage: "icloud.fill")
                    }
                }

                if !account.createdPlaylists.isEmpty {
                    Section {
                        ForEach(account.createdPlaylists) { playlist in
                            Button {
                                openDestination(.playlist(playlist.id))
                            } label: {
                                HStack(spacing: 10) {
                                    CachedAsyncImage(url: playlist.coverURL?.resizedImageURL(80), animated: false)
                                        .frame(width: 32, height: 32)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(playlist.name)
                                            .font(.system(size: 14))
                                            .lineLimit(1)
                                        Text("\(playlist.trackCount) 首")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("创建的歌单")
                            Spacer()
                            Button {
                                showNewPlaylist = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                        }
                    }
                }

                if !account.subscribedPlaylists.isEmpty {
                    Section("收藏的歌单") {
                        ForEach(account.subscribedPlaylists) { playlist in
                            Button {
                                openDestination(.playlist(playlist.id))
                            } label: {
                                HStack(spacing: 10) {
                                    CachedAsyncImage(url: playlist.coverURL?.resizedImageURL(80), animated: false)
                                        .frame(width: 32, height: 32)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(playlist.name)
                                            .font(.system(size: 14))
                                            .lineLimit(1)
                                        Text("\(playlist.trackCount) 首")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Section {
                PlayerClearanceSpacer()
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("我的")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(
                    store: appStore.scope(state: \.settings, action: \.settings),
                    appStore: appStore
                )
                    .navigationTitle("设置")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") {
                                showSettings = false
                            }
                        }
                    }
            }
        }
        .alert("新建歌单", isPresented: $showNewPlaylist) {
            TextField("歌单名称", text: $newPlaylistName)
            Button("创建") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                newPlaylistName = ""
                guard !name.isEmpty else { return }
                Task {
                    do {
                        try await NeteaseAPI.createPlaylist(name: name, isPrivate: false)
                        appStore.send(.account(.refreshLibrary))
                        appStore.send(.toasts(.presented(String(localized: "歌单已创建"))))
                    } catch {
                        appStore.send(.toasts(.presented(error.localizedDescription)))
                    }
                }
            }
            Button("取消", role: .cancel) { newPlaylistName = "" }
        }
    }
}
#endif
