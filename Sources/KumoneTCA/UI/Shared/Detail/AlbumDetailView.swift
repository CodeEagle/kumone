import ComposableArchitecture
import KumoneCore
import SwiftUI

struct AlbumDetailView: View {
    let store: StoreOf<AlbumDetailFeature>
    let appStore: StoreOf<AppFeature>

    @State private var showFullDescription = false
    @State private var hasStartedHeroFlight = false
    /// See PlaylistDetailView: the page's own arrival fade, gated on the
    /// cover's flight launching (not on `onAppear`) so the frosted
    /// background arrives with the cover instead of occluding the feed's
    /// card while the header target is still gated out.
    @State private var hasAppeared = false

    #if os(macOS)
    @ObservedObject private var heroFlight = HeroFlightDirector.shared
    @ObservedObject private var heroProbe = HeroProbe.shared
    #endif

    /// The cover flies in first; the rest of the page reveals only after it
    /// lands (see PlaylistDetailView.isFlying).
    private var isFlying: Bool {
        #if os(macOS)
        // `released` marks a stand-in sitting on the target while its spring
        // settles: the real cover can already take over underneath it, so the
        // gate lets go before the flight fully ends.
        (heroProbe.armedIDs.contains(heroID) || heroFlight.active[heroID] != nil)
            && !heroFlight.released.contains(heroID)
        #else
        false
        #endif
    }
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var heroID: String { HeroID.album(store.albumID) }

    private var account: AccountFeature.State { appStore.account }

    private var isCompact: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: isCompact ? 16 : 20) {
                if let album = store.album {
                    if isCompact {
                        compactHeader(album)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    } else {
                        regularHeader(album)
                            .padding(.horizontal, Theme.Layout.contentInset)
                            .padding(.top, 16)
                    }

                    TrackListView(
                        tracks: store.tracks,
                        style: .albumTrack,
                        onPlay: { tracks, startAt in
                            store.send(.delegate(.play(
                                tracks: tracks,
                                source: .album(store.albumID),
                                startAt: startAt,
                                context: .album(id: store.albumID, name: album.name))))
                        },
                        appStore: appStore
                    )
                    // No isFlying gate: with the push wrapped in
                    // withAnimation (see openDestination), the track list
                    // rides the overlay's own insertion fade and arrives
                    // with the flight instead of waiting for the landing.
                    .padding(.horizontal, isCompact ? 6 : Theme.Layout.contentInset - 10)

                    if !store.otherAlbums.isEmpty {
                        SectionHeader(title: "该歌手的其他专辑")
                            .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
                            .padding(.top, 12)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                                ForEach(store.otherAlbums) { item in
                                    Button {
                                        HeroTrigger.arm(HeroID.album(item.id))
                                        appStore.animateOpen(.album(item.id))
                                    } label: {
                                        CoverCardBody(
                                            coverURL: item.picUrl?.resizedImageURL(384),
                                            title: item.name,
                                            subtitle: Formatters.date(fromMS: item.publishTime),
                                            heroID: HeroID.album(item.id)
                                        )
                                    }
                                    .buttonStyle(.interactiveCard)
                                }
                                Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                            }
                        }
                    }
                } else if case .loading = store.loadState {
                    loadingHeader
                } else if case let .error(message) = store.loadState {
                    ErrorStateView(message: message) {
                        store.send(.reload)
                    }
                    .frame(minHeight: 400)
                }

                PlayerClearanceSpacer()
            }
        }
        #if os(macOS)
        .navigationTitle(store.album?.name ?? String(localized: "专辑"))
        // See PlaylistDetailView: a frosted background over the overlay's
        // transparency, fading in with the rest of the page when the
        // cover's flight launches.
        .scrollContentBackground(.hidden)
        // See PlaylistDetailView: the page fades in from zero, gated on the
        // cover's flight launching, without needing an animation transaction
        // on the TCA send.
        // Background must be inside the opacity gate too; adding it after
        // opacity leaves the material visible while the content is hidden.
        .background(.ultraThinMaterial)
        .opacity(hasAppeared ? 1 : 0)
        .animation(AppAnimation.smooth, value: hasAppeared)
        #else
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: store.albumID) {
            store.send(.onAppear)
        }
        .onAppear {
            KumoneLogger.app.notice("PAGE appear album")
            if !isFlying {
                DispatchQueue.main.async {
                    withAnimation(AppAnimation.smooth) { hasAppeared = true }
                }
            } else {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !hasAppeared else { return }
                    KumoneLogger.app.notice("PAGE fade fallback album")
                    withAnimation(AppAnimation.smooth) { hasAppeared = true }
                }
            }
        }
        #if os(macOS)
        .onChange(of: heroFlight.active[heroID] != nil) { _, launched in
            guard launched, !hasAppeared else { return }
            KumoneLogger.app.notice("PAGE fade launch album")
            DispatchQueue.main.async {
                withAnimation(AppAnimation.smooth) { hasAppeared = true }
            }
        }
        .onChange(of: heroProbe.armedIDs.contains(heroID)) { _, armed in
            guard !armed, !hasAppeared else { return }
            KumoneLogger.app.notice("PAGE fade disarm album")
            DispatchQueue.main.async {
                withAnimation(AppAnimation.smooth) { hasAppeared = true }
            }
        }
        #endif
        #if os(macOS)
        .onChange(of: isFlying) { _, flying in
            // The cover gate flips: pairs with the flight's `DIR release`
            // line so the reveal-vs-fade timing is readable from the file.
            if !flying { HeroProbe.writeTimed("TARGET reveal", heroID) }
        }
        #endif
        .onDisappear {
            hasStartedHeroFlight = false
            HeroFlightDirector.shared.end(id: heroID)
            hasAppeared = false
        }
    }

    // MARK: - Compact Header

    private func compactHeader(_ album: AlbumDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                CachedAsyncImage(url: album.picUrl?.resizedImageURL(384))
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                    .heroTarget(
                        id: heroID,
                        // Same URL the header above displays (see
                    // PlaylistDetailView): the flight's stand-in reuses the
                    // exact cached bitmap instead of an uncached placeholder.
                    artworkURL: album.picUrl?.resizedImageURL(512),
                        cornerRadius: Theme.Radius.standard,
                        hasStarted: $hasStartedHeroFlight
                    )

                VStack(alignment: .leading, spacing: 6) {
                    Text(album.name)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(3)

                    if let artist = album.artist {
                        Button {
                            appStore.animateOpen(.artist(artist.id))
                        } label: {
                            Text(artist.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.accent)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }

                    Text("\(store.tracks.count) 首 · \(Formatters.date(fromMS: album.publishTime))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let description = album.description, !description.isEmpty {
                Button {
                    showFullDescription = true
                } label: {
                    HStack(spacing: 4) {
                        Text(description.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showFullDescription) {
                    NavigationStack {
                        ScrollView {
                            Text(description)
                                .font(.system(size: 14))
                                .padding(20)
                        }
                        .navigationTitle("专辑简介")
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                Button("完成") { showFullDescription = false }
                            }
                        }
                    }
                }
            }

            // Compact Action Bar
            HStack(spacing: 10) {
                Button {
                    store.send(.playAll)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("播放全部 (\(store.tracks.count))")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Theme.accentGradient, in: Capsule())
                    .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
                }
                .buttonStyle(.pressable)

                if account.isLoggedIn {
                    Button {
                        store.send(.toggleSubscribe)
                    } label: {
                        Image(systemName: store.isSubscribed ? "checkmark" : "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(store.isSubscribed ? Theme.accent : .primary)
                            .frame(width: 38, height: 38)
                            .background(.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
    }

    // MARK: - Regular Header

    private func regularHeader(_ album: AlbumDetail) -> some View {
        HStack(alignment: .bottom, spacing: 24) {
            CachedAsyncImage(url: album.picUrl?.resizedImageURL(512), animated: false)
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                .opacity(isFlying ? 0 : 1)
                .animation(nil, value: isFlying)
                .heroTarget(
                    id: heroID,
                    // Same URL the header above displays (see
                    // PlaylistDetailView): the flight's stand-in reuses the
                    // exact cached bitmap instead of an uncached placeholder.
                    artworkURL: album.picUrl?.resizedImageURL(512),
                    cornerRadius: Theme.Radius.large,
                    hasStarted: $hasStartedHeroFlight
                )

            VStack(alignment: .leading, spacing: 8) {
                Text(album.subType?.isEmpty == false ? album.subType! : String(localized: "专辑"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(album.name)
                    .font(.title.weight(.bold))
                    .lineLimit(2)

                if let artist = album.artist {
                    Button {
                        appStore.animateOpen(.artist(artist.id))
                    } label: {
                        Text(artist.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }

                Text("\(store.tracks.count) 首 · \(totalDuration) · \(Formatters.date(fromMS: album.publishTime))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)

                if let description = album.description, !description.isEmpty {
                    Button {
                        showFullDescription = true
                    } label: {
                        Text(description.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showFullDescription, arrowEdge: .bottom) {
                        ScrollView {
                            Text(description)
                                .font(.system(size: 13))
                                .padding(16)
                                .frame(width: 380, alignment: .leading)
                        }
                        .frame(maxHeight: 400)
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 10) {
                    Button {
                        store.send(.playAll)
                    } label: {
                        Label("播放", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Theme.accentGradient, in: Capsule())
                            .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
                    }
                    .buttonStyle(.pressable)

                    if account.isLoggedIn {
                        Button {
                            store.send(.toggleSubscribe)
                        } label: {
                            Label(store.isSubscribed ? String(localized: "已收藏") : String(localized: "收藏"),
                                  systemImage: store.isSubscribed ? "checkmark" : "plus")
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.primary.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // No isFlying gate: see the track list note — this column rides
            // the insertion fade with the rest of the page now that the push
            // is animated.
        }
        .frame(height: 210)
    }

    private var totalDuration: String {
        let totalMS = store.tracks.reduce(into: 0) { $0 += $1.durationMS }
        return Formatters.longDuration(TimeInterval(totalMS) / 1000)
    }

    private var loadingHeader: some View {
        HStack(alignment: .top, spacing: isCompact ? 14 : 24) {
            SkeletonView(cornerRadius: isCompact ? Theme.Radius.standard : Theme.Radius.large)
                .frame(width: isCompact ? 120 : 200, height: isCompact ? 120 : 200)

            VStack(alignment: .leading, spacing: 10) {
                SkeletonView(cornerRadius: 4).frame(width: 80, height: 14)
                SkeletonView(cornerRadius: 4).frame(maxWidth: isCompact ? 160 : 200, minHeight: 14, maxHeight: 14)
                SkeletonView(cornerRadius: 4).frame(width: 120, height: 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
        .padding(.top, isCompact ? 12 : 16)
    }
}
