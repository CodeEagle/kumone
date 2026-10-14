// CarPlayConnector.swift — CarPlay lifecycle + template assembly + tap bridging.
// The single public type in KumoneCore, forwarded to by the app target's CarPlaySceneDelegate.

#if os(iOS)
import CarPlay
import ComposableArchitecture
import KumoneCore
import UIKit

/// Owns the CarPlay connection lifecycle, the template hierarchy, and data loading.
/// It's a singleton — activated when a CarPlay scene connects, cleaned up when it disconnects.
///
/// Reads and mutates the process-wide `IOSAppStore` so the main window and
/// CarPlay stay in sync over one source of truth. There is no per-scene state:
/// every tap is a `store.send`, and every rendered value comes from the store.
@MainActor
public final class CarPlayConnector: NSObject {

    public static let shared = CarPlayConnector()

    // MARK: - State

    private weak var interfaceController: CPInterfaceController?
    private var tabBar: CPTabBarTemplate?
    private var recommendTab: CPListTemplate?
    private var curatedTab: CPListTemplate?
    private var fmTab: CPListTemplate?
    private var libraryTab: CPListTemplate?

    private var content = CarPlayContentStore()
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0

    /// The store values the templates render, snapshotted so a change can be
    /// diffed into the smallest possible refresh.
    private var snapshot = StoreSnapshot()

    // MARK: - Now Playing buttons
    // like / dislike are created once in didConnect and cached, because their visual state is
    // driven by mutable properties (isSelected / isEnabled). shuffle and repeat instead carry
    // their state in the button *image*, and CPNowPlayingImageButton's image is immutable, so
    // those two are rebuilt from scratch on every refresh.
    private var likeButton: CPNowPlayingAddToLibraryButton?
    private var dislikeButton: CPNowPlayingImageButton?

    private var store: StoreOf<AppFeature> { IOSAppStore.store }

    override init() {
        super.init()
    }

    // MARK: - Lifecycle

    /// Called when the CarPlay scene connects. Builds the root template and kicks off data loading.
    public func didConnect(interfaceController: CPInterfaceController, window: CPWindow) {
        self.interfaceController = interfaceController

        // Bootstraps the shared store (idempotent — the main window may already
        // have done it): settings, account, updater and the media-command
        // listener all come alive here.
        store.send(.onAppear)

        // Configure the Now Playing buttons (persistent — live for the singleton's lifetime).
        configureNowPlayingButtons()

        // Build and install the root template.
        let root = makeRootTemplate()
        tabBar = root
        interfaceController.setRootTemplate(root, animated: true, completion: nil)

        snapshot = makeSnapshot()
        observeStore()

        // On a warm connect (the app was already running) the account is known,
        // so load straight into the final state. A cold start waits for the
        // store's bootstrap to land — `refreshFromStore` fires the reload then.
        if store.account.isBootstrapped {
            scheduleFullReload()
        }
    }

    /// Called when the CarPlay scene disconnects. Clears template references but doesn't stop playback.
    public func didDisconnect() {
        CPNowPlayingTemplate.shared.remove(self)
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        interfaceController = nil
        tabBar = nil
        recommendTab = nil
        curatedTab = nil
        fmTab = nil
        libraryTab = nil
    }

    // MARK: - Store observation

    /// A flat, equatable view of the store state the templates render. Diffing
    /// it keeps a `progress` tick or a lyrics fetch from rebuilding buttons.
    private struct StoreSnapshot: Equatable {
        var isLoggedIn = false
        var isBootstrapped = false
        var profileID: Int? = nil
        var userPlaylistIDs: [Int] = []
        var isFMMode = false
        var isPlaying = false
        var shuffleEnabled = false
        var repeatMode = RepeatMode.off
        var currentTrackID: Int? = nil
        var likedTrackIDs: Set<Int> = []
    }

    private func makeSnapshot() -> StoreSnapshot {
        let account = store.account
        let player = store.player
        return StoreSnapshot(
            isLoggedIn: account.isLoggedIn,
            isBootstrapped: account.isBootstrapped,
            profileID: account.profile?.userId,
            userPlaylistIDs: account.userPlaylists.map(\.id),
            isFMMode: player.isFMMode,
            isPlaying: player.isPlaying,
            shuffleEnabled: player.shuffleEnabled,
            repeatMode: player.repeatMode,
            currentTrackID: player.currentTrack?.id,
            likedTrackIDs: account.likedTrackIDs
        )
    }

    /// Tracks the store values the templates depend on. `withPerceptionTracking`
    /// calls back exactly once, so the handler re-registers to keep watching.
    private func observeStore() {
        withPerceptionTracking {
            _ = store.account.isLoggedIn
            _ = store.account.isBootstrapped
            _ = store.account.profile?.userId
            _ = store.account.userPlaylists.map(\.id)
            _ = store.account.likedTrackIDs
            _ = store.player.isFMMode
            _ = store.player.isPlaying
            _ = store.player.shuffleEnabled
            _ = store.player.repeatMode
            _ = store.player.currentTrack?.id
        } onChange: { [weak self] in
            // The callback fires during willSet, so the read is deferred to the
            // next main-actor turn, after the new state is committed.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshFromStore()
                self.observeStore()
            }
        }
    }

    /// Diffs the store against the last rendered state and refreshes only what moved.
    private func refreshFromStore() {
        let next = makeSnapshot()
        defer { snapshot = next }

        // Login / logout / account switch / first bootstrap: rebuild every tab
        // from scratch so an older account's data can't clobber a newer one's.
        if next.isLoggedIn != snapshot.isLoggedIn
            || next.profileID != snapshot.profileID
            || next.isBootstrapped != snapshot.isBootstrapped
        {
            rebuildAllTabs()
            refreshNowPlayingButtons()
            updateFMTab()
            updateLibraryTab()
            return
        }

        if next.userPlaylistIDs != snapshot.userPlaylistIDs {
            updateLibraryTab()
        }

        if next.isFMMode != snapshot.isFMMode || next.isPlaying != snapshot.isPlaying {
            refreshNowPlayingButtons()
            updateFMTab()
        } else if next.shuffleEnabled != snapshot.shuffleEnabled
                    || next.repeatMode != snapshot.repeatMode
        {
            refreshNowPlayingButtons()
        }

        if next.currentTrackID != snapshot.currentTrackID
            || next.likedTrackIDs != snapshot.likedTrackIDs
        {
            syncLikeButton()
        }
    }

    // MARK: - Root template

    /// Builds the CPTabBarTemplate (Recommend / Curated / Roaming / Library) — mirrors the App's IOSTab layout 1:1.
    private func makeRootTemplate() -> CPTabBarTemplate {
        let recommend = CPListTemplate(title: String(localized: "推荐"), sections: [])
        recommend.tabImage = UIImage(systemName: "house")
        recommend.emptyViewTitleVariants = [String(localized: "正在加载推荐…")]

        let curated = CPListTemplate(title: String(localized: "精选"), sections: [])
        curated.tabImage = UIImage(systemName: "square.grid.2x2")
        curated.emptyViewTitleVariants = [String(localized: "正在加载精选…")]

        let fm = CPListTemplate(title: String(localized: "漫游"), sections: [])
        fm.tabImage = UIImage(systemName: "dot.radiowaves.left.and.right")
        fm.emptyViewTitleVariants = [String(localized: "请先登录网易云音乐")]

        let library = CPListTemplate(title: String(localized: "我的"), sections: [])
        library.tabImage = UIImage(systemName: "person.crop.circle")
        library.emptyViewTitleVariants = [String(localized: "请先登录网易云音乐")]

        self.recommendTab = recommend
        self.curatedTab = curated
        self.fmTab = fm
        self.libraryTab = library

        // CPNowPlayingTemplate is auto-presented by CarPlay whenever audio plays; it can't be added as a CPTabBarTemplate tab.
        return CPTabBarTemplate(templates: [recommend, curated, fm, library])
    }

    // MARK: - Now Playing button configuration

    /// Creates and caches the like / dislike buttons in didConnect, wires up the queue and
    /// album-artist controls, then installs the button row on CPNowPlayingTemplate.
    /// - like (CPNowPlayingAddToLibraryButton): always shown, mirrors the App's global LikeButton.
    /// - dislike (CPNowPlayingImageButton): only shown while in FM mode, mirroring the trash button in the App's FMView.
    /// - shuffle / repeat: only shown outside FM mode, where the queue is fixed and reorderable.
    ///   FM has no queue to shuffle or loop, so showing them there would be dead controls.
    private func configureNowPlayingButtons() {
        let nowPlaying = CPNowPlayingTemplate.shared

        // Up Next: CarPlay leaves this button dead unless the app both enables it and pushes its
        // own template from the observer callback below.
        nowPlaying.isUpNextButtonEnabled = true
        nowPlaying.upNextTitle = String(localized: "播放队列")
        nowPlaying.isAlbumArtistButtonEnabled = true
        nowPlaying.add(self)

        // "Like" button — uses the system's "add to library" styled button.
        let like = CPNowPlayingAddToLibraryButton(handler: { [weak self] _ in
            guard let self,
                  let trackID = self.store.player.currentTrack?.id else { return }
            self.store.send(.account(.toggleLike(trackID)))
        })
        like.isEnabled = true
        like.isSelected = store.player.currentTrack.map { store.account.isLiked($0.id) } ?? false
        self.likeButton = like

        // "Dislike" button — custom SF Symbol icon, only shown and enabled while FM mode is on.
        let dislike = CPNowPlayingImageButton(
            image: UIImage(systemName: "hand.thumbsdown.fill")!,
            handler: { [weak self] _ in self?.store.send(.player(.fmTrash)) }
        )
        dislike.isEnabled = store.player.isFMMode
        self.dislikeButton = dislike

        refreshNowPlayingButtons()
    }

    /// Recomputes the whole Now Playing button row from current player state.
    private func refreshNowPlayingButtons() {
        guard let likeButton, let dislikeButton else { return }
        let player = store.player
        let isFMMode = player.isFMMode

        dislikeButton.isEnabled = isFMMode

        var buttons: [CPNowPlayingButton] = [likeButton]
        if isFMMode {
            buttons.append(dislikeButton)
        } else {
            buttons.append(makeShuffleButton(enabled: player.shuffleEnabled))
            buttons.append(makeRepeatButton(mode: player.repeatMode))
        }

        CPNowPlayingTemplate.shared.updateNowPlayingButtons(buttons)
    }

    /// Keeps the cached like button's selected state in sync with the store.
    private func syncLikeButton() {
        likeButton?.isSelected = store.player.currentTrack
            .map { store.account.isLiked($0.id) } ?? false
    }

    /// A tinted `shuffle` glyph — red when shuffle is on, muted when off.
    /// The tint has to be baked into the image (`.alwaysOriginal`) because
    /// CPNowPlayingImageButton exposes no selected/tint state of its own.
    private func makeShuffleButton(enabled: Bool) -> CPNowPlayingImageButton {
        let image = nowPlayingGlyph("shuffle", active: enabled)
        return CPNowPlayingImageButton(image: image) { [weak self] _ in
            self?.store.send(.player(.toggleShuffle))
        }
    }

    /// A tinted `repeat` / `repeat.1` glyph tracking the three-state repeat mode.
    private func makeRepeatButton(mode: RepeatMode) -> CPNowPlayingImageButton {
        let symbol = mode == .one ? "repeat.1" : "repeat"
        let image = nowPlayingGlyph(symbol, active: mode != .off)
        return CPNowPlayingImageButton(image: image) { [weak self] _ in
            self?.store.send(.player(.cycleRepeatMode))
        }
    }

    private func nowPlayingGlyph(_ systemName: String, active: Bool) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: active ? .bold : .regular)
        let tint: UIColor = active ? .systemRed : .secondaryLabel
        return UIImage(systemName: systemName, withConfiguration: config)?
            .withTintColor(tint, renderingMode: .alwaysOriginal)
            ?? UIImage()
    }

    // MARK: - Now Playing navigation

    /// Pushes the live playback queue when the driver taps the Up Next button.
    private func showQueue() {
        let player = store.player
        let template = CarPlayTemplateFactory.queueTemplate(
            current: player.currentTrack,
            upcoming: player.upcomingTracks,
            onCurrentTap: { [weak self] in
                self?.interfaceController?.popTemplate(animated: true, completion: nil)
            },
            onTrackTap: { [weak self] track in
                self?.store.send(.player(.jumpTo(track)))
                self?.interfaceController?.popTemplate(animated: true, completion: nil)
            }
        )
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    /// Opens the current track's album, falling back to its first artist when the track carries no
    /// album (cloud-disk uploads and some FM tracks decode with `album.id == 0`).
    private func showAlbumOrArtistOfCurrentTrack() {
        guard let track = store.player.currentTrack else { return }

        if track.album.id > 0 {
            pushTracks(
                title: track.album.name,
                load: { try? await NeteaseAPI.album(id: track.album.id).songs },
                context: .album(id: track.album.id, name: track.album.name),
                source: .album(track.album.id)
            )
        } else if let artist = track.artists.first, artist.id > 0 {
            pushTracks(
                title: artist.name,
                load: { try? await NeteaseAPI.artist(id: artist.id).hotSongs },
                context: .artist(id: artist.id, name: artist.name),
                source: .artist(artist.id)
            )
        }
    }

    // MARK: - Data loading

    /// The Recommend tab's section order matches `HomeView.loadedBody` 1:1.
    private static let homeToplistWhitelist: Set<Int> = [
        19_723_756, 3_779_629, 2_884_035, 3_778_678, 60_198
    ]

    /// Loads all four tabs' data into an independent snapshot in parallel.
    /// The last three fetchers are guarded by `loggedIn` so logged-out callers don't hit a guaranteed 401.
    private func loadAllTabs(into content: CarPlayContentStore, loggedIn: Bool, uid: Int?) async {
        async let r: Void = content.fetchRecommendPlaylists(loggedIn: loggedIn)
        async let c: Void = content.fetchCuratedPlaylists()
        async let o: Void = content.fetchOfficialPlaylists()
        async let ch: Void = content.fetchChinesePlaylists()
        async let t: Void = content.fetchToplists()
        async let d: Void = content.fetchDailyTracks(loggedIn: loggedIn)
        async let e: Void = content.fetchRecentsTracks(uid: uid, loggedIn: loggedIn)
        async let l: Void = content.fetchCloudTracks(loggedIn: loggedIn)
        async let rd: Void = content.fetchRadarPlaylists(loggedIn: loggedIn)
        async let al: Void = content.fetchNewAlbums()
        async let ar: Void = content.fetchTopArtists()

        _ = await (r, c, o, ch, t, d, e, l, rd, al, ar)
    }

    /// Only the latest batch of requests is allowed to commit, so cold-start or account-switch races can't let an older account's data clobber a newer one.
    private func scheduleFullReload() {
        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled,
                  generation == loadGeneration,
                  interfaceController != nil else { return }

            let account = store.account
            let nextContent = CarPlayContentStore()
            let loggedIn = account.isLoggedIn
            let uid = account.profile?.userId
            await loadAllTabs(into: nextContent, loggedIn: loggedIn, uid: uid)
            guard !Task.isCancelled,
                  generation == loadGeneration,
                  interfaceController != nil else { return }

            content = nextContent
            updateRecommendTab()
            updateCuratedTab()
            updateFMTab()
            updateLibraryTab()
        }
    }

    /// Refreshes the Recommend tab's sections, matching `App HomeView.loadedBody` exactly:
    /// 1. Today's picks (feature cards: Daily / Personal FM / Heartbeat) — login-only
    /// 2. Recommended playlists
    /// 3. Radar playlists — login-only
    /// 4. Toplists (5 fixed IDs, same as the App)
    /// 5. New albums
    /// 6. Recommended artists
    private func updateRecommendTab() {
        guard let recommendTab else { return }
        var sections: [CPListSection] = []
        let loggedIn = store.account.isLoggedIn

        // 1. Today's picks — feature cards
        if loggedIn {
            sections.append(contentsOf: CarPlayTemplateFactory.recommendFeatureSections(
                onTap: { [weak self] feature in self?.handleRecommendFeatureTap(feature) }
            ))
        }

        // 2. Recommended playlists
        sections.append(contentsOf: CarPlayTemplateFactory.playlistSections(
            content.recommendPlaylists,
            onPlaylistTap: { [weak self] playlist in
                self?.pushPlaylistDetail(playlist)
            }
        ))

        // 3. Radar playlists — login-only
        if loggedIn, !content.radarPlaylists.isEmpty {
            sections.append(contentsOf: CarPlayTemplateFactory.radarPlaylistSections(
                content.radarPlaylists,
                onTap: { [weak self] radar in self?.pushRadarPlaylist(radar) }
            ))
        }

        // 4. Toplists (5 entries, filtered with the same whitelist App HomeView uses).
        let homeToplists = content.toplists.filter {
            Self.homeToplistWhitelist.contains($0.id)
        }
        if !homeToplists.isEmpty {
            let toplistItems = homeToplists.map { toplist -> CPListItem in
                let item = CPListItem(text: toplist.name, detailText: toplist.updateFrequency)
                item.accessoryType = .none
                item.handler = { [weak self] _, completion in
                    self?.pushToplistDetail(toplist)
                    completion()
                }
                CarPlayTemplateFactory.fillArtwork(item, from: toplist.coverImgUrl)
                return item
            }
            sections.append(CPListSection(items: toplistItems, header: String(localized: "排行榜"), sectionIndexTitle: nil))
        }

        // 5. New albums
        if !content.newAlbums.isEmpty {
            sections.append(contentsOf: CarPlayTemplateFactory.newAlbumSections(
                content.newAlbums,
                onTap: { [weak self] album in self?.pushAlbum(album) }
            ))
        }

        // 6. Recommended artists
        if !content.topArtists.isEmpty {
            sections.append(contentsOf: CarPlayTemplateFactory.topArtistSections(
                content.topArtists,
                onTap: { [weak self] artist in self?.pushArtist(artist) }
            ))
        }

        recommendTab.updateSections(sections)
        if sections.isEmpty {
            recommendTab.emptyViewTitleVariants = [String(localized: "暂无推荐歌单")]
        }
    }

    /// Tap handler for the Recommend tab's top feature rows:
    /// - Daily → push the tracks list (reuses the Library tab's .daily entry)
    /// - Personal FM → start FM
    /// - Heartbeat → the shared store owns the seed + fetch (same action as HomeView)
    private func handleRecommendFeatureTap(_ feature: CarPlayRecommendFeature) {
        switch feature {
        case .daily:
            pushLibraryEntry(.daily, liked: nil)
        case .fm:
            store.send(.player(.startFM))
        case .heartbeat:
            store.send(.startHeartbeat)
        }
    }

    /// Refreshes the Curated tab's sections: high-quality + hot + toplists + official + Chinese playlists.
    /// Mirrors the category chips in App ExploreView (All / Featured / Toplists / Official / Chinese).
    private func updateCuratedTab() {
        guard let curatedTab else { return }
        var sections = CarPlayTemplateFactory.playlistSections(
            content.highQualityPlaylists,
            onPlaylistTap: { [weak self] playlist in
                self?.pushPlaylistDetail(playlist)
            }
        )
        if !content.hotPlaylists.isEmpty {
            let hotItems = content.hotPlaylists.map { playlist -> CPListItem in
                let item = CPListItem(text: playlist.name, detailText: nil)
                item.accessoryType = .none
                item.handler = { [weak self] _, completion in
                    self?.pushPlaylistDetail(playlist)
                    completion()
                }
                CarPlayTemplateFactory.fillArtwork(item, from: playlist.coverURL)
                return item
            }
            sections.append(CPListSection(items: hotItems, header: String(localized: "热门歌单"), sectionIndexTitle: nil))
        }
        // Toplists get their own section below.
        if !content.toplists.isEmpty {
            let toplistItems = content.toplists.map { toplist -> CPListItem in
                let item = CPListItem(text: toplist.name, detailText: toplist.updateFrequency)
                item.accessoryType = .none
                item.handler = { [weak self] _, completion in
                    self?.pushToplistDetail(toplist)
                    completion()
                }
                CarPlayTemplateFactory.fillArtwork(item, from: toplist.coverImgUrl)
                return item
            }
            sections.append(CPListSection(items: toplistItems, header: String(localized: "排行榜"), sectionIndexTitle: nil))
        }
        // Official playlists — backs the "Official" chip in App ExploreView.
        if !content.officialPlaylists.isEmpty {
            sections.append(contentsOf: CarPlayTemplateFactory.playlistSections(
                content.officialPlaylists,
                onPlaylistTap: { [weak self] playlist in self?.pushPlaylistDetail(playlist) },
                header: String(localized: "官方歌单")
            ))
        }
        // Chinese playlists — backs the "Chinese" chip in App ExploreView.
        if !content.chinesePlaylists.isEmpty {
            sections.append(contentsOf: CarPlayTemplateFactory.playlistSections(
                content.chinesePlaylists,
                onPlaylistTap: { [weak self] playlist in self?.pushPlaylistDetail(playlist) },
                header: String(localized: "华语歌单")
            ))
        }
        curatedTab.updateSections(sections)
        if content.highQualityPlaylists.isEmpty, content.hotPlaylists.isEmpty, content.toplists.isEmpty,
           content.officialPlaylists.isEmpty, content.chinesePlaylists.isEmpty {
            curatedTab.emptyViewTitleVariants = [String(localized: "暂无精选歌单")]
        }
    }

    /// Refreshes the Roaming tab on CarPlay. Logged-in users get the FM template
    /// with the currently playing track row plus the action button (Start Roaming /
    /// Next / Resume Roaming). Logged-out users see an empty view prompting them
    /// to sign in to NetEase Music first.
    private func updateFMTab() {
        guard let fmTab else { return }
        let loggedIn = store.account.isLoggedIn
        if !loggedIn {
            fmTab.updateSections([])
            fmTab.emptyViewTitleVariants = [String(localized: "请先登录网易云音乐")]
            return
        }
        let player = store.player
        let sections = CarPlayTemplateFactory.fmSection(
            isFMMode: player.isFMMode,
            isPlaying: player.isPlaying,
            currentTrack: player.currentTrack,
            onActionTap: { [weak self] in self?.handleFMTap() }
        )
        fmTab.updateSections(sections)
        fmTab.emptyViewTitleVariants = [String(localized: "正在加载…")]
    }

    /// What happens when the driver taps the FM tab's action button, depending
    /// on what the player is doing right now:
    /// - FM mode is off entirely → fire `startFM` to begin a fresh roaming
    ///   session (fetches recommendations from NetEase and starts playing).
    /// - FM mode is on and we're playing → skip ahead via `fmNext`. We
    ///   intentionally don't reuse `next` here because FM doesn't use the
    ///   normal queue — its tracks are pulled one batch at a time from
    ///   NetEase's recommendation API, and CPNowPlayingTemplate's built-in
    ///   "next" button doesn't know about that semantics. Putting the skip
    ///   right on the FM tab keeps the driver's intent obvious.
    /// - FM mode is on but we're paused → just resume with `togglePlayPause`.
    ///   Using `startFM` here would wipe the FM queue and start a brand-new
    ///   session, which is definitely not what the driver wants when they
    ///   just hit pause and are tapping to come back.
    private func handleFMTap() {
        let player = store.player
        if !player.isFMMode {
            store.send(.player(.startFM))
        } else if player.isPlaying {
            store.send(.player(.fmNext))
        } else {
            store.send(.player(.togglePlayPause))
        }
    }

    /// Refreshes the Library tab: pulls the account's playlists from the store and renders 3 sections.
    private func updateLibraryTab() {
        guard let libraryTab else { return }
        let account = store.account
        guard account.isLoggedIn else {
            libraryTab.updateSections([])
            libraryTab.emptyViewTitleVariants = [String(localized: "请先登录网易云音乐")]
            return
        }
        let model = CarPlayLibraryModel(
            liked: account.likedSongsPlaylist,
            created: Array(account.createdPlaylists.prefix(20)),
            subscribed: Array(account.subscribedPlaylists.prefix(20)),
            isLoggedIn: true
        )
        let sections = CarPlayTemplateFactory.librarySections(
            library: model,
            onEntryTap: { [weak self] entry in self?.pushLibraryEntry(entry, liked: model.liked) },
            onPlaylistTap: { [weak self] playlist in self?.pushPlaylistDetail(playlist) }
        )
        libraryTab.updateSections(sections)
        libraryTab.emptyViewTitleVariants = [String(localized: "暂无内容")]
    }

    /// Tap handler for the four Library entries: pushes the tracks-list template, then renders it once tracks load.
    private func pushLibraryEntry(_ entry: CarPlayLibraryEntry, liked: PlaylistSummary?) {
        let loading = CPListTemplate(title: entry.title, sections: [])
        loading.emptyViewTitleVariants = [String(localized: "正在加载…")]

        interfaceController?.pushTemplate(loading, animated: true) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                let tracks = await self.fetchTracks(for: entry, liked: liked)
                guard !tracks.isEmpty else {
                    loading.updateSections([])
                    loading.emptyViewTitleVariants = [String(localized: "暂无曲目")]
                    return
                }
                let detail = CarPlayTemplateFactory.trackListTemplate(
                    title: entry.title,
                    trackCount: tracks.count,
                    tracks: tracks,
                    onPlayAll: { [weak self] in self?.handlePlayAll(entry: entry, liked: liked) },
                    onTrackTap: { [weak self] track, allTracks in self?.handleTrackTap(entry: entry, track: track, allTracks: allTracks, liked: liked) }
                )
                loading.updateSections(detail.sections)
            }
        }
    }

    /// Fetches tracks for a given Library entry. An empty array means "no tracks" or "not logged in".
    private func fetchTracks(for entry: CarPlayLibraryEntry, liked: PlaylistSummary?) async -> [Track] {
        switch entry {
        case .liked:
            guard let liked else { return [] }
            return await content.fetchPlaylistTracks(id: liked.id, name: liked.name)
        case .daily:
            await content.fetchDailyTracks(loggedIn: store.account.isLoggedIn)
            return content.dailyTracks
        case .recents:
            await content.fetchRecentsTracks(
                uid: store.account.profile?.userId,
                loggedIn: store.account.isLoggedIn
            )
            return content.recentsTracks
        case .cloud:
            await content.fetchCloudTracks(loggedIn: store.account.isLoggedIn)
            return content.cloudTracks
        }
    }

    /// "Play all" handler: routes through `playContext` so the shared store drives
    /// its full resolve + load flow.
    private func handlePlayAll(entry: CarPlayLibraryEntry, liked: PlaylistSummary?) {
        switch entry {
        case .liked:
            guard let liked else { return }
            store.send(.player(.playContext(.playlist(id: liked.id, name: liked.name))))
        case .daily:
            store.send(.player(.playContext(.daily)))
        case .recents:
            store.send(.player(.playContext(.recents)))
        case .cloud:
            store.send(.player(.playContext(.cloud)))
        }
    }

    /// Single-track tap handler: passes the full queue so next/prev stay useful.
    private func handleTrackTap(entry: CarPlayLibraryEntry, track: Track, allTracks: [Track], liked: PlaylistSummary?) {
        switch entry {
        case .liked:
            guard let liked else { return }
            store.send(.player(.play(
                tracks: allTracks,
                source: .playlist(liked.id),
                startAt: track,
                context: .playlist(id: liked.id, name: liked.name)
            )))
        case .daily:
            store.send(.player(.play(
                tracks: allTracks,
                source: .daily,
                startAt: track,
                context: .daily
            )))
        case .recents:
            store.send(.player(.play(
                tracks: allTracks,
                source: .none,
                startAt: track,
                context: .recents
            )))
        case .cloud:
            store.send(.player(.play(
                tracks: allTracks,
                source: .cloud,
                startAt: track,
                context: .cloud
            )))
        }
    }

    // MARK: - Radar / album / artist detail

    /// Recommend tab radar tap: `radar.id` is itself a playlist id, so it goes straight through `fetchPlaylistTracks`.
    private func pushRadarPlaylist(_ radar: CarPlayRadarPlaylist) {
        pushTracks(
            title: radar.title,
            load: { [weak self] in
                guard let self else { return nil }
                return await self.content.fetchPlaylistTracks(id: radar.id, name: radar.title)
            },
            context: .playlist(id: radar.id, name: radar.title),
            source: .playlist(radar.id)
        )
    }

    /// Recommend tab album tap: fetch album details, play the whole album or one song.
    private func pushAlbum(_ album: AlbumSummary) {
        pushTracks(
            title: album.name,
            load: {
                try? await NeteaseAPI.album(id: album.id).songs
            },
            context: .album(id: album.id, name: album.name),
            source: .album(album.id)
        )
    }

    /// Recommend tab artist tap: fetch the artist's hot tracks.
    private func pushArtist(_ artist: ArtistSummary) {
        pushTracks(
            title: artist.name,
            load: {
                try? await NeteaseAPI.artist(id: artist.id).hotSongs
            },
            context: .artist(id: artist.id, name: artist.name),
            source: .artist(artist.id)
        )
    }

    /// Generic "push tracks" helper: shows an empty template first, then fills it with `trackListTemplate` once tracks load.
    private func pushTracks(
        title: String,
        load: @escaping () async -> [Track]?,
        context: PlayContext,
        source: PlaySource
    ) {
        let loading = CPListTemplate(title: title, sections: [])
        loading.emptyViewTitleVariants = [String(localized: "正在加载…")]

        interfaceController?.pushTemplate(loading, animated: true) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                guard let tracks = await load(), !tracks.isEmpty else {
                    loading.updateSections([])
                    loading.emptyViewTitleVariants = [String(localized: "暂无曲目")]
                    return
                }
                let detail = CarPlayTemplateFactory.trackListTemplate(
                    title: title,
                    trackCount: tracks.count,
                    tracks: tracks,
                    onPlayAll: { [weak self] in
                        self?.store.send(.player(.playContext(context)))
                    },
                    onTrackTap: { [weak self] track, allTracks in
                        self?.store.send(.player(.play(
                            tracks: allTracks, source: source, startAt: track, context: context
                        )))
                    }
                )
                loading.updateSections(detail.sections)
            }
        }
    }

    // MARK: - Playlist detail

    /// Pushes the playlist detail template: empty template with title first, then populated once tracks load.
    private func pushPlaylistDetail(_ playlist: PlaylistSummary) {
        let loading = CPListTemplate(title: playlist.name, sections: [])
        loading.emptyViewTitleVariants = [String(localized: "正在加载…")]

        interfaceController?.pushTemplate(loading, animated: true) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                let tracks = await self.content.fetchPlaylistTracks(
                    id: playlist.id, name: playlist.name
                )
                let detail = CarPlayTemplateFactory.playlistDetailTemplate(
                    playlist: playlist,
                    tracks: tracks,
                    onPlayAll: {
                        // Play all: route through playContext so we reuse the full load + play pipeline.
                        self.store.send(.player(.playContext(.playlist(id: playlist.id, name: playlist.name))))
                    },
                    onTrackTap: { track, allTracks in
                        // Single track tap: hand over the entire queue so next/prev still work.
                        self.store.send(.player(.play(
                            tracks: allTracks,
                            source: .playlist(playlist.id),
                            startAt: track,
                            context: .playlist(id: playlist.id, name: playlist.name)
                        )))
                    }
                )
                loading.updateSections(detail.sections)
            }
        }
    }

    /// Pushes the toplist detail template (toplists are just playlists under the hood).
    private func pushToplistDetail(_ toplist: ToplistItem) {
        let loading = CPListTemplate(title: toplist.name, sections: [])
        loading.emptyViewTitleVariants = [String(localized: "正在加载…")]

        interfaceController?.pushTemplate(loading, animated: true) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                // A toplist's id is just its playlist id.
                let tracks = await self.content.fetchPlaylistTracks(
                    id: toplist.id, name: toplist.name
                )
                let detail = CarPlayTemplateFactory.toplistDetailTemplate(
                    toplist: toplist,
                    tracks: tracks,
                    onPlayAll: {
                        self.store.send(.player(.playContext(.playlist(id: toplist.id, name: toplist.name))))
                    },
                    onTrackTap: { track, allTracks in
                        self.store.send(.player(.play(
                            tracks: allTracks,
                            source: .playlist(toplist.id),
                            startAt: track,
                            context: .playlist(id: toplist.id, name: toplist.name)
                        )))
                    }
                )
                loading.updateSections(detail.sections)
            }
        }
    }

    // MARK: - Login-state rebuild

    /// When the account changes, rebuild all tab data (forces a full cache refresh).
    private func rebuildAllTabs() {
        scheduleFullReload()
    }
}

// MARK: - CPNowPlayingTemplateObserver

// CPNowPlayingTemplateObserver isn't @MainActor-annotated, so the callbacks have to be declared
// nonisolated and hop back onto the main actor themselves.
extension CarPlayConnector: CPNowPlayingTemplateObserver {

    public nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor in self.showQueue() }
    }

    public nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor in self.showAlbumOrArtistOfCurrentTrack() }
    }
}
#endif
