import KumoneCore
import SwiftUI
import ComposableArchitecture

/// Vertical position of the sharp lyric focus inside the lyrics viewport,
/// as a fraction of the viewport height. Slightly above center so the
/// currently-sung line sits in the upper-middle of the detail page.
private let lyricFocusY: CGFloat = 0.44

/// Immersive full-window now-playing page: artwork-tinted gradient backdrop,
/// large artwork on the left, big synced lyrics on the right.
struct NowPlayingView: View {
    let onOpenDestination: (Destination) -> Void

    @Environment(\.appStore) private var appStore: StoreOf<AppFeature>?

    private var player: PlayerFeature.State { appStore?.player ?? .init() }

    private var account: AccountFeature.State { appStore?.account ?? .init() }

    private var settings: SettingsFeature.State { appStore?.settings ?? .init() }
    #if os(macOS)
    @EnvironmentObject private var artworkStore: NowPlayingArtworkStore
    #endif
    #if os(iOS)
    @Environment(\.dismissNowPlayingAction) private var dismissNowPlayingAction
    @Environment(\.dismissNowPlayingDragAction) private var dismissNowPlayingDragAction
    #endif

    #if os(iOS)
    @State private var loadedArtworkImage: PlatformImage?
    @State private var loadedArtworkColors: ArtworkColors = .fallback
    #endif
    @State private var activeIndex: Int?
    @State private var isUserScrolling = false
    @State private var resumeTask: Task<Void, Never>?
    @State private var showLyricsOnMobile = false
    @State private var showQueueOnMobile = false
    @State private var lyricsColumnHold = false
    #if os(macOS)
    @State private var hasStartedPlayPauseFlight = false
    @State private var hasStartedPreviousFlight = false
    @State private var hasStartedNextFlight = false
    @State private var hasStartedLikeFlight = false
    @State private var hasStartedShuffleFlight = false
    @State private var hasStartedRepeatFlight = false
    @State private var hasStartedFMTrashFlight = false
    @State private var hasStartedVIPFlight = false
    @State private var hasStartedTitleFlight = false
    @State private var hasStartedArtistFlight = false
    @State private var hasStartedHeroFlight = false
    @ObservedObject private var heroFlight = HeroFlightDirector.shared
    @State private var isZenMode = false
    @State private var lyricsColumnWasVisible = false
    @State private var isWindowHovered = true
    @State private var isZenActive = false
    @State private var zenHoverTask: Task<Void, Never>?
    @State private var isShaderPickerOpen = false
    private static let zenAnimation: Animation = .spring(response: 0.45, dampingFraction: 0.85)
    #endif
    /// The shader list is observed rather than read off the singleton: the
    /// first `body` pass happens before `onAppear` runs the scan, so the
    /// backdrop would resolve `nil` and never be asked again.
    @StateObject private var shaderLibrary = ShaderLibrary.shared
    /// The shader list's PCM-sync switch governs this backdrop's renderer too.
    /// The picker's selection lives on `ShaderSettings` so the AppKit shell's
    /// window layer and this page read and write the same choice.
    @ObservedObject private var shaderSettings = ShaderSettings.shared
    /// Lyrics column viewport, in global coordinates: the positional blur
    /// needs a center line and a falloff span.
    @State private var viewportFrame: CGRect = .zero

    /// Runs the current shader behind the now-playing content instead of the
    /// flat gradient. Off by default: a backdrop should not move until the user
    /// asks it to.
    #if os(iOS)
    @AppStorage("visualizer.backdropEnabled") private var shaderBackdropEnabled = true
    #endif

    /// The shader this page renders and the picker highlights.
    ///
    /// On macOS the window-level layer is the authority — the app delegate
    /// drives it from `AppFeature.shaderID` — so the selection follows the
    /// store and stays in step with what is actually behind the window. iOS
    /// has no such layer and resolves from the persisted name instead.
    private var visualizerShader: ShaderDescriptor? {
        if shaderSettings.shaderPickingDisabled { return nil }
        if let id = appStore?.shaderID,
           let match = shaderLibrary.available.first(where: { $0.id == id }) {
            return match
        }
        if shaderSettings.pickedShaderName.isEmpty {
            return shaderLibrary.available.first
        }
        return shaderLibrary.available.first { $0.name == shaderSettings.pickedShaderName }
    }

    var body: some View {
        GeometryReader { geo in
            let isCompact = geo.size.width < 720
            ZStack {
                backdrop

                if isCompact {
                    compactLayout(size: geo.size)
                } else {
                    regularLayout(size: geo.size)
                }
            }
            // Pin to the screen width so an intrinsically-wide child can never
            // stretch the ZStack and push the corner overlays off-screen.
            .frame(width: geo.size.width)
            #if os(iOS)
            // iOS keeps the dismiss chevron top-leading (no traffic lights);
            // macOS moves it to the trailing overlay below.
            .overlay(alignment: .topLeading) {
                if showsClassicChrome(isCompact: isCompact) {
                    closeButton
                        .padding(.top, 20)
                        .padding(.leading, 20)
                }
            }
            #endif
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 10) {
                    #if os(macOS)
                    if showsClassicChrome(isCompact: isCompact) {
                        closeButton
                    }
                    #endif
                    if isCompact, showsClassicChrome(isCompact: isCompact) {
                        PlayerIconButton(
                            icon: "quote.bubble",
                            size: 13,
                            isActive: player.activePanel == .lyrics
                        ) {
                            appStore?.send(.player(.togglePanel(.lyrics)))
                        }
                        .help("歌词")
                    }
                }
                .padding(.top, 20)
                .padding(.trailing, 20)
            }
            #if os(iOS)
            .overlay {
                if settings.nowPlayingMode == .minimal && showQueueOnMobile {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showQueueOnMobile = false }
                        .accessibilityLabel("关闭播放列表")
                        .accessibilityAddTraits(.isButton)
                }
            }
            #endif
        }
        #if os(macOS)
        // The window toolbar is hidden while this page is up, but SwiftUI keeps
        // reserving its safe area, which pushed the whole immersive layout —
        // close button included — a toolbar's height down from the window top.
        // iOS keeps its safe area: there the inset is the status bar / notch.
        .ignoresSafeArea()
        // Keep the hover region independent of the chrome and lyric layout.
        .contentShape(Rectangle())
        .onHover { hovering in
            guard isWindowHovered != hovering else { return }
            isWindowHovered = hovering
            if isZenMode {
                scheduleZenHoverChange()
            } else if !hovering, lyricsColumnHold {
                withAnimation(.easeInOut(duration: 0.4)) {
                    lyricsColumnHold = false
                }
            }
        }
        .onChange(of: isShaderPickerOpen) {
            scheduleZenHoverChange()
        }
        .onDisappear {
            hasStartedHeroFlight = false
            hasStartedPlayPauseFlight = false
            hasStartedPreviousFlight = false
            hasStartedNextFlight = false
            hasStartedLikeFlight = false
            hasStartedShuffleFlight = false
            hasStartedRepeatFlight = false
            hasStartedFMTrashFlight = false
            hasStartedVIPFlight = false
            hasStartedTitleFlight = false
            hasStartedArtistFlight = false
            zenHoverTask?.cancel()
            zenHoverTask = nil
            lyricsColumnHold = false
            lyricsColumnWasVisible = false
        }
        #endif
        .preferredColorScheme(.dark)
        #if os(iOS)
        .task(id: player.currentTrack?.id) {
            await loadArtwork()
        }
        #endif
        #if os(iOS)
        .onAppear {
            showLyricsOnMobile = settings.nowPlayingMode == .immersive
            showQueueOnMobile = false
        }
        .onChange(of: settings.nowPlayingMode) {
            showLyricsOnMobile = settings.nowPlayingMode == .immersive
            showQueueOnMobile = false
        }
        .onChange(of: player.currentTrack?.id) {
            if settings.nowPlayingMode == .minimal || settings.nowPlayingMode == .vinyl {
                showLyricsOnMobile = false
            }
        }
        #endif
        #if os(macOS)
        .onChange(of: hasLyricsColumn) { _, hasColumn in
            if lyricsColumnWasVisible && !hasColumn
                && player.activePanel == .lyrics && isWindowHovered {
                lyricsColumnHold = true
            }
            if hasColumn { lyricsColumnHold = false }
            lyricsColumnWasVisible = hasColumn
        }
        .onExitCommand { close() }
        .onChange(of: appStore?.isNowPlayingPresented) { _, isPresented in
            if isPresented != true {
                hasStartedHeroFlight = false
                hasStartedPlayPauseFlight = false
                hasStartedPreviousFlight = false
                hasStartedNextFlight = false
                hasStartedLikeFlight = false
                hasStartedShuffleFlight = false
                hasStartedRepeatFlight = false
                hasStartedFMTrashFlight = false
                hasStartedVIPFlight = false
                hasStartedTitleFlight = false
                hasStartedArtistFlight = false
            }
        }
        #endif
        .onAppear {
            ShaderDirectory.ensureExists()
            shaderLibrary.reload()
        }
    }

    private var hasLyricsColumn: Bool {
        if let lyrics = player.lyrics, !lyrics.isEmpty { return true }
        return player.lyrics == nil // still loading — keep layout stable
    }

    /// The chevron-down button that dismisses the immersive page. On macOS it
    /// rides the top-trailing corner: the window traffic lights sit top-leading
    /// and the two overlapped while the window toolbar is hidden for this page.
    private var closeButton: some View {
        Button {
            close()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.pressable)
        #if os(macOS)
        .opacity(isZenActive ? 0 : 1)
        .allowsHitTesting(!isZenActive)
        #endif
    }

    private func close() {
        #if os(iOS)
        if let dismissNowPlayingAction {
            dismissNowPlayingAction()
        } else {
            withAnimation(NowPlayingPresentationMetrics.presentationAnimation) {
                appStore?.send(.dismissNowPlaying)
            }
        }
        #else
        appStore?.send(.dismissNowPlaying)
        #endif
    }

    private func showsClassicChrome(isCompact: Bool) -> Bool {
        #if os(iOS)
        return !isCompact || settings.nowPlayingMode == .classic
        #else
        return true
        #endif
    }


    /// Jump straight to the line the song is on. Used when the view appears,
    /// where waiting for the next line change would leave the lyrics parked at
    /// the top. Scrolling is deferred a turn: the list has not laid out yet
    /// while `onAppear` runs, and `scrollTo` on an unlaid list does nothing.
    private func adoptCursor(proxy: ScrollViewProxy) {
        let index = player.lyricsCursorIndex
        activeIndex = index
        resumeTask?.cancel()
        isUserScrolling = false
        // Before the first timestamp there is no active line, but the new
        // song must still display its first lyric at the focus position.
        guard let index = index ?? player.lyrics?.lines.first?.id else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: lyricFocusY))
        }
    }

    // MARK: - Backdrop

    private var artworkImage: PlatformImage? {
        #if os(macOS)
        artworkStore.artwork
        #else
        loadedArtworkImage
        #endif
    }

    private var colors: ArtworkColors {
        #if os(macOS)
        artworkStore.colors
        #else
        loadedArtworkColors
        #endif
    }

    private var backdrop: some View {
        ZStack {
            #if os(macOS)
            // The window-level shader is this page's background now, so the
            // backdrop keeps only the bottom scrim the controls need to stay
            // readable. The flat album-color gradient and the page's own
            // shader container are iOS-only from here on.
            LinearGradient(
                colors: [.clear, .black.opacity(0.28)],
                startPoint: .top, endPoint: .bottom
            )
            #else
            if shaderBackdropEnabled {
                // The shader is the backdrop: it draws opaque, so it goes on
                // top of the flat gradient and replaces it. The old order put
                // the gradient *above* a 0.55-opacity shader, which buried the
                // visuals under a solid album-color wash ("the yellow blur").
                LinearGradient(
                    colors: [colors.primary.color, colors.secondary.color],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                ShaderContainerView(
                    shader: visualizerShader,
                    isPlaying: player.isPlaying,
                    palette: ShaderPaletteBuilder.make(from: colors),
                    pcmSync: shaderSettings.pcmSyncEnabled
                )
                // Just enough bottom shading to keep the controls readable.
                LinearGradient(
                    colors: [.clear, .black.opacity(0.28)],
                    startPoint: .top, endPoint: .bottom
                )
            } else {
                LinearGradient(
                    colors: [colors.primary.color, colors.secondary.color],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [.white.opacity(0.12), .clear],
                    center: .topLeading, startRadius: 0, endRadius: 700
                )
                LinearGradient(
                    colors: [.clear, .black.opacity(0.35)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            #endif
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: colors)
    }

    #if os(iOS)
    private func loadArtwork() async {
        guard let urlString = player.currentTrack?.album.picUrl,
              let url = urlString.resizedImageURL(768) else {
            loadedArtworkImage = nil
            loadedArtworkColors = .fallback
            return
        }
        if let image = await ImageCache.shared.image(for: url) {
            loadedArtworkImage = image
            loadedArtworkColors = ArtworkPalette.extract(from: image, cacheKey: urlString)
        }
    }
    #endif

    // MARK: - Layouts

    private var isLyricsColumnVisible: Bool {
        #if os(macOS)
        hasLyricsColumn && (player.activePanel == .lyrics) || lyricsColumnHold
        #else
        hasLyricsColumn
        #endif
    }

    private func regularLayout(size: CGSize) -> some View {
        // Everything below the artwork needs ~300pt; shrink the artwork on
        // short displays (iPhone landscape) instead of clipping it.
        let artworkSize = max(120, min(340, size.width * 0.32, size.height - 300))
        // Cap the two-column band and centre it. Spreading each column to
        // `.infinity` across an ultra-wide display (iPad landscape, ~1368pt)
        // left the left column's content floating in an oversized half and a
        // wide blank gutter on the right (#62).
        let maxBandWidth: CGFloat = isLyricsColumnVisible ? 1040 : 560
        return HStack(spacing: 0) {
            leftColumn(artworkSize: artworkSize)
                .frame(maxWidth: .infinity)
            if isLyricsColumnVisible {
                lyricsColumn
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: maxBandWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 48)
        .padding(.vertical, size.height < 500 ? 24 : 40)
        .animation(AppAnimation.smooth, value: isLyricsColumnVisible)
    }

    @ViewBuilder
    private func compactLayout(size: CGSize) -> some View {
        #if os(iOS)
        switch settings.nowPlayingMode {
        case .vinyl:
            vinylCompactLayout(size: size)
        case .classic:
            classicCompactLayout(size: size)
        case .immersive:
            immersiveCompactLayout(size: size)
        case .minimal:
            minimalCompactLayout(size: size)
        }
        #else
        switch settings.nowPlayingMode {
        case .vinyl:
            vinylCompactLayout(size: size)
        default:
            classicCompactLayout(size: size)
        }
        #endif
    }

    private func vinylCompactLayout(size: CGSize) -> some View {
        let discDimension = min(size.width - 64, size.height * 0.42, 320)
        let showsVinyl = !showLyricsOnMobile && !showQueueOnMobile

        return VStack(spacing: 0) {
            #if os(iOS)
            Color.clear.frame(
                height: NowPlayingPresentationMetrics.immersiveHeaderTopInset
            )

            CompactTrackHeader(
                showsExpandedArtwork: showsVinyl,
                onOpenDestination: onOpenDestination
            )
                .padding(.bottom, 10)
            #else
            Spacer().frame(height: 30)
            trackMetaView
                .padding(.bottom, 10)
            #endif

            ZStack {
                if showsVinyl {
                    VStack(spacing: 12) {
                        Spacer(minLength: 4)

                        VinylTurntableView(
                            artworkImage: artworkImage,
                            isPlaying: player.isPlaying,
                            trackId: player.currentTrack?.id,
                            size: discDimension,
                            onTap: {
                                withAnimation(AppAnimation.standard) {
                                    showLyricsOnMobile = true
                                }
                            },
                            onNextTrack: {
                                appStore?.send(.player(.next))
                            },
                            onPreviousTrack: {
                                appStore?.send(.player(.previous))
                            }
                        )
                        .accessibilityIdentifier("vinylTurntable")

                        MiniLyricsView(onOpen: {
                            withAnimation(AppAnimation.standard) {
                                showLyricsOnMobile = true
                            }
                        })
                        .frame(maxWidth: .infinity, maxHeight: 70)

                        Spacer(minLength: 0)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else if showQueueOnMobile {
                    #if os(iOS)
                    CompactQueueContent()
                        .transition(.opacity)
                    #else
                    lyricsColumn
                        .transition(.opacity)
                    #endif
                } else {
                    #if os(iOS)
                    IOSImmersiveLyricsColumn()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(AppAnimation.standard) {
                                showLyricsOnMobile = false
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 1.05)))
                    #else
                    lyricsColumn
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(AppAnimation.standard) {
                                showLyricsOnMobile = false
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 1.05)))
                    #endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            #if os(iOS)
            immersiveControls
            #else
            VStack(spacing: 12) {
                NowPlayingScrubber()
                    .padding(.horizontal, 24)
                controls()
            }
            .padding(.bottom, 24)
            #endif
        }
        .frame(width: max(size.width - 64, 0))
        .padding(.horizontal, 32)
    }

    private func classicCompactLayout(size: CGSize) -> some View {
        let artworkDim = min(size.width - 64, size.height * 0.38, 300)
        return VStack(spacing: 20) {
            Spacer().frame(height: 44)
            if showLyricsOnMobile {
                lyricsColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            } else {
                VStack(spacing: 20) {
                    artworkView(size: artworkDim)
                    trackMetaView
                    MiniLyricsView {
                        withAnimation(AppAnimation.standard) {
                            showLyricsOnMobile = true
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transition(.opacity)
            }
            VStack(spacing: 12) {
                NowPlayingScrubber()
                    .padding(.horizontal, 24)
                controls()
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 16)
    }

    #if os(iOS)
    private func immersiveCompactLayout(size: CGSize) -> some View {
        let artworkDimension = min(size.width - 112, size.height * 0.3, 250)
        let showsExpandedArtwork = !showLyricsOnMobile && !showQueueOnMobile

        return VStack(spacing: 0) {
            Color.clear.frame(
                height: NowPlayingPresentationMetrics.immersiveHeaderTopInset
            )

            CompactTrackHeader(
                showsExpandedArtwork: showsExpandedArtwork,
                onOpenDestination: onOpenDestination,
                onTapArtwork: collapseImmersiveArtwork
            )
            .padding(.bottom, 14)

            ZStack {
                immersiveArtworkContent(artworkDimension: artworkDimension)
                    .opacity(showsExpandedArtwork ? 1 : 0)
                    .allowsHitTesting(showsExpandedArtwork)
                    .accessibilityHidden(!showsExpandedArtwork)

                if showQueueOnMobile {
                    CompactQueueContent()
                        .transition(.opacity)
                } else {
                    IOSImmersiveLyricsColumn()
                        .opacity(showLyricsOnMobile ? 1 : 0)
                        .allowsHitTesting(showLyricsOnMobile)
                        .accessibilityHidden(!showLyricsOnMobile)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            immersiveControls
        }
        .frame(width: max(size.width - 64, 0))
        .padding(.horizontal, 32)
        .overlayPreferenceValue(ImmersiveArtworkFramePreferenceKey.self) { frames in
            GeometryReader { proxy in
                if let compactAnchor = frames[.compact],
                   let expandedAnchor = frames[.expanded] {
                    let compactFrame = proxy[compactAnchor]
                    let expandedFrame = proxy[expandedAnchor]
                    let targetFrame = showsExpandedArtwork ? expandedFrame : compactFrame
                    let targetCenterX = showsExpandedArtwork
                        ? size.width / 2
                        : compactFrame.midX

                    immersiveArtworkSurface(isExpanded: showsExpandedArtwork)
                        .frame(width: targetFrame.width, height: targetFrame.height)
                        .position(x: targetCenterX, y: targetFrame.midY)
                        .accessibilityIdentifier("immersiveArtwork")
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var immersiveControls: some View {
        VStack(spacing: 17) {
            NowPlayingScrubber()
            CompactTransportControls()
            CompactVolumeControl()
            CompactSecondaryControls(
                showsLyrics: showLyricsOnMobile,
                showsQueue: showQueueOnMobile,
                onToggleLyrics: toggleImmersiveLyrics,
                onToggleQueue: toggleImmersiveQueue
            )
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
        .accessibilityIdentifier("immersiveControls")
    }

    private func immersiveArtworkContent(artworkDimension: CGFloat) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)
            Color.clear
                .frame(width: artworkDimension, height: artworkDimension)
                .anchorPreference(
                    key: ImmersiveArtworkFramePreferenceKey.self,
                    value: .bounds
                ) { [.expanded: $0] }
            MiniLyricsView(onOpen: showImmersiveLyrics)
                .frame(maxWidth: .infinity, maxHeight: 96)
            Spacer(minLength: 0)
        }
    }

    private func immersiveArtworkSurface(isExpanded: Bool) -> some View {
        Group {
            if let artworkImage {
                Image(platformImage: artworkImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.white.opacity(isExpanded ? 0.06 : 0.1))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: isExpanded ? 48 : 18, weight: .light))
                            .foregroundStyle(.white.opacity(isExpanded ? 0.3 : 0.45))
                    }
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: isExpanded ? 18 : 12,
                style: .continuous
            )
        )
        .shadow(
            color: .black.opacity(isExpanded ? 0.45 : 0.22),
            radius: isExpanded ? 36 : 10,
            y: isExpanded ? 18 : 4
        )
    }

    private func toggleImmersiveLyrics() {
        withAnimation(ImmersiveArtworkTransition.animation) {
            if showQueueOnMobile {
                showQueueOnMobile = false
                showLyricsOnMobile = true
            } else {
                showLyricsOnMobile.toggle()
            }
        }
    }

    private func showImmersiveLyrics() {
        withAnimation(ImmersiveArtworkTransition.animation) {
            showQueueOnMobile = false
            showLyricsOnMobile = true
        }
    }

    /// Tapping the top-left cover while lyrics/queue are up returns to the
    /// expanded artwork — the Apple Music gesture requested in #50. Idempotent,
    /// so a tap while already expanded is a harmless no-op.
    private func collapseImmersiveArtwork() {
        guard showLyricsOnMobile || showQueueOnMobile else { return }
        withAnimation(ImmersiveArtworkTransition.animation) {
            showLyricsOnMobile = false
            showQueueOnMobile = false
        }
    }

    private func toggleImmersiveQueue() {
        withAnimation(ImmersiveArtworkTransition.animation) {
            showQueueOnMobile.toggle()
        }
    }

    private func minimalCompactLayout(size: CGSize) -> some View {
        let contentWidth = max(size.width - 64, 0)
        let artworkDimension = min(contentWidth, size.height * 0.52, 378)

        return VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Color.clear
                MinimalTrackInfoRow(
                    onOpenDestination: onOpenDestination,
                    metadataOnly: true
                )
                    .padding(.top, NowPlayingPresentationMetrics.immersiveHeaderTopInset)
                    .opacity(showLyricsOnMobile ? 1 : 0)
                    .accessibilityHidden(!showLyricsOnMobile)
            }
            .frame(height: 90)

            ZStack(alignment: .top) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggleMinimalLyrics)

                artworkView(size: artworkDimension)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggleMinimalLyrics)
                    .accessibilityIdentifier("immersiveArtwork")
                    .accessibilityLabel("显示歌词")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { toggleMinimalLyrics() }
                    .opacity(showLyricsOnMobile ? 0 : 1)
                    .allowsHitTesting(!showLyricsOnMobile)

                IOSMinimalLyricsColumn {
                    showLyricsOnMobile = false
                }
                .opacity(showLyricsOnMobile ? 1 : 0)
                .allowsHitTesting(showLyricsOnMobile)
                .accessibilityHidden(!showLyricsOnMobile)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .simultaneousGesture(
                minimalDismissGesture,
                including: showLyricsOnMobile ? .none : .all
            )
            .padding(.bottom, 20)

            minimalControls
        }
        .frame(width: contentWidth)
        .padding(.horizontal, 32)
        .padding(.bottom, 32)
        .animation(.easeInOut(duration: 0.22), value: showLyricsOnMobile)
    }

    private var minimalControls: some View {
        VStack(spacing: 22) {
            ZStack {
                MinimalTrackInfoRow(onOpenDestination: onOpenDestination)
                    .opacity(showLyricsOnMobile ? 0 : 1)
                    .allowsHitTesting(!showLyricsOnMobile)
                    .accessibilityHidden(showLyricsOnMobile)
                MinimalTrackInfoRow(
                    onOpenDestination: onOpenDestination,
                    actionsOnly: true
                )
                    .opacity(showLyricsOnMobile ? 1 : 0)
                    .allowsHitTesting(showLyricsOnMobile)
                    .accessibilityHidden(!showLyricsOnMobile)
            }
            .frame(height: 44)
            NowPlayingScrubber()
                .padding(.horizontal, 2)
                .padding(.top, 16)
            MinimalTransportControls(
                backdrop: colors,
                showQueue: $showQueueOnMobile
            )
                .padding(.horizontal, 2)
        }
        .accessibilityIdentifier("immersiveControls")
    }

    private func toggleMinimalLyrics() {
        guard showLyricsOnMobile || player.lyrics?.isEmpty == false else { return }
        showLyricsOnMobile.toggle()
    }

    private var minimalDismissGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                guard let dismissNowPlayingDragAction else { return }
                let translation = value.translation
                let isDownward = translation.height > 0
                    && abs(translation.height) > abs(translation.width)
                dismissNowPlayingDragAction.onChanged(isDownward ? translation.height : 0)
            }
            .onEnded { value in
                guard let dismissNowPlayingDragAction else { return }
                let translation = value.translation
                let isDownward = translation.height > 0
                    && abs(translation.height) > abs(translation.width)
                dismissNowPlayingDragAction.onEnded(
                    isDownward ? translation.height : 0,
                    isDownward ? value.predictedEndTranslation.height : 0
                )
            }
    }
    #endif

    // MARK: - Views

    private func artworkView(size: CGFloat) -> some View {
        Group {
            if let album = player.currentTrack?.album, album.id > 0, !album.name.isEmpty {
                Button {
                    onOpenDestination(.album(album.id))
                } label: {
                    artworkSurface(size: size)
                }
                .buttonStyle(.plain)
                .noFocusRing()
                .accessibilityLabel("打开专辑：\(album.name)")
            } else {
                artworkSurface(size: size)
            }
        }
        #if os(macOS)
        .heroAnchor(HeroID.nowPlayingArtworkTarget, scale: player.isPlaying ? 1 : 0.95)
        .nowPlayingHeroTarget(
            id: HeroID.nowPlayingArtwork,
            content: .artwork(url: player.currentTrack?.album.picUrl?.resizedImageURL(768), cornerRadius: 18),
            scale: player.isPlaying ? 1 : 0.95,
            anchorID: HeroID.nowPlayingArtworkTarget,
            isPresented: appStore?.isNowPlayingPresented == true,
            hasStarted: $hasStartedHeroFlight
        )
        #endif
    }

    private func artworkSurface(size: CGFloat) -> some View {
        Group {
            if let artworkImage {
                Image(platformImage: artworkImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.white.opacity(0.06))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 48, weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        // The hero stand-in owns the artwork for the whole flight, in both
        // directions; the real one reappears the instant the stand-in lands.
        .shadow(color: .black.opacity(0.45), radius: 36, y: 18)
        .opacity(heroFlight.active[HeroID.nowPlayingArtwork] != nil ? 0 : 1)
        .animation(nil, value: heroFlight.active[HeroID.nowPlayingArtwork] != nil)
        .scaleEffect(player.isPlaying ? 1 : 0.95)
        .animation(AppAnimation.bouncy, value: player.isPlaying)
    }

    private var trackMetaView: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text(player.currentTrack?.name ?? "")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    #if os(macOS)
                    .heroAnchor(HeroID.nowPlayingTitleTarget)
                    .nowPlayingHeroTarget(
                        id: HeroID.nowPlayingTitle,
                        content: .playerTitle(player.currentTrack?.name ?? ""),
                        anchorID: HeroID.nowPlayingTitleTarget,
                        isPresented: appStore?.isNowPlayingPresented == true,
                        hasStarted: $hasStartedTitleFlight
                    )
                    .opacity(heroFlight.active[HeroID.nowPlayingTitle] != nil ? 0 : 1)
                    .animation(nil, value: heroFlight.active[HeroID.nowPlayingTitle] != nil)
                    #endif
                if player.currentTrack?.fee == 1 {
                    VIPBadge()
                        #if os(macOS)
                        .heroAnchor(HeroID.nowPlayingVIPTarget)
                        .nowPlayingHeroTarget(
                            id: HeroID.nowPlayingVIP, content: .vipBadge,
                            anchorID: HeroID.nowPlayingVIPTarget,
                            isPresented: appStore?.isNowPlayingPresented == true,
                            hasStarted: $hasStartedVIPFlight
                        )
                        .opacity(heroFlight.active[HeroID.nowPlayingVIP] != nil ? 0 : 1)
                        #endif
                }
            }
            if let track = player.currentTrack {
                NowPlayingTrackDestinationLinks(
                    track: track,
                    font: .system(size: 13.5),
                    color: .white.opacity(0.65),
                    onOpenDestination: onOpenDestination
                )
                #if os(macOS)
                .heroAnchor(HeroID.nowPlayingArtistTarget)
                .nowPlayingHeroTarget(
                    id: HeroID.nowPlayingArtist,
                    // The stand-in shows exactly what this row renders —
                    // filtered artists joined by " / ", then " — " and the
                    // album — so it lands as the row's perfect double.
                    content: .text(nowPlayingArtistLinkText(track),
                                   color: .white.opacity(0.65), fontSize: 13.5),
                    anchorID: HeroID.nowPlayingArtistTarget,
                    isPresented: appStore?.isNowPlayingPresented == true,
                    hasStarted: $hasStartedArtistFlight
                )
                .opacity(heroFlight.active[HeroID.nowPlayingArtist] != nil ? 0 : 1)
                #endif
            }
        }
        .frame(maxWidth: 400)
    }

    /// The string `NowPlayingTrackDestinationLinks` draws for a track, used by
    /// the title/artist hero flight so the stand-in's text matches the landing
    /// row character for character (separator " / " between artists, then
    /// " — " before the album).
    private func nowPlayingArtistLinkText(_ track: Track) -> String {
        let artists = track.artists.filter { $0.id > 0 && !$0.name.isEmpty }
        let artistPart = artists.isEmpty
            ? track.artistNames
            : artists.map(\.name).joined(separator: " / ")
        guard track.album.id > 0, !track.album.name.isEmpty else { return artistPart }
        guard !artistPart.isEmpty else { return track.album.name }
        return artistPart + " — " + track.album.name
    }

    private func leftColumn(artworkSize: CGFloat) -> some View {
        Group {
            #if os(macOS)
            // Zen mode slides the artwork and metadata to the viewport's
            // vertical centre. The offset is applied through `visualEffect`
            // and only while zen is active, so the resting layout — and the
            // hero anchors read off this column — is untouched otherwise.
            GeometryReader { viewport in
                VStack(spacing: 0) {
                    Spacer()
                    artworkAndMetadata(artworkSize: artworkSize)
                        // Keep the title and destination links at their natural
                        // height, even when the viewport proposes less space.
                        .fixedSize(horizontal: false, vertical: true)
                        .visualEffect { content, geometry in
                            content.offset(
                                y: isZenActive
                                    ? viewport.size.height / 2
                                        - geometry.frame(in: .named("nowPlayingColumn")).midY
                                    : 0
                            )
                        }
                        .animation(Self.zenAnimation, value: isZenActive)

                    // Keep identity and layout stable while hidden: rebuilding
                    // these subviews can restart transitions during hover and
                    // layout updates. Zen only fades them now — no offset — so
                    // the column above never reflows while they disappear.
                    VStack(spacing: 26) {
                        VStack(spacing: 14) {
                            NowPlayingScrubber()
                                .frame(maxWidth: 380)
                            controls(showsRoamingBadge: false, showsRoutePicker: false)
                        }
                        actionRow
                    }
                    .padding(.top, 26)
                    .opacity(isZenActive ? 0 : 1)
                    .allowsHitTesting(!isZenActive)
                    .accessibilityHidden(isZenActive)
                    // The lyrics toggle resizes this column; the buttons in the
                    // action row have to ride the same horizontal slide the rest
                    // of the page takes instead of jumping to their new spot.
                    .animation(AppAnimation.smooth, value: isLyricsColumnVisible)
                    Spacer()
                }
                .frame(width: viewport.size.width, height: viewport.size.height)
                .coordinateSpace(name: "nowPlayingColumn")
            }
            #else
            VStack(spacing: 26) {
                Spacer()
                artworkAndMetadata(artworkSize: artworkSize)
                VStack(spacing: 14) {
                    NowPlayingScrubber()
                        .frame(maxWidth: 380)
                    controls()
                }
                Spacer()
            }
            #endif
        }
        .padding(.trailing, isLyricsColumnVisible ? 30 : 0)
    }

    /// The artwork (or vinyl record) plus the title/artist row: the block that
    /// centres itself in zen mode and shares one identity between the macOS
    /// and iOS layouts of `leftColumn`.
    private func artworkAndMetadata(artworkSize: CGFloat) -> some View {
        VStack(spacing: 26) {
            if settings.nowPlayingMode == .vinyl {
                VinylTurntableView(
                    artworkImage: artworkImage,
                    isPlaying: player.isPlaying,
                    trackId: player.currentTrack?.id,
                    size: artworkSize,
                    onTap: {
                        appStore?.send(.player(.togglePlayPause))
                    },
                    onNextTrack: {
                        appStore?.send(.player(.next))
                    },
                    onPreviousTrack: {
                        appStore?.send(.player(.previous))
                    },
                    heroTarget: VinylHeroTarget(
                        id: HeroID.nowPlayingArtwork,
                        anchorID: HeroID.nowPlayingArtworkTarget,
                        artworkURL: player.currentTrack?.album.picUrl?.resizedImageURL(768),
                        // The landing shape is the record's circular label, so
                        // the stand-in must be a circle, not the square
                        // cover's rounded rectangle.
                        cornerRadius: artworkSize * 0.64 / 2,
                        isPresented: appStore?.isNowPlayingPresented == true,
                        hasStarted: $hasStartedHeroFlight
                    )
                )
            } else {
                artworkView(size: artworkSize)
            }
            trackMetaView
        }
    }

    #if os(macOS)
    private var actionRow: some View {
        HStack(spacing: 12) {
            lyricsToggleButton
            zenButton
            Spacer(minLength: 0)
            ShaderPickerButton(
                isPresented: $isShaderPickerOpen,
                selected: visualizerShader,
                library: shaderLibrary,
                palette: ShaderPaletteBuilder.make(from: colors)
            ) { shader in
                if let shader {
                    shaderSettings.pickedShaderName = shader.name
                    shaderSettings.shaderPickingDisabled = false
                    // The window-level layer observes the store; writing only
                    // storage left it on a different shader than the one the
                    // page picks.
                    appStore?.send(.setShader(shader.id))
                } else {
                    shaderSettings.shaderPickingDisabled = true
                    appStore?.send(.setShader(nil))
                }
            }
            Spacer(minLength: 0)
            if player.isFMMode {
                fmRoamingBadge
            }
            RoutePickerButton(diameter: 36, glyphSize: 14)
        }
        .frame(maxWidth: 380)
    }

    private var lyricsToggleButton: some View {
        PlayerIconButton(
            icon: "quote.bubble",
            size: 13,
            isActive: player.activePanel == .lyrics
        ) {
            appStore?.send(.player(.togglePanel(.lyrics)))
        }
        .help("歌词")
    }

    /// Every hover-driven chrome change uses the same cancellable delay,
    /// including enabling Zen and returning from the shader popover.
    private func scheduleZenHoverChange() {
        zenHoverTask?.cancel()
        zenHoverTask = nil
        guard isZenMode else { return }
        let hovering = isWindowHovered
        if hovering || isShaderPickerOpen {
            withAnimation(Self.zenAnimation) {
                isZenActive = false
            }
            return
        }
        zenHoverTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard !Task.isCancelled, isZenMode,
                  isWindowHovered == hovering,
                  hovering || !isShaderPickerOpen else { return }
            withAnimation(Self.zenAnimation) {
                isZenActive = !hovering
                if !hovering { lyricsColumnHold = false }
            }
        }
    }

    private var zenButton: some View {
        Button {
            isZenMode.toggle()
            scheduleZenHoverChange()
            if !isZenMode {
                withAnimation(Self.zenAnimation) { isZenActive = false }
            }
        } label: {
            Image(systemName: isZenMode ? "moon.fill" : "moon")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.pressable)
        .help(isZenMode ? "关闭 Zen 模式" : "开启 Zen 模式")
        .accessibilityLabel(isZenMode ? "关闭 Zen 模式" : "开启 Zen 模式")
    }

    private var fmRoamingBadge: some View {
        Image(systemName: "wave.3.right.circle.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(width: 36, height: 36)
            .background(.white.opacity(0.12), in: Circle())
            .accessibilityLabel("私人漫游")
    }
    #endif

    private func controls(showsRoamingBadge: Bool = true,
                          showsRoutePicker: Bool = true) -> some View {
        // Equal-width slots so the row always fits the screen: fixed-size
        // buttons in a plain HStack summed wider than a phone (≈430pt with the
        // like button), overflowing the layout and shoving the overlays and
        // metadata off the right edge. `maxWidth: .infinity` per control makes
        // the row scale to any width instead.
        HStack(spacing: 0) {
            if let track = player.currentTrack {
                let liked = account.isLiked(track.id)
                circleButton(
                    icon: liked ? "heart.fill" : "heart",
                    size: 15, tint: liked ? Theme.accent : nil
                ) {
                    appStore?.send(.account(.toggleLike(track.id)))
                }
                #if os(macOS)
                .heroAnchor(HeroID.nowPlayingLikeTarget)
                .nowPlayingHeroTarget(
                    id: HeroID.nowPlayingLike,
                    content: .icon(name: liked ? "heart.fill" : "heart",
                                   tint: liked ? Theme.accent : .white.opacity(0.8), background: .translucentWhite,
                                   diameter: 40, fontSize: 15, weight: .medium),
                    anchorID: HeroID.nowPlayingLikeTarget,
                    isPresented: appStore?.isNowPlayingPresented == true,
                    hasStarted: $hasStartedLikeFlight
                )
                .opacity(heroFlight.active[HeroID.nowPlayingLike] != nil ? 0 : 1)
                #endif
                .frame(maxWidth: .infinity)
            }

            if player.isFMMode {
                circleButton(icon: "trash", size: 14) {
                    appStore?.send(.player(.fmTrash))
                }
                #if os(macOS)
                .heroAnchor(HeroID.nowPlayingFMTrashTarget)
                .nowPlayingHeroTarget(
                    id: HeroID.nowPlayingFMTrash,
                    content: .icon(name: "trash",
                                   tint: .white.opacity(0.8), background: .translucentWhite,
                                   diameter: 40, fontSize: 14, weight: .medium),
                    anchorID: HeroID.nowPlayingFMTrashTarget,
                    isPresented: appStore?.isNowPlayingPresented == true,
                    hasStarted: $hasStartedFMTrashFlight
                )
                .opacity(heroFlight.active[HeroID.nowPlayingFMTrash] != nil ? 0 : 1)
                #endif
                .frame(maxWidth: .infinity)
            } else {
                circleButton(
                    icon: "shuffle", size: 14,
                    tint: player.shuffleEnabled ? Theme.accent : nil
                ) {
                    appStore?.send(.player(.toggleShuffle))
                }
                #if os(macOS)
                .heroAnchor(HeroID.nowPlayingShuffleTarget)
                .nowPlayingHeroTarget(
                    id: HeroID.nowPlayingShuffle,
                    content: .icon(name: "shuffle",
                                   tint: player.shuffleEnabled ? Theme.accent : .white.opacity(0.8), background: .translucentWhite,
                                   diameter: 40, fontSize: 14, weight: .medium),
                    anchorID: HeroID.nowPlayingShuffleTarget,
                    isPresented: appStore?.isNowPlayingPresented == true,
                    hasStarted: $hasStartedShuffleFlight
                )
                .opacity(heroFlight.active[HeroID.nowPlayingShuffle] != nil ? 0 : 1)
                #endif
                .frame(maxWidth: .infinity)
                circleButton(icon: "backward.fill", size: 16) {
                    appStore?.send(.player(.previous))
                }
                #if os(macOS)
                .heroAnchor(HeroID.nowPlayingPreviousTarget)
                .nowPlayingHeroTarget(
                    id: HeroID.nowPlayingPrevious,
                    content: .icon(name: "backward.fill",
                                   tint: .white.opacity(0.8), background: .translucentWhite,
                                   diameter: 40, fontSize: 16, weight: .medium),
                    anchorID: HeroID.nowPlayingPreviousTarget,
                    isPresented: appStore?.isNowPlayingPresented == true,
                    hasStarted: $hasStartedPreviousFlight
                )
                .opacity(heroFlight.active[HeroID.nowPlayingPrevious] != nil ? 0 : 1)
                #endif
                .frame(maxWidth: .infinity)
            }

            playPauseButton
                .frame(maxWidth: .infinity)

            circleButton(icon: "forward.fill", size: 16) {
                appStore?.send(.player(.next))
            }
            #if os(macOS)
            .heroAnchor(HeroID.nowPlayingNextTarget)
            .nowPlayingHeroTarget(
                id: HeroID.nowPlayingNext,
                content: .icon(name: "forward.fill",
                               tint: .white.opacity(0.8), background: .translucentWhite,
                               diameter: 40, fontSize: 16, weight: .medium),
                anchorID: HeroID.nowPlayingNextTarget,
                isPresented: appStore?.isNowPlayingPresented == true,
                hasStarted: $hasStartedNextFlight
            )
            .opacity(heroFlight.active[HeroID.nowPlayingNext] != nil ? 0 : 1)
            #endif
            .frame(maxWidth: .infinity)

            if showsRoutePicker {
                RoutePickerButton(diameter: 40, glyphSize: 15)
                    .frame(maxWidth: .infinity)
            }

            if player.isFMMode {
                if showsRoamingBadge {
                    Image(systemName: "wave.3.right.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 40, height: 40)
                        .frame(maxWidth: .infinity)
                }
            } else {
                circleButton(
                    icon: player.repeatMode == .one ? "repeat.1" : "repeat",
                    size: 14,
                    tint: player.repeatMode != .off ? Theme.accent : nil
                ) {
                    appStore?.send(.player(.cycleRepeatMode))
                }
                #if os(macOS)
                .heroAnchor(HeroID.nowPlayingRepeatTarget)
                .nowPlayingHeroTarget(
                    id: HeroID.nowPlayingRepeat,
                    content: .icon(name: player.repeatMode == .one ? "repeat.1" : "repeat",
                                   tint: player.repeatMode != .off ? Theme.accent : .white.opacity(0.8), background: .translucentWhite,
                                   diameter: 40, fontSize: 14, weight: .medium),
                    anchorID: HeroID.nowPlayingRepeatTarget,
                    isPresented: appStore?.isNowPlayingPresented == true,
                    hasStarted: $hasStartedRepeatFlight
                )
                .opacity(heroFlight.active[HeroID.nowPlayingRepeat] != nil ? 0 : 1)
                #endif
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var playPauseButton: some View {
        Button {
            appStore?.send(.player(.togglePlayPause))
        } label: {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: 58, height: 58)
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .contentTransition(.opacity)
            }
        }
        .buttonStyle(.pressable)
        #if os(macOS)
        .heroAnchor(HeroID.nowPlayingPlayPauseTarget)
        .nowPlayingHeroTarget(
            id: HeroID.nowPlayingPlayPause,
            content: .icon(name: player.isPlaying ? "pause.fill" : "play.fill",
                           tint: .black.opacity(0.85), background: .white, diameter: 58, fontSize: 21),
            anchorID: HeroID.nowPlayingPlayPauseTarget,
            isPresented: appStore?.isNowPlayingPresented == true,
            hasStarted: $hasStartedPlayPauseFlight
        )
        .opacity(heroFlight.active[HeroID.nowPlayingPlayPause] != nil ? 0 : 1)
        #endif
    }

    private func circleButton(icon: String, size: CGFloat,
                              tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint ?? .white.opacity(0.8))
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.1), in: Circle())
        }
        .buttonStyle(.pressable)
    }

    // MARK: - Lyrics column

    @ViewBuilder
    private var lyricsColumn: some View {
        if let lyrics = player.lyrics, !lyrics.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        Color.clear.frame(height: max(viewportFrame.height / 2 - 40, 200))
                        ForEach(lyrics.lines) { line in
                            bigLyricLine(line, isActive: line.id == activeIndex,
                                         center: viewportFrame.minY + viewportFrame.height * lyricFocusY,
                                         span: viewportFrame.height / 2)
                                .id(line.id)
                        }
                        Color.clear.frame(height: max(viewportFrame.height / 2 - 40, 240))
                    }
                    .padding(.horizontal, 24)
                }
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.12),
                            .init(color: .black, location: 0.85),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { viewportFrame = geo.frame(in: .global) }
                            .onChange(of: geo.frame(in: .global)) { _, frame in viewportFrame = frame }
                    }
                )
                .onChange(of: player.lyricsCursorIndex) { _, index in
                    guard index != activeIndex else { return }
                    activeIndex = index
                    guard !isUserScrolling, let index else { return }
                    withAnimation(.spring(response: 0.8, dampingFraction: 0.85)) {
                        proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: lyricFocusY))
                    }
                }
                .onAppear {
                    // The cursor only fires on a line change, which can be many
                    // seconds away — on re-entering the page, adopt where the
                    // song already is instead of waiting for the next line.
                    adoptCursor(proxy: proxy)
                }
                .simultaneousGesture(
                    DragGesture().onChanged { _ in
                        isUserScrolling = true
                        resumeTask?.cancel()
                        resumeTask = Task {
                            try? await Task.sleep(for: .seconds(3))
                            guard !Task.isCancelled else { return }
                            isUserScrolling = false
                        }
                    }
                )
            }
            // A new playback session needs a fresh scroll position even when
            // SwiftUI coalesces the intermediate lyrics=nil update.
            .id(player.resolveGeneration)
        } else if lyricsColumnHold {
            Color.clear
        } else if player.lyrics?.isInstrumental == true {
            VStack(spacing: 10) {
                Image(systemName: "music.quarternote.3")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.white.opacity(0.4))
                Text("纯音乐，请欣赏")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func bigLyricLine(_ line: LyricLine, isActive: Bool, center: CGFloat, span: CGFloat) -> some View {
        Button {
            // The click that brings an inactive app to the front is only an
            // activation: a lyric line needs the app to have been active for a
            // beat before it will jump the song.
            guard LyricTapGate.shared.allowsTap else { return }
            appStore?.send(.player(.seek(line.time)))
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                if settings.lyricsAnnotation == .romaji, let romaji = line.romaji {
                    Text(romaji)
                        .font(.system(size: isActive ? 15 : 13, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                }
                LyricMainText(
                    line: line, isActive: isActive,
                    size: isActive ? 26 : 20, weight: isActive ? .bold : .semibold,
                    verbatim: settings.verbatimLyrics
                )
                if settings.showLyricsTranslation, let translation = line.translation {
                    Text(translation)
                        .font(.system(size: isActive ? 16 : 14, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .modifier(EdgeBlur(center: center, span: span))
            .scaleEffect(isActive ? 1.02 : 1, anchor: .leading)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isActive)
    }
}


/// The main lyric line. Renders karaoke-style per-character highlighting from
/// verbatim (`yrc`) timings, driven live by the player, when the line is active
/// and verbatim data exists; otherwise a plain line.
///
/// Whether the line carries furigana is `LyricText`'s decision; the wipe is
/// handed down as per-character opacity so it reads the same either way.
struct LyricMainText: View {
    let line: LyricLine
    let isActive: Bool
    let size: CGFloat
    let weight: Font.Weight
    let verbatim: Bool
    var inactiveOpacity: Double = 0.45

    @Environment(\.appStore) private var appStore: StoreOf<AppFeature>?
    // Views read the same engine injected into the app store.
    private var playback: PlaybackEngineClient { PlaybackEngineAdapter.client }

    private var player: PlayerFeature.State { appStore?.player ?? .init() }

    var body: some View {
        if isActive, verbatim, let words = line.words, !words.isEmpty {
            TimelineView(.animation(paused: !player.isPlaying)) { _ in
                LyricText(
                    line: line, size: size, weight: weight, color: .white,
                    alphas: Self.alphas(for: line, words: words, at: playback.currentTime())
                )
            }
        } else {
            LyricText(
                line: line, size: size, weight: weight,
                color: .white.opacity(isActive ? 1 : inactiveOpacity)
            )
        }
    }

    /// One opacity per character of `line.text`: sung characters are bright,
    /// the current one fades in, unsung stay dim.
    static func alphas(for line: LyricLine, words: [LyricWord], at time: TimeInterval) -> [Double] {
        let unsung = 0.28
        var out: [Double] = []
        for word in words {
            let chars = Array(word.text)
            let per = chars.isEmpty ? word.duration : word.duration / Double(chars.count)
            for index in chars.indices {
                let charStart = word.start + per * Double(index)
                let frac = per > 0 ? min(max((time - charStart) / per, 0), 1)
                                   : (time >= charStart ? 1 : 0)
                out.append(unsung + (1 - unsung) * frac)
            }
        }
        // `line.text` is the words joined and *then* trimmed, so drop the
        // opacities for whitespace the line no longer starts with.
        let joined = words.map(\.text).joined()
        guard joined.count != line.text.count else { return out }
        let leading = joined.count - joined.drop(while: \.isWhitespace).count
        return Array(out.dropFirst(leading).prefix(line.text.count))
    }
}

/// Picker-style top/bottom blur: a line stays sharp at the viewport's center
/// and blurs progressively toward the top and bottom edges, the falloff
/// running 0 → `maxRadius` over `span` points on either side of `center`.
///
/// The lyrics column used to blur every line that was not the current one,
/// which left a single hard step between sharp and soft. This replaces it
/// with a positional ramp, so the blur follows where a line sits rather than
/// which line it is — the current line ends up centered, and everything else
/// softens away above and below it.
struct EdgeBlur: ViewModifier {
    /// Center line of the viewport, in global coordinates.
    var center: CGFloat
    /// Points from center at which the blur reaches `maxRadius`.
    var span: CGFloat
    /// Blur radius at the top/bottom edges.
    var maxRadius: CGFloat = 8
    /// Bottom falloff multiplier. Above 1 the blur rises more slowly below the
    /// center than above it, so the *next* line stays readable while the top
    /// of the list still fades out fully.
    var bottomFalloff: CGFloat = 3.5

    @State private var midY: CGFloat = .zero

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { midY = geo.frame(in: .global).midY }
                        .onChange(of: geo.frame(in: .global).midY) { _, value in midY = value }
                }
            )
            .blur(radius: radius)
    }

    private var radius: CGFloat {
        guard span > 0 else { return 0 }
        let delta = midY - center
        if delta <= 0 {
            return min(-delta / span, 1) * maxRadius
        }
        return min(delta / (span * bottomFalloff), 1) * maxRadius
    }
}

#if os(iOS)
private struct IOSImmersiveLyricsColumn: View {
    @Environment(\.appStore) private var appStore: StoreOf<AppFeature>?

    private var player: PlayerFeature.State { appStore?.player ?? .init() }

    private var settings: SettingsFeature.State { appStore?.settings ?? .init() }

    @State private var activeIndex: Int?
    @State private var isUserScrolling = false
    @State private var resumeTask: Task<Void, Never>?
    /// Viewport for the positional lyric blur.
    @State private var viewportFrame: CGRect = .zero

    var body: some View {
        Group {
            if let lyrics = player.lyrics, !lyrics.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            Color.clear.frame(height: max(viewportFrame.height / 2 - 40, 72))
                            ForEach(lyrics.lines) { line in
                                lyricLine(
                                    line,
                                    isActive: line.id == activeIndex,
                                    center: viewportFrame.minY + viewportFrame.height * lyricFocusY,
                                    span: viewportFrame.height / 2
                                )
                                .id(line.id)
                            }
                            Color.clear.frame(height: max(viewportFrame.height / 2 - 40, 96))
                        }
                        .padding(.horizontal, 4)
                    }
                    .mask(edgeMask)
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { viewportFrame = geo.frame(in: .global) }
                                .onChange(of: geo.frame(in: .global)) { _, frame in viewportFrame = frame }
                        }
                    )
                    .accessibilityIdentifier("syncedLyricsScroll")
                    .onChange(of: player.lyricsCursorIndex) { _, index in
                        guard index != activeIndex else { return }
                        activeIndex = index
                        guard !isUserScrolling, let index else { return }
                        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.38)) {
                            proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: lyricFocusY))
                        }
                    }
                    .onAppear {
                        adoptCursor(proxy: proxy)
                    }
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { _ in
                                isUserScrolling = true
                                resumeTask?.cancel()
                                resumeTask = Task { @MainActor in
                                    try? await Task.sleep(for: .seconds(3))
                                    guard !Task.isCancelled else { return }
                                    isUserScrolling = false
                                    if let activeIndex {
                                        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                                            proxy.scrollTo(activeIndex, anchor: UnitPoint(x: 0.5, y: lyricFocusY))
                                        }
                                    }
                                }
                            }
                    )
                }
                .id(player.resolveGeneration)
            } else if player.lyrics?.isInstrumental == true {
                VStack(spacing: 10) {
                    Image(systemName: "music.quarternote.3")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("纯音乐，请欣赏")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDisappear {
            resumeTask?.cancel()
        }
    }


    /// Jump straight to the line the song is on. Used when the view appears,
    /// where waiting for the next line change would leave the lyrics parked at
    /// the top. Scrolling is deferred a turn: the list has not laid out yet
    /// while `onAppear` runs, and `scrollTo` on an unlaid list does nothing.
    private func adoptCursor(proxy: ScrollViewProxy) {
        let index = player.lyricsCursorIndex
        activeIndex = index
        resumeTask?.cancel()
        isUserScrolling = false
        // Before the first timestamp there is no active line, but the new
        // song must still display its first lyric at the focus position.
        guard let index = index ?? player.lyrics?.lines.first?.id else { return }
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: lyricFocusY))
            }
        }
    }

    private var edgeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.85),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func lyricLine(_ line: LyricLine, isActive: Bool, center: CGFloat, span: CGFloat) -> some View {
        Button {
            guard LyricTapGate.shared.allowsTap else { return }
            appStore?.send(.player(.seek(line.time)))
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                if settings.lyricsAnnotation == .romaji, let romaji = line.romaji {
                    Text(romaji)
                        .font(.system(size: isActive ? 15 : 13, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.75 : 0.4))
                }

                LyricMainText(
                    line: line,
                    isActive: isActive,
                    size: isActive ? 26 : 21,
                    weight: isActive ? .bold : .semibold,
                    verbatim: settings.verbatimLyrics
                )

                if settings.showLyricsTranslation, let translation = line.translation {
                    Text(translation)
                        .font(.system(size: isActive ? 16 : 14, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.75 : 0.4))
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .modifier(EdgeBlur(center: center, span: span))
            .scaleEffect(isActive ? 1.02 : 1.0, anchor: .leading)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isActive)
    }
}

// MARK: - Compact now-playing sections

private enum ImmersiveArtworkTransition {
    /// A time-based ease-out curve stays fluid at the display's native refresh rate.
    static let animation = Animation.timingCurve(
        0.16,
        1,
        0.3,
        1,
        duration: 0.42
    )
    static let compactArtworkDimension: CGFloat = 62
    static let compactHeaderSpacing: CGFloat = 13
    static let expandedMetadataOffset = -(
        compactArtworkDimension + compactHeaderSpacing
    )
}

private enum ImmersiveArtworkFrame: Hashable {
    case compact
    case expanded
}

private struct ImmersiveArtworkFramePreferenceKey: PreferenceKey {
    static var defaultValue: [ImmersiveArtworkFrame: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [ImmersiveArtworkFrame: Anchor<CGRect>],
        nextValue: () -> [ImmersiveArtworkFrame: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct CompactTrackHeader: View {
    @Environment(\.appStore) private var appStore: StoreOf<AppFeature>?

    private var player: PlayerFeature.State { appStore?.player ?? .init() }

    private var account: AccountFeature.State { appStore?.account ?? .init() }
    @State private var showAddToPlaylist = false

    let showsExpandedArtwork: Bool
    let onOpenDestination: (Destination) -> Void
    /// Tap handler for the compact cover (used to collapse lyrics back to
    /// artwork). The real image floats above this placeholder with hit-testing
    /// disabled, so taps land here.
    var onTapArtwork: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: ImmersiveArtworkTransition.compactHeaderSpacing) {
            Color.clear
                .frame(
                    width: ImmersiveArtworkTransition.compactArtworkDimension,
                    height: ImmersiveArtworkTransition.compactArtworkDimension
                )
                .anchorPreference(
                    key: ImmersiveArtworkFramePreferenceKey.self,
                    value: .bounds
                ) { [.compact: $0] }
                .contentShape(Rectangle())
                .onTapGesture { onTapArtwork?() }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(player.currentTrack?.name ?? "")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if player.currentTrack?.fee == 1 {
                        VIPBadge()
                    }
                }
                if let track = player.currentTrack {
                    NowPlayingTrackDestinationLinks(
                        track: track,
                        font: .subheadline,
                        color: .white.opacity(0.62),
                        onOpenDestination: onOpenDestination
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(
                x: showsExpandedArtwork
                    ? ImmersiveArtworkTransition.expandedMetadataOffset
                    : 0
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("immersiveTrackMetadata")

            if let track = player.currentTrack {
                let liked = account.isLiked(track.id)
                HStack(spacing: 0) {
                    Button {
                        appStore?.send(.account(.toggleLike(track.id)))
                    } label: {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(liked ? Theme.accent : .white.opacity(0.88))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel(liked ? "取消收藏" : "收藏")
                    .accessibilityIdentifier("immersiveFavoriteButton")

                    Menu {
                        Button {
                            appStore?.send(.player(.addToPlayNext(track, playNow: false)))
                        } label: {
                            Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }

                        Button {
                            showAddToPlaylist = true
                        } label: {
                            Label("加入歌单…", systemImage: "music.note.list")
                        }

                        Divider()

                        #if os(iOS)
                        if let appStore {
                            SleepTimerMenu(store: appStore.scope(state: \.player, action: \.player))
                        }

                        Divider()
                        #endif

                        Button {
                            Platform.copyToPasteboard(
                                string: "https://music.163.com/#/song?id=\(track.id)"
                            )
                            appStore?.send(.toasts(.presented(String(localized: "链接已复制"))))
                        } label: {
                            Label("复制链接", systemImage: "link")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("更多操作")
                    .accessibilityIdentifier("immersiveMoreMenu")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = player.currentTrack, let appStore {
                AddToPlaylistSheet(track: track, appStore: appStore)
            }
        }
    }
}

private struct CompactTransportControls: View {
    @Environment(\.appStore) private var appStore: StoreOf<AppFeature>?

    private var player: PlayerFeature.State { appStore?.player ?? .init() }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: { appStore?.send(.player(player.isFMMode ? .fmTrash : .previous)) }) {
                Image(systemName: player.isFMMode ? "trash" : "backward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .accessibilityLabel(player.isFMMode ? "不喜欢" : "上一首")

            Button(action: { appStore?.send(.player(.togglePlayPause)) }) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 36, weight: .bold))
                    .contentTransition(.opacity)
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

            Button(action: { appStore?.send(.player(.next)) }) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .accessibilityLabel("下一首")
        }
        .foregroundStyle(.white)
        .buttonStyle(.pressable)
    }
}

private struct CompactVolumeControl: View {
    @Environment(\.appStore) private var appStore: StoreOf<AppFeature>?

    private var player: PlayerFeature.State { appStore?.player ?? .init() }
    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "speaker.fill")
                .font(.caption2)
            // One GeometryReader with the gesture on the ZStack. A nested
            // GeometryReader (the old TranslucentSliderTrack) silently dropped
            // the drag, so the volume slider did nothing (#37).
            GeometryReader { geo in
                let width = geo.size.width
                let fraction = min(max(CGFloat(player.volume), 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.28))
                    Capsule().fill(.white.opacity(0.78))
                        .frame(width: width * fraction)
                }
                .frame(height: isDragging ? 10 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            updateVolume(at: value.location.x, width: width)
                        }
                        .onEnded { value in
                            updateVolume(at: value.location.x, width: width)
                            isDragging = false
                        }
                )
                .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isDragging)
            }
            .frame(height: 24)
            .accessibilityElement()
            .accessibilityLabel("音量")
            .accessibilityValue("\(Int((player.volume * 100).rounded()))%")
            .accessibilityAdjustableAction(adjustVolume)
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption)
        }
        .foregroundStyle(.white.opacity(0.7))
    }

    private func updateVolume(at location: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        appStore?.send(.player(.setVolume(Float(min(max(location / width, 0), 1)))))
    }

    private func adjustVolume(_ direction: AccessibilityAdjustmentDirection) {
        let step: Float = 0.05
        switch direction {
        case .increment:
            appStore?.send(.player(.setVolume(min(player.volume + step, 1))))
        case .decrement:
            appStore?.send(.player(.setVolume(max(player.volume - step, 0))))
        @unknown default:
            break
        }
    }
}

private struct CompactSecondaryControls: View {
    @Environment(\.appStore) private var appStore: StoreOf<AppFeature>?
    let showsLyrics: Bool
    let showsQueue: Bool
    let onToggleLyrics: () -> Void
    let onToggleQueue: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            secondaryButton(
                icon: showsLyrics && !showsQueue ? "quote.bubble.fill" : "quote.bubble",
                label: showsLyrics ? "显示封面" : "显示歌词",
                isActive: showsLyrics && !showsQueue
            ) { onToggleLyrics() }

            RoutePickerButton(diameter: 44, glyphSize: 17)
                .frame(maxWidth: .infinity)

            secondaryButton(
                icon: "list.bullet",
                label: showsQueue ? "关闭播放队列" : "显示播放队列",
                isActive: showsQueue
            ) { onToggleQueue() }
        }
    }

    private func secondaryButton(
        icon: String,
        label: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isActive ? Theme.accent : .white.opacity(0.72))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.08), in: Circle())
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct CompactQueueContent: View {
    @Environment(\.appStore) private var appStore: StoreOf<AppFeature>?

    private var player: PlayerFeature.State { appStore?.player ?? .init() }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                modeButton(
                    icon: "arrow.right",
                    label: "顺序播放",
                    isActive: !player.shuffleEnabled && player.repeatMode == .off,
                    action: enableSequentialPlayback
                )
                modeButton(
                    icon: "shuffle",
                    label: player.shuffleEnabled ? "关闭随机播放" : "随机播放",
                    isActive: player.shuffleEnabled,
                    action: { appStore?.send(.player(.toggleShuffle)) }
                )
                modeButton(
                    icon: "repeat",
                    label: "列表循环",
                    isActive: player.repeatMode == .all
                ) {
                    appStore?.send(.player(.setRepeatMode(player.repeatMode == .all ? .off : .all)))
                }
                modeButton(
                    icon: "repeat.1",
                    label: "单曲循环",
                    isActive: player.repeatMode == .one
                ) {
                    appStore?.send(.player(.setRepeatMode(player.repeatMode == .one ? .off : .one)))
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text("继续播放")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(player.upcomingTracks.count) 首")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.46))
            }

            if player.upcomingTracks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 28, weight: .light))
                    Text("播放队列是空的")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(
                            Array(player.upcomingTracks.prefix(100).enumerated()),
                            id: \.offset
                        ) { _, track in
                            CompactQueueRow(track: track)
                        }
                    }
                }
                .mask(
                    LinearGradient(
                        colors: [.black, .black, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .padding(.top, 6)
    }

    private func modeButton(
        icon: String,
        label: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isActive ? Color.black.opacity(0.76) : .white.opacity(0.76))
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(
                    isActive ? AnyShapeStyle(.white.opacity(0.66)) : AnyShapeStyle(.white.opacity(0.1)),
                    in: Capsule()
                )
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func enableSequentialPlayback() {
        if player.shuffleEnabled {
            appStore?.send(.player(.toggleShuffle))
        }
        appStore?.send(.player(.setRepeatMode(.off)))
    }
}

private struct CompactQueueRow: View {
    let track: Track

    @Environment(\.appStore) private var appStore: StoreOf<AppFeature>?

    private var player: PlayerFeature.State { appStore?.player ?? .init() }

    var body: some View {
        Button {
            appStore?.send(.player(.jumpTo(track)))
        } label: {
            HStack(spacing: 11) {
                CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(120), animated: false)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Text(track.artistNames)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text(Formatters.duration(track.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.36))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(track.name)，\(track.artistNames)")
    }
}



private struct IOSMinimalLyricsColumn: View {
    @Environment(\.appStore) private var appStore: StoreOf<AppFeature>?

    private var player: PlayerFeature.State { appStore?.player ?? .init() }

    private var settings: SettingsFeature.State { appStore?.settings ?? .init() }

    let onClose: () -> Void

    @State private var activeIndex: Int?
    @State private var selectedIndex: Int?
    @State private var nearestIndex: Int?
    @State private var lineCenters: [Int: CGFloat] = [:]
    @State private var isDragging = false
    @State private var suppressesAutoScroll = false
    @State private var scrollSettleTask: Task<Void, Never>?
    @State private var selectionTimeoutTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let lyrics = player.lyrics, !lyrics.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                Color.clear.frame(height: geometry.size.height / 2)
                                ForEach(lyrics.lines) { line in
                                    lyricLine(
                                        line,
                                        isActive: line.id == activeIndex,
                                        isSelected: line.id == selectedIndex,
                                        availableWidth: geometry.size.width
                                    ) {
                                        guard let selectedIndex else {
                                            closeLyrics()
                                            return
                                        }
                                        guard selectedIndex == line.id else {
                                            returnToActiveLine(proxy: proxy)
                                            return
                                        }
                                        selectionTimeoutTask?.cancel()
                                        selectionTimeoutTask = nil
                                        suppressesAutoScroll = true
                                        appStore?.send(.player(.seek(line.time)))
                                        suppressesAutoScroll = false
                                        activeIndex = line.id
                                        self.selectedIndex = nil
                                        nearestIndex = nil
                                    }
                                    .id(line.id)
                                    .background {
                                        GeometryReader { lineGeometry in
                                            Color.clear.preference(
                                                key: MinimalLyricCentersKey.self,
                                                value: [
                                                    line.id: lineGeometry.frame(
                                                        in: .named("immersiveLyrics")
                                                    ).midY
                                                ]
                                            )
                                        }
                                    }
                                }
                                Color.clear.frame(height: geometry.size.height / 2)
                            }
                            .padding(.horizontal, 2)
                        }
                        .coordinateSpace(name: "immersiveLyrics")
                        .mask(edgeMask)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: closeLyrics)
                        .accessibilityIdentifier("syncedLyricsScroll")
                        .onPreferenceChange(MinimalLyricCentersKey.self) { centers in
                            lineCenters = centers
                            guard isDragging || scrollSettleTask != nil else { return }
                            nearestIndex = nearestLine(
                                to: geometry.size.height / 2,
                                in: centers
                            )
                            guard !isDragging else { return }
                            scheduleScrollSelection(
                                guideY: geometry.size.height / 2,
                                proxy: proxy
                            )
                        }
                        .onAppear {
                            activeIndex = lyrics.activeIndex(at: player.progress + 0.2)
                            if let activeIndex {
                                Task { @MainActor in
                                    await Task.yield()
                                    proxy.scrollTo(activeIndex, anchor: .center)
                                }
                            }
                        }
                        .onChange(of: player.progress) {
                            let index = lyrics.activeIndex(at: player.progress + 0.2)
                            guard index != activeIndex else { return }
                            activeIndex = index
                            guard !suppressesAutoScroll,
                                  !isDragging, scrollSettleTask == nil,
                                  selectedIndex == nil, let index else { return }
                            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.38)) {
                                proxy.scrollTo(index, anchor: .center)
                            }
                        }
                        .onChange(of: player.currentTrack?.id) {
                            activeIndex = nil
                            selectedIndex = nil
                            nearestIndex = nil
                            suppressesAutoScroll = false
                            scrollSettleTask?.cancel()
                            scrollSettleTask = nil
                            selectionTimeoutTask?.cancel()
                            selectionTimeoutTask = nil
                        }
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { _ in
                                    if !isDragging {
                                        scrollSettleTask?.cancel()
                                        scrollSettleTask = nil
                                        selectionTimeoutTask?.cancel()
                                        selectionTimeoutTask = nil
                                        selectedIndex = nil
                                        isDragging = true
                                    }
                                    nearestIndex = nearestLine(
                                        to: geometry.size.height / 2,
                                        in: lineCenters
                                    )
                                }
                                .onEnded { _ in
                                    isDragging = false
                                    scheduleScrollSelection(
                                        guideY: geometry.size.height / 2,
                                        proxy: proxy
                                    )
                                }
                        )
                        .overlay {
                            selectionGuide(lyrics: lyrics)
                        }
                    }
                } else if player.lyrics?.isInstrumental == true {
                    VStack(spacing: 10) {
                        Image(systemName: "music.quarternote.3")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.white.opacity(0.4))
                        Text("纯音乐，请欣赏")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: closeLyrics)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onDisappear {
            scrollSettleTask?.cancel()
            selectionTimeoutTask?.cancel()
        }
    }

    @ViewBuilder
    private func selectionGuide(lyrics: ParsedLyrics) -> some View {
        let isScrolling = isDragging || scrollSettleTask != nil
        if let index = isScrolling ? nearestIndex : selectedIndex,
           lyrics.lines.indices.contains(index) {
            HStack(spacing: 8) {
                if isScrolling {
                    Canvas { context, size in
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: size.height / 2))
                        path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                        context.stroke(
                            path,
                            with: .color(.white.opacity(0.45)),
                            style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                        )
                    }
                    .frame(height: 1)
                } else {
                    Spacer()
                }

                Text(Formatters.duration(lyrics.lines[index].time))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.72))
                    .offset(x: 25)
            }
            .padding(.horizontal, 2)
            .allowsHitTesting(false)
        }
    }

    private func nearestLine(to guideY: CGFloat, in centers: [Int: CGFloat]) -> Int? {
        centers.min { abs($0.value - guideY) < abs($1.value - guideY) }?.key
    }

    private func scheduleScrollSelection(guideY: CGFloat, proxy: ScrollViewProxy) {
        scrollSettleTask?.cancel()
        // ponytail: iOS 16 has no scroll phase API; replace with onScrollPhaseChange
        // when the deployment target reaches iOS 18.
        scrollSettleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let selection = nearestLine(to: guideY, in: lineCenters) ?? nearestIndex
            selectedIndex = selection
            nearestIndex = selection
            scrollSettleTask = nil
            guard let selection else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                proxy.scrollTo(selection, anchor: .center)
            }
            scheduleSelectionTimeout(proxy: proxy)
        }
    }

    private func scheduleSelectionTimeout(proxy: ScrollViewProxy) {
        selectionTimeoutTask?.cancel()
        selectionTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, selectedIndex != nil else { return }
            returnToActiveLine(proxy: proxy)
        }
    }

    private func returnToActiveLine(proxy: ScrollViewProxy) {
        selectionTimeoutTask?.cancel()
        selectionTimeoutTask = nil
        selectedIndex = nil
        nearestIndex = nil
        guard let activeIndex else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            proxy.scrollTo(activeIndex, anchor: .center)
        }
    }

    private func closeLyrics() {
        scrollSettleTask?.cancel()
        scrollSettleTask = nil
        selectionTimeoutTask?.cancel()
        selectionTimeoutTask = nil
        selectedIndex = nil
        nearestIndex = nil
        isDragging = false
        onClose()
    }

    private var edgeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.85),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func lyricLine(
        _ line: LyricLine,
        isActive: Bool,
        isSelected: Bool,
        availableWidth: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                if settings.lyricsAnnotation == .romaji, let romaji = line.romaji {
                    Text(romaji)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                        .fixedSize(horizontal: false, vertical: true)
                        .scaleEffect(isActive ? 1.02 : 12.0 / 13.0, anchor: .leading)
                }

                LyricMainText(
                    line: line, isActive: isActive,
                    size: 17, weight: .bold,
                    verbatim: settings.verbatimLyrics
                )
                    .fixedSize(horizontal: false, vertical: true)
                    .scaleEffect(isActive ? 1.02 : 16.0 / 17.0, anchor: .leading)

                if settings.showLyricsTranslation, let translation = line.translation {
                    Text(translation)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                        .fixedSize(horizontal: false, vertical: true)
                        .scaleEffect(isActive ? 1.02 : 12.0 / 13.0, anchor: .leading)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(isSelected ? 0.14 : 0))
            )
            .contentShape(Rectangle())
            .padding(.trailing, availableWidth * (1 - 1 / 1.02))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: isActive)
        .animation(.easeOut(duration: 0.18), value: isSelected)
    }
}

private struct MinimalLyricCentersKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

// MARK: - Minimal track info row

private struct MinimalTrackInfoRow: View {
    @Environment(\.appStore) private var appStore: StoreOf<AppFeature>?

    private var player: PlayerFeature.State { appStore?.player ?? .init() }

    private var account: AccountFeature.State { appStore?.account ?? .init() }
    @State private var showAddToPlaylist = false
    @State private var airPlayRequest = 0
    let onOpenDestination: (Destination) -> Void
    var metadataOnly = false
    var actionsOnly = false

    var body: some View {
        Group {
            if metadataOnly {
                metadata(alignment: .center, textAlignment: .center)
                    .padding(.horizontal, 48)
            } else if actionsOnly {
                if let track = player.currentTrack {
                    HStack {
                        favoriteButton(for: track)
                        Spacer()
                        moreMenu(for: track)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    metadata(alignment: .leading, textAlignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let track = player.currentTrack {
                        favoriteButton(for: track)
                        moreMenu(for: track)
                    }
                }
            }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = player.currentTrack, let appStore {
                AddToPlaylistSheet(track: track, appStore: appStore)
            }
        }
    }

    private func metadata(
        alignment: HorizontalAlignment,
        textAlignment: TextAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            HStack(spacing: 6) {
                Text(player.currentTrack?.name ?? "")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if player.currentTrack?.fee == 1 {
                    VIPBadge()
                }
            }
            if let track = player.currentTrack {
                NowPlayingTrackDestinationLinks(
                    track: track,
                    font: .footnote,
                    color: .white.opacity(0.62),
                    onOpenDestination: onOpenDestination
                )
            }
        }
        .multilineTextAlignment(textAlignment)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("immersiveTrackMetadata")
    }

    private func favoriteButton(for track: Track) -> some View {
        let liked = account.isLiked(track.id)
        return Button {
            appStore?.send(.account(.toggleLike(track.id)))
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(liked ? Theme.accent : .white.opacity(0.88))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(liked ? "取消收藏" : "收藏")
        .accessibilityIdentifier("immersiveFavoriteButton")
    }

    private func moreMenu(for track: Track) -> some View {
        Menu {
            Button {
                airPlayRequest += 1
            } label: {
                Label("AirPlay", systemImage: "airplayaudio")
            }

            Button {
                appStore?.send(.player(.addToPlayNext(track, playNow: false)))
            } label: {
                Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                showAddToPlaylist = true
            } label: {
                Label("加入歌单…", systemImage: "music.note.list")
            }

            Divider()

            #if os(iOS)
            if let appStore {
                SleepTimerMenu(store: appStore.scope(state: \.player, action: \.player))
            }

            Divider()
            #endif

            Button {
                Platform.copyToPasteboard(
                    string: "https://music.163.com/#/song?id=\(track.id)"
                )
                appStore?.send(.toasts(.presented(String(localized: "链接已复制"))))
            } label: {
                Label("复制链接", systemImage: "link")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("更多操作")
        .accessibilityIdentifier("immersiveMoreMenu")
        .background {
            RoutePickerButton(
                diameter: 1, glyphSize: 1, request: airPlayRequest,
                tint: .clear, background: .clear
            )
            .opacity(0.01)
        }
    }
}

private struct MinimalTransportControls: View {
    @Environment(\.appStore) private var appStore: StoreOf<AppFeature>?

    private var player: PlayerFeature.State { appStore?.player ?? .init() }
    let backdrop: ArtworkColors
    @Binding var showQueue: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button {
                showQueue = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityLabel("播放列表")
            .accessibilityIdentifier("immersivePlaylistButton")
                .frame(maxWidth: .infinity)

            Button(action: { appStore?.send(.player(player.isFMMode ? .fmTrash : .previous)) }) {
                Image(systemName: player.isFMMode ? "trash" : "backward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .accessibilityLabel(player.isFMMode ? "不喜欢" : "上一首")

            Button(action: { appStore?.send(.player(.togglePlayPause)) }) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 38, weight: .bold))
                    .contentTransition(.opacity)
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

            Button(action: { appStore?.send(.player(.next)) }) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .accessibilityLabel("下一首")

            playbackModeButton
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .buttonStyle(.pressable)
        .sheet(isPresented: $showQueue) {
            queueSheet
        }
    }

    @ViewBuilder
    private var queueSheet: some View {
        if #available(iOS 16.4, *) {
            MinimalQueueSheet(backdrop: backdrop)
                .presentationDetents([.fraction(0.5)])
                .presentationBackgroundInteraction(.enabled)
        } else {
            MinimalQueueSheet(backdrop: backdrop)
                .presentationDetents([.fraction(0.5)])
        }
    }

    @ViewBuilder
    private var playbackModeButton: some View {
        if player.isFMMode {
            Color.clear
                .frame(height: 44)
        } else {
            Button {
                appStore?.send(.player(.cyclePlaybackMode))
            } label: {
                Image(systemName: playbackModeIcon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(playbackModeTint)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playbackModeLabel)
        }
    }

    private var playbackModeIcon: String {
        if player.shuffleEnabled { return "shuffle" }
        switch player.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private var playbackModeTint: Color {
        (player.shuffleEnabled || player.repeatMode != .off)
            ? Theme.accent
            : .white.opacity(0.88)
    }

    private var playbackModeLabel: String {
        if player.shuffleEnabled { return "随机播放" }
        switch player.repeatMode {
        case .off: return "顺序播放"
        case .all: return "列表循环"
        case .one: return "单曲循环"
        }
    }
}

private struct MinimalQueueSheet: View {
    @Environment(\.appStore) private var appStore: StoreOf<AppFeature>?

    private var player: PlayerFeature.State { appStore?.player ?? .init() }
    let backdrop: ArtworkColors

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    if let current = player.currentTrack {
                        MinimalQueueSectionLabel("正在播放")
                        MinimalQueueRow(track: current, isCurrent: true)

                        if !player.upcomingTracks.isEmpty {
                            MinimalQueueSectionLabel("即将播放")
                                .padding(.top, 10)
                            ForEach(
                                Array(player.upcomingTracks.prefix(100).enumerated()),
                                id: \.offset
                            ) { _, track in
                                MinimalQueueRow(track: track, isCurrent: false)
                            }
                        }
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 28, weight: .light))
                            Text("播放队列是空的")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 240)
                    }
                }
                .padding(10)
            }
            .navigationTitle("播放列表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(player.upcomingTracks.count + (player.hasCurrentTrack ? 1 : 0)) 首")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .background(queueBackdrop)
    }

    private var queueBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [backdrop.primary.color, backdrop.secondary.color],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Color.black.opacity(0.45)
        }
        .ignoresSafeArea()
    }
}

private struct MinimalQueueSectionLabel: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

private struct MinimalQueueRow: View {
    let track: Track
    let isCurrent: Bool

    @Environment(\.appStore) private var appStore: StoreOf<AppFeature>?

    private var player: PlayerFeature.State { appStore?.player ?? .init() }

    var body: some View {
        Button {
            guard !isCurrent else { return }
            appStore?.send(.player(.jumpTo(track)))
        } label: {
            HStack(spacing: 10) {
                CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(96), animated: false)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(isCurrent ? Theme.accent : .primary)
                        .lineLimit(1)
                    Text(track.artistNames)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if isCurrent {
                    PlayingIndicator(animating: player.isPlaying)
                } else {
                    Text(Formatters.duration(track.duration))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#endif


// MARK: - Scrubber (white-on-dark variant)

struct NowPlayingScrubber: View {
    @Environment(\.appStore) private var appStore: StoreOf<AppFeature>?

    private var player: PlayerFeature.State { appStore?.player ?? .init() }

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragProgress: Double = 0

    private var fraction: Double {
        guard player.duration > 0 else { return 0 }
        let value = isDragging ? dragProgress : player.progress
        return min(max(value / player.duration, 0), 1)
    }

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.25))
                        .frame(height: 4)
                    // How much of the stream is already buffered, behind the
                    // played position. A network stream keeps this below 1 for
                    // the whole track, so it reads as a preload fill, not a
                    // stuck loading bar.
                    if player.bufferProgress > 0 {
                        Capsule()
                            .fill(.white.opacity(0.4))
                            .frame(width: max(4, width * player.bufferProgress), height: 4)
                    }
                    Capsule()
                        .fill(.white)
                        .frame(width: max(4, width * fraction), height: 4)
                    Circle()
                        .fill(.white)
                        .frame(width: thumbDiameter, height: thumbDiameter)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: width * fraction - thumbDiameter / 2)
                        .opacity(isHovering || isDragging ? 1 : 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard player.duration > 0 else { return }
                            isDragging = true
                            
                            dragProgress = min(max(value.location.x / width, 0), 1) * player.duration
                        }
                        .onEnded { _ in
                            appStore?.send(.player(.seek(dragProgress)))
                            isDragging = false
                            
                        }
                )
            }
            .frame(height: 14)
            .onHover { hovering in
                withAnimation(AppAnimation.quick) { isHovering = hovering }
            }

            HStack {
                Text(Formatters.duration(isDragging ? dragProgress : player.progress))
                Spacer()
                Text(Formatters.duration(player.duration))
            }
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var thumbDiameter: CGFloat {
        isDragging ? 13 : (isHovering ? 11 : 9)
    }
}

// MARK: - Mini lyrics (compact now-playing)

/// Three synced lyric lines (previous / current / next) filling the gap
/// between the track meta and the transport controls on compact layouts.
/// Tapping opens the full lyrics page.
struct MiniLyricsView: View {
    let onOpen: () -> Void

    @Environment(\.appStore) private var appStore: StoreOf<AppFeature>?

    private var player: PlayerFeature.State { appStore?.player ?? .init() }

    private var lines: (previous: LyricLine?, current: LyricLine?, next: LyricLine?) {
        guard let lyrics = player.lyrics, !lyrics.isEmpty else { return (nil, nil, nil) }
        guard let index = player.lyricsCursorIndex else {
            return (nil, nil, lyrics.lines.first)
        }
        let all = lyrics.lines
        return (
            index > 0 ? all[index - 1] : nil,
            all[index],
            index + 1 < all.count ? all[index + 1] : nil
        )
    }

    var body: some View {
        let (previous, current, next) = lines
        Group {
            if current != nil || next != nil {
                VStack(spacing: 12) {
                    line(previous, emphasized: false)
                    line(current, emphasized: true)
                    line(next, emphasized: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: current?.id)
            } else {
                Color.clear
            }
        }
    }

    @ViewBuilder
    private func line(_ line: LyricLine?, emphasized: Bool) -> some View {
        Text(line?.text.isEmpty == false ? line!.text : " ")
            .font(.system(size: emphasized ? 17 : 14, weight: emphasized ? .bold : .medium))
            .foregroundStyle(.white.opacity(emphasized ? 1 : 0.45))
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .id(line?.id)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
