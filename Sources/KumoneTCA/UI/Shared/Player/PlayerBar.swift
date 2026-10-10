import ComposableArchitecture
import KumoneCore
import SwiftUI

struct PlayerBar: View {
    let appStore: StoreOf<AppFeature>

    private var player: PlayerFeature.State { appStore.player }

    @ObservedObject private var heroFlight = HeroFlightDirector.shared

    @State private var isBarHovering = false

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 860
            HStack(spacing: 12) {
                songInfoSection(compact: compact)
                    .frame(width: compact ? 180 : 252, alignment: .leading)
                centerSection
                    .frame(maxWidth: .infinity)
                optionsSection(compact: compact)
            }
            .padding(.horizontal, 14)
        }
        .frame(height: Theme.Layout.playerBarHeight)
        .compatGlass(interactive: true, in: Capsule())
        // The Liquid Glass effect layer does not participate in hit testing, so
        // the capsule itself has to claim the area: without this, clicks and
        // hover on the bar's empty stretches fall through to whatever is
        // behind it.
        .contentShape(Capsule())
        .background(
            Capsule()
                .fill(Color.primary.opacity(isBarHovering ? 0.05 : 0))
                .animation(AppAnimation.quick, value: isBarHovering)
        )
        .onHover { isBarHovering = $0 }
        .overlay(Capsule().strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
        // Keep the capsule clear of the window's rounded corners so the inner
        // and outer radii don't visually merge (#88).
        .padding(.horizontal, 20)
        .padding(.bottom, Theme.Layout.playerBarBottomMargin)
        .background(alignment: .bottom) { bottomFade }
    }

    // MARK: - Left: artwork + titles + like

    private func songInfoSection(compact: Bool) -> some View {
        HStack(spacing: 10) {
            artworkButton
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    MarqueeText(
                        text: player.currentTrack?.name ?? String(localized: "未在播放"),
                        isPaused: appStore.isNowPlayingPresented
                            || heroFlight.active[HeroID.nowPlayingTitle] != nil
                    )
                        .frame(height: 17)
                        #if os(macOS)
                        .heroAnchor(HeroID.nowPlayingTitle)
                        // The flying stand-in owns the title for the whole
                        // flight, in both directions.
                        .opacity(heroFlight.active[HeroID.nowPlayingTitle] != nil ? 0 : 1)
                        .animation(nil, value: heroFlight.active[HeroID.nowPlayingTitle] != nil)
                        #endif
                    if player.currentTrack?.fee == 1 {
                        VIPBadge()
                            #if os(macOS)
                            .heroAnchor(HeroID.nowPlayingVIP)
                            .opacity(heroFlight.active[HeroID.nowPlayingVIP] != nil ? 0 : 1)
                            #endif
                    }
                }
                Text(player.currentTrack?.artistNames ?? "miumiu")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    #if os(macOS)
                    .heroAnchor(HeroID.nowPlayingArtist)
                    .opacity(heroFlight.active[HeroID.nowPlayingArtist] != nil ? 0 : 1)
                    #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let track = player.currentTrack {
                LikeButton(trackID: track.id, appStore: appStore)
                #if os(macOS)
                .heroAnchor(HeroID.nowPlayingLike)
                .opacity(heroFlight.active[HeroID.nowPlayingLike] != nil ? 0 : 1)
                #endif
            }
        }
    }

    private var artworkButton: some View {
        Button {
            guard player.hasCurrentTrack else { return }
            for pair in HeroID.nowPlayingPairs {
                HeroProbe.shared.begin(pair.source)
                guard let sourceFrame = HeroFrameStore.shared.frame(for: pair.source) else { continue }
                HeroProbe.shared.recordSource(
                    id: pair.source,
                    frame: sourceFrame,
                    scale: HeroFrameStore.shared.scale(for: pair.source) ?? 1,
                    cornerRadius: pair.source == HeroID.nowPlayingArtwork ? Theme.Radius.small
                        : (pair.source == HeroID.nowPlayingPlayPause ? 15 : 0)
                )
            }
            withAnimation(AppAnimation.smooth) {
                _ = appStore.send(.presentNowPlaying)
            }
        } label: {
            // Keep the hero's URL stable, but do not decode a page-sized bitmap
            // for the 38pt minibar. The flight uses its own page rendition.
            CachedAsyncImage(url: player.currentTrack?.album.picUrl?.resizedImageURL(768), animated: false, rendition: .thumbnail)
                .frame(width: 38, height: 38)
                .heroAnchor(HeroID.nowPlayingArtwork)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                .opacity(heroFlight.active[HeroID.nowPlayingArtwork] != nil ? 0 : 1)
                .animation(nil, value: heroFlight.active[HeroID.nowPlayingArtwork] != nil)
        }
        .buttonStyle(.pressable)
        .noFocusRing()
        .help("打开播放页")
    }

    // MARK: - Center: transport + scrubber

    private var centerSection: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                if player.isFMMode {
                    PlayerIconButton(icon: "trash", size: 12) {
                        appStore.send(.player(.fmTrash))
                    }
                    #if os(macOS)
                    .heroAnchor(HeroID.nowPlayingFMTrash)
                    .opacity(heroFlight.active[HeroID.nowPlayingFMTrash] != nil ? 0 : 1)
                    #endif
                    .help("不喜欢，换一首")
                } else {
                    PlayerIconButton(
                        icon: "shuffle", size: 12,
                        isActive: player.shuffleEnabled
                    ) {
                        appStore.send(.player(.toggleShuffle))
                    }
                    #if os(macOS)
                    .heroAnchor(HeroID.nowPlayingShuffle)
                    .opacity(heroFlight.active[HeroID.nowPlayingShuffle] != nil ? 0 : 1)
                    #endif
                    .help("随机播放")
                }

                PlayerIconButton(icon: "backward.fill", size: 14, disabled: player.isFMMode) {
                    appStore.send(.player(.previous))
                }
                #if os(macOS)
                .heroAnchor(HeroID.nowPlayingPrevious)
                .opacity(heroFlight.active[HeroID.nowPlayingPrevious] != nil ? 0 : 1)
                #endif

                playPauseButton

                PlayerIconButton(icon: "forward.fill", size: 14) {
                    appStore.send(.player(.next))
                }
                #if os(macOS)
                .heroAnchor(HeroID.nowPlayingNext)
                .opacity(heroFlight.active[HeroID.nowPlayingNext] != nil ? 0 : 1)
                #endif

                if player.isFMMode {
                    Image(systemName: "wave.3.right.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 26, height: 26)
                        #if os(macOS)
                        .heroAnchor(HeroID.nowPlayingRoaming)
                        .opacity(heroFlight.active[HeroID.nowPlayingRoaming] != nil ? 0 : 1)
                        #endif
                        .help("私人漫游中")
                } else {
                    PlayerIconButton(
                        icon: player.repeatMode == .one ? "repeat.1" : "repeat", size: 12,
                        isActive: player.repeatMode != .off
                    ) {
                        appStore.send(.player(.cycleRepeatMode))
                    }
                    #if os(macOS)
                    .heroAnchor(HeroID.nowPlayingRepeat)
                    .opacity(heroFlight.active[HeroID.nowPlayingRepeat] != nil ? 0 : 1)
                    #endif
                    .help("循环模式")
                }
            }
            ScrubberLane(appStore: appStore)
        }
        .padding(.vertical, 5)
        .opacity(player.hasCurrentTrack ? 1 : 0.5)
    }

    private var playPauseButton: some View {
        Button {
            appStore.send(.player(.togglePlayPause))
        } label: {
            ZStack {
                Circle()
                    .fill(Theme.accentGradient)
                    .frame(width: 30, height: 30)
                    .shadow(color: Theme.accent.opacity(0.35), radius: 5, y: 1)
                if player.isBuffering && player.isPlaying {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.opacity)
                }
            }
        }
        .buttonStyle(.pressable)
        #if os(macOS)
        .heroAnchor(HeroID.nowPlayingPlayPause)
        .opacity(heroFlight.active[HeroID.nowPlayingPlayPause] != nil ? 0 : 1)
        #endif
        .padding(.horizontal, 2)
    }

    // MARK: - Right: quality / panels / volume

    private func optionsSection(compact: Bool) -> some View {
        HStack(spacing: 4) {
            // Reserve a constant-width slot for the quality tag: it is
            // inserted/removed on every track change (servedQuality is
            // cleared while resolving the next URL), which would otherwise
            // widen/narrow this section and visibly shift the transport.
            if !compact {
                Group {
                    if let level = player.servedQuality,
                       let quality = AudioQuality(rawValue: level) {
                        QualityTag(text: quality.badge)
                    } else if player.unblockSource != nil {
                        QualityTag(text: String(localized: "音源"))
                            .help("来自 \(player.unblockSource ?? "")")
                    } else {
                        // An empty `if let` inside a fixed frame does NOT hold
                        // its width in an HStack (verified: the slot collapses to
                        // 0 and the whole right section jumps the first time a
                        // quality badge appears). Color.clear keeps the 56pt.
                        Color.clear
                    }
                }
                .frame(width: 56, alignment: .leading)
                .padding(.trailing, 2)
            }
            PlayerIconButton(
                icon: "quote.bubble", size: 13,
                isActive: player.activePanel == .lyrics
            ) {
                appStore.send(.player(.togglePanel(.lyrics)))
            }
            .help("歌词")
            .heroAnchor(HeroID.nowPlayingLyrics)
            PlayerIconButton(
                icon: "inset.filled.bottomthird.square", size: 13,
                isActive: appStore.settings.showDesktopLyrics
            ) {
                appStore.send(.settings(.setShowDesktopLyrics(!appStore.settings.showDesktopLyrics)))
            }
            .help("桌面歌词")
            PlayerIconButton(
                icon: "list.bullet", size: 13,
                isActive: player.activePanel == .queue,
                disabled: player.isFMMode
            ) {
                appStore.send(.player(.togglePanel(.queue)))
            }
            .help("播放队列")
            #if os(macOS)
            RoutePickerButton(diameter: 26, glyphSize: 13,
                              tint: .secondary, background: .clear)
                .heroAnchor(HeroID.nowPlayingAirPlay)
            #endif
            VolumeControl(appStore: appStore)
        }
    }

    private var bottomFade: some View {
        LinearGradient(
            colors: [
                Platform.windowBackgroundColor.opacity(0),
                Platform.windowBackgroundColor.opacity(0.25),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: 50)
        .allowsHitTesting(false)
    }
}

// MARK: - Icon button

struct PlayerIconButton: View {
    let icon: String
    var size: CGFloat = 14
    var isActive = false
    var disabled = false
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isActive ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(backgroundColor)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .onHover { isHovering = $0 }
        .animation(AppAnimation.quick, value: isHovering)
    }

    private var backgroundColor: Color {
        let base: Color = colorScheme == .dark ? .white : .black
        if isHovering, !disabled { return base.opacity(0.08) }
        if isActive { return base.opacity(0.05) }
        return .clear
    }
}

// MARK: - Like button

struct LikeButton: View {
    let trackID: Int
    var size: CGFloat = 13
    let appStore: StoreOf<AppFeature>

    var body: some View {
        let liked = appStore.account.isLiked(trackID)
        PlayerIconButton(
            icon: liked ? "heart.fill" : "heart", size: size,
            isActive: liked
        ) {
            appStore.send(.account(.toggleLike(trackID)))
        }
        .help(liked ? String(localized: "取消喜欢") : String(localized: "喜欢"))
    }
}

// MARK: - Scrubber

struct ScrubberLane: View {
    let appStore: StoreOf<AppFeature>

    private var player: PlayerFeature.State { appStore.player }
    @Environment(\.colorScheme) private var colorScheme

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragProgress: Double = 0

    private var fraction: Double {
        guard player.duration > 0 else { return 0 }
        let value = isDragging ? dragProgress : player.progress
        return min(max(value / player.duration, 0), 1)
    }

    var body: some View {
        HStack(spacing: 8) {
            timeLabel(isDragging ? dragProgress : player.progress)
            track
            timeLabel(player.duration)
        }
        .frame(maxWidth: 460)
    }

    private func timeLabel(_ value: TimeInterval) -> some View {
        Text(Formatters.duration(value))
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 34)
    }

    private var track: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.18) : .black.opacity(0.15))
                    .frame(height: 3.5)
                // How much of the stream is already buffered, behind the played
                // position. A network stream keeps this below 1 for the whole
                // track, so it reads as a preload fill, not a stuck bar.
                if player.bufferProgress > 0 {
                    Capsule()
                        .fill(colorScheme == .dark ? Color.white.opacity(0.38) : .black.opacity(0.3))
                        .frame(width: max(3.5, width * player.bufferProgress), height: 3.5)
                }
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(3.5, width * fraction), height: 3.5)
                Circle()
                    .fill(.white)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
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
                        appStore.send(.player(.seek(dragProgress)))
                        isDragging = false
                    }
            )
        }
        .frame(height: 14)
        .onHover { hovering in
            withAnimation(AppAnimation.quick) { isHovering = hovering }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.72), value: isDragging)
    }

    private var thumbDiameter: CGFloat {
        isDragging ? 12 : (isHovering ? 10 : 8)
    }
}

// MARK: - Volume

struct VolumeControl: View {
    let appStore: StoreOf<AppFeature>

    @State private var showPopover = false

    private var volume: Float { appStore.player.volume }

    var body: some View {
        PlayerIconButton(icon: volumeIcon, size: 13) {
            showPopover.toggle()
        }
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            VolumeSlider(appStore: appStore)
                .padding(.vertical, 12)
                .padding(.horizontal, 10)
        }
        .help("音量")
    }

    private var volumeIcon: String {
        switch volume {
        case 0: return "speaker.slash"
        case ..<0.4: return "speaker.wave.1"
        case ..<0.75: return "speaker.wave.2"
        default: return "speaker.wave.3"
        }
    }
}

struct VolumeSlider: View {
    let appStore: StoreOf<AppFeature>

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.18) : .black.opacity(0.15))
                    .frame(width: 4)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 4, height: max(4, height * CGFloat(appStore.player.volume)))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        appStore.send(.player(.setVolume(
                            Float(min(max(1 - value.location.y / height, 0), 1))
                        )))
                    }
            )
        }
        .frame(width: 22, height: 110)
    }
}
