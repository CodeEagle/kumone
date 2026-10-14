import ComposableArchitecture
import KumoneCore
import SwiftUI

struct PlaylistDetailView: View {
    let store: StoreOf<PlaylistDetailFeature>
    let appStore: StoreOf<AppFeature>
    var isLikedList = false
    var recommendationContext: RecommendationContext?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showFullDescription = false

    @State private var hasStartedHeroFlight = false
    /// Drives the page's own arrival fade. The page does **not** fade in on
    /// `onAppear`: a tap armed a card flight whose launch waits for this
    /// page's detail load to place the target, so fading in immediately puts
    /// the frosted background over the feed's cover while the header target
    /// still hides under the flight gate — the cover then pops into an
    /// already-settled page. Instead the fade starts when the stand-in
    /// launches (landing with the spring), or straight away when no arm
    /// exists (sidebar/deep-link arrivals), or when the arm clears without a
    /// flight. A bounded fallback keeps a stalled arm from trapping the page
    /// invisible. Flipping inside a plain `withAnimation` does not animate
    /// here (TCA + Observation state changes carry no transaction); the
    /// implicit `.animation(value:)` below does, so every flip defers one
    /// run loop to let the unfaded frame render first.
    @State private var hasAppeared = false

    #if os(macOS)
    @ObservedObject private var heroFlight = HeroFlightDirector.shared
    @ObservedObject private var heroProbe = HeroProbe.shared
    #endif

    private var heroID: String { HeroID.playlist(store.playlistID) }

    /// The cover flies in first; the rest of the page reveals only after it
    /// lands. The probe's armed id covers the pre-launch push frames the
    /// director's entry cannot (the flight is armed at tap, launched once the
    /// target measures), and the director's entry covers launch-to-land, so
    /// the union spans tap through landing.
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

    private var account: AccountFeature.State { appStore.account }

    private var isOwnPlaylist: Bool {
        store.detail?.creator?.userId == account.profile?.userId
    }

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
                if let detail = store.detail {
                    if isCompact {
                        compactHeader(detail)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    } else {
                        regularHeader(detail)
                            .padding(.horizontal, Theme.Layout.contentInset)
                            .padding(.top, 16)
                    }

                    TrackListView(
                        tracks: store.filteredTracks,
                        privileges: store.privileges,
                        removableFromPlaylistID: isOwnPlaylist ? store.playlistID : nil,
                        onRemoved: { store.send(.trackRemoved($0)) },
                        recommendationContext: recommendationContext,
                        onRecommendationReduced: { rejected, replacement in
                            store.send(.recommendationReduced(rejected: rejected, replacement: replacement))
                        },
                        onPlay: { tracks, startAt in
                            store.send(.delegate(.play(
                                tracks: tracks,
                                source: .playlist(store.playlistID),
                                startAt: startAt,
                                context: .playlist(id: store.playlistID, name: detail.name))))
                        },
                        appStore: appStore
                    )
                    // No isFlying gate: with the push wrapped in
                    // withAnimation (see openDestination), the track list
                    // rides the overlay's own insertion fade and arrives
                    // with the flight instead of waiting for the landing.
                    .padding(.horizontal, isCompact ? 6 : Theme.Layout.contentInset - 10)

                    if store.isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.small)
                            Spacer()
                        }
                        .padding(.vertical, 12)
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
        .navigationTitle(store.detail?.name ?? String(localized: "歌单"))
        // The page sits in an overlay above the root column (see
        // detailStack in MainWindow): a frosted background replaces the
        // opaque system scroll background so the rooted feed behind it and
        // the window's shader read through, and the whole page — this glass
        // included — fades in with the cover's flight (see `hasAppeared`).
        .scrollContentBackground(.hidden)
        // The whole page — frosted background included — fades in from
        // zero. The entry gate (see `hasAppeared`) starts the fade with the
        // cover's flight, so the background never occludes the feed's card
        // while the header target is still gated out; the fade lands with
        // the spring instead. The cover target is hidden by its own
        // heroTarget until the flight ends, so it stays out of this fade.
        .opacity(hasAppeared ? 1 : 0)
        .animation(AppAnimation.smooth, value: hasAppeared)
        .background(.ultraThinMaterial)
        #else
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: store.playlistID) {
            store.send(.onAppear)
        }
        .onAppear {
            KumoneLogger.app.notice("PAGE appear playlist")
            HeroProbe.writeTimed("PAGE appear")
            if !isFlying {
                // Nothing armed: no cover will ever fly, so the page stands
                // on its own.
                DispatchQueue.main.async {
                    withAnimation(AppAnimation.smooth) { hasAppeared = true }
                }
            } else {
                // Armed: wait for the launch (or the disarm/fallback paths)
                // before fading in, so the background arrives with the cover
                // instead of occluding it.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !hasAppeared else { return }
                    KumoneLogger.app.notice("PAGE fade fallback playlist")
            HeroProbe.writeTimed("PAGE fade fallback")
                    withAnimation(AppAnimation.smooth) { hasAppeared = true }
                }
            }
        }
        #if os(macOS)
        .onChange(of: heroFlight.active[heroID] != nil) { _, launched in
            guard launched, !hasAppeared else { return }
            KumoneLogger.app.notice("PAGE fade launch playlist")
            HeroProbe.writeTimed("PAGE fade launch")
            DispatchQueue.main.async {
                withAnimation(AppAnimation.smooth) { hasAppeared = true }
            }
        }
        .onChange(of: heroProbe.armedIDs.contains(heroID)) { _, armed in
            guard !armed, !hasAppeared else { return }
            KumoneLogger.app.notice("PAGE fade disarm playlist")
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
        // The page's text is selectable: the title, creator, stats and
        // description carry playlist details a user may want to copy.
        .textSelection(.enabled)
    }

    // MARK: - Compact (Mobile) Header

    private func compactHeader(_ detail: PlaylistDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                CachedAsyncImage(url: detail.coverImgUrl?.resizedImageURL(384))
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                    .heroTarget(
                        id: heroID,
                        // Same URL the header above displays: the flight's
                    // stand-in — and the return flight launched from this
                    // page — reuses the exact cached bitmap instead of an
                    // uncached placeholder.
                    artworkURL: detail.coverImgUrl?.resizedImageURL(512),
                        cornerRadius: Theme.Radius.standard,
                        hasStarted: $hasStartedHeroFlight
                    )

                VStack(alignment: .leading, spacing: 6) {
                    Text(isLikedList ? String(localized: "我喜欢的音乐") : detail.name)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(3)

                    if let creator = detail.creator, !isLikedList {
                        HStack(spacing: 6) {
                            CachedAsyncImage(url: creator.avatarUrl?.resizedImageURL(48), animated: false)
                                .frame(width: 18, height: 18)
                                .clipShape(Circle())
                            Text(creator.nickname)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Text("\(detail.trackCount) 首 · \(Formatters.playCount(detail.playCount)) 次播放")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let description = detail.description, !description.isEmpty {
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
                        .navigationTitle("歌单简介")
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
                    store.send(.delegate(.play(
                        tracks: store.playableTracks,
                        source: .playlist(store.playlistID),
                        startAt: nil,
                        context: .playlist(id: store.playlistID, name: detail.name))))
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("播放全部 (\(store.playableTracks.count))")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Theme.accentGradient, in: Capsule())
                    .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
                }
                .buttonStyle(.pressable)

                if isLikedList {
                    Button {
                        store.send(.startHeartbeat)
                    } label: {
                        Image(systemName: "heart.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 38, height: 38)
                            .background(.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.pressable)
                } else if !isOwnPlaylist, account.isLoggedIn {
                    Button {
                        store.send(.toggleSubscribe)
                    } label: {
                        Image(systemName: detail.subscribed ? "checkmark" : "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(detail.subscribed ? Theme.accent : .primary)
                            .frame(width: 38, height: 38)
                            .background(.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
    }

    // MARK: - Regular (Desktop / iPad) Header

    private func regularHeader(_ detail: PlaylistDetail) -> some View {
        HStack(alignment: .bottom, spacing: 24) {
            CachedAsyncImage(url: detail.coverImgUrl?.resizedImageURL(512), animated: false)
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                .opacity(isFlying ? 0 : 1)
                .animation(nil, value: isFlying)
                .heroTarget(
                    id: heroID,
                    // Same URL the header above displays: the flight's
                    // stand-in — and the return flight launched from this
                    // page — reuses the exact cached bitmap instead of an
                    // uncached placeholder.
                    artworkURL: detail.coverImgUrl?.resizedImageURL(512),
                    cornerRadius: Theme.Radius.large,
                    hasStarted: $hasStartedHeroFlight
                )

            VStack(alignment: .leading, spacing: 8) {
                Text(isLikedList ? String(localized: "我喜欢的音乐") : String(localized: "歌单"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(detail.name)
                    .font(.title.weight(.bold))
                    .lineLimit(2)

                if let creator = detail.creator {
                    HStack(spacing: 6) {
                        CachedAsyncImage(url: creator.avatarUrl?.resizedImageURL(48), animated: false)
                            .frame(width: 18, height: 18)
                            .clipShape(Circle())
                        Text(creator.nickname)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Text("\(detail.trackCount) 首 · \(Formatters.playCount(detail.playCount)) 次播放 · 更新于 \(Formatters.date(fromMS: detail.updateTime))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)

                if let description = detail.description, !description.isEmpty {
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

                actionRow(detail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // No isFlying gate: see the track list note — this column rides
            // the insertion fade with the rest of the page now that the push
            // is animated.
        }
        .frame(height: 210)
    }

    private func actionRow(_ detail: PlaylistDetail) -> some View {
        HStack(spacing: 10) {
            Button {
                store.send(.delegate(.play(
                    tracks: store.playableTracks,
                    source: .playlist(store.playlistID),
                    startAt: nil,
                    context: .playlist(id: store.playlistID, name: detail.name))))
            } label: {
                Label("播放全部", systemImage: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Theme.accentGradient, in: Capsule())
                    .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
            }
            .buttonStyle(.pressable)

            if isLikedList {
                Button {
                    store.send(.startHeartbeat)
                } label: {
                    Label("心动模式", systemImage: "heart.circle")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.pressable)
            } else if !isOwnPlaylist, account.isLoggedIn {
                Button {
                    store.send(.toggleSubscribe)
                } label: {
                    Label(detail.subscribed ? String(localized: "已收藏") : String(localized: "收藏"),
                          systemImage: detail.subscribed ? "checkmark" : "plus")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.pressable)
            }

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索歌单内歌曲", text: filterBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 130)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.primary.opacity(0.05), in: Capsule())
        }
    }

    private var filterBinding: Binding<String> {
        Binding(get: { store.filter }, set: { store.send(.setFilter($0)) })
    }

    private var loadingHeader: some View {
        HStack(alignment: .top, spacing: isCompact ? 14 : 24) {
            SkeletonView(cornerRadius: isCompact ? Theme.Radius.standard : Theme.Radius.large)
                .frame(width: isCompact ? 120 : 200, height: isCompact ? 120 : 200)

            VStack(alignment: .leading, spacing: 10) {
                SkeletonView(cornerRadius: 4).frame(width: 80, height: 14)
                SkeletonView(cornerRadius: 4).frame(maxWidth: isCompact ? 160 : 220, minHeight: 14, maxHeight: 14)
                SkeletonView(cornerRadius: 4).frame(width: 120, height: 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
        .padding(.top, isCompact ? 12 : 16)
    }
}
