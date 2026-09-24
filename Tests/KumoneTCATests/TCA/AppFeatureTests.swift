import ComposableArchitecture
import Dependencies
import Foundation
import KumoneCore
@testable import KumoneTCA
import XCTest

@MainActor
final class AppFeatureTests: XCTestCase {
    /// `UserProfile` has a Decodable-only conformance, so build one from JSON.
    nonisolated private static func makeProfile(_ nickname: String = "tester") -> UserProfile {
        let json = "{\"userId\": 42, \"nickname\": \"\(nickname)\", \"vipType\": 11}"
        return try! JSONDecoder().decode(UserProfile.self, from: Data(json.utf8))
    }

    nonisolated private static func makePlaylistSummary(_ id: Int, _ name: String, specialType: Int = 0)
        -> PlaylistSummary
    {
        let json = "{\"id\": \(id), \"name\": \"\(name)\", \"specialType\": \(specialType)}"
        return try! JSONDecoder().decode(PlaylistSummary.self, from: Data(json.utf8))
    }

    nonisolated private static var likedSongsPlaylist: PlaylistSummary {
        makePlaylistSummary(9, "我喜欢的音乐", specialType: 5)
    }

    nonisolated private static func makeAlbumSummary(_ id: Int) -> AlbumSummary {
        let json = """
            {"id": \(id), "name": "专辑\(id)", "picUrl": "https://music.example.com/a\(id).jpg", \
            "artist": {"name": "歌手"}, "publishTime": 1700000000000, "size": 2}
            """
        return try! JSONDecoder().decode(AlbumSummary.self, from: Data(json.utf8))
    }

    nonisolated private static func makeArtist() -> ArtistSummary {
        let json = """
            {"id": 7, "name": "歌手", "picUrl": "https://music.example.com/ar7.jpg", \
            "albumSize": 3, "musicSize": 9, "briefDesc": "简介", "alias": [], "followed": false}
            """
        return try! JSONDecoder().decode(ArtistSummary.self, from: Data(json.utf8))
    }

    nonisolated private static func track(_ id: Int, _ name: String, durationMS: Int = 200_000) -> Track {
        Track(
            id: id, name: name, artists: [],
            album: AlbumRef(id: 0, name: "Album", picUrl: nil),
            durationMS: durationMS, alias: [], transNames: [], fee: 0, mvID: 0, trackNo: 0,
            disc: nil, noCopyright: false, isCloud: false, embeddedPrivilege: nil)
    }

    /// The account bootstrap chain: cookie check → profile → library refresh.
    private func configureAccount(_ deps: inout DependencyValues) {
        deps.session.hasAuthCookie = { true }
        deps.persistence.doubleForKey = { _ in 0 }
        deps.persistence.setDouble = { _, _ in }
        deps.netease.userAccount = { Self.makeProfile() }
        deps.netease.userPlaylists = { _, _, _ in [] }
        deps.netease.likedTrackIDs = { _ in [] }
    }

    // MARK: - Player → toasts

    func testPlayerToastIsForwardedToTheToastOverlay() async {
        let toastID = UUID()
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            $0.uuid = .init { toastID }
        }
        await store.send(.player(.toast("无法播放")))
        await store.receive(.toasts(.presented("无法播放"))) {
            $0.toasts.current = Toast(id: toastID, message: "无法播放")
        }
        await store.receive(.toasts(.autoDismissTimerCompleted(toastID))) {
            $0.toasts.current = nil
        }
    }

    // MARK: - Settings → player mirrors

    func testSettingsAreMirroredIntoThePlayer() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.persistence.setBool = { _, _ in }
            $0.persistence.setString = { _, _ in }
        }
        await store.send(.settings(.setAudioQuality(.lossless))) {
            $0.settings.audioQuality = .lossless
            $0.player.audioQuality = .lossless
            $0.playlistRoot.enableUnblock = true
        }
        await store.send(.settings(.setEnableUnblock(false))) {
            $0.settings.enableUnblock = false
            $0.player.enableUnblock = false
            $0.playlistRoot.enableUnblock = false
        }
    }

    // MARK: - Account → player mirrors

    func testBootstrapMirrorsLoginIntoThePlayerAndWelcomesTheUser() async {
        let toastID = UUID()
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.musicProvider = MockMusicProvider()
            configureAccount(&$0)
            $0.continuousClock = ImmediateClock()
            $0.uuid = .init { toastID }
        }
        await store.send(.account(.bootstrap)) {
            $0.account.hasAuthCookie = true
            $0.account.isBootstrapping = true
        }
        await store.receive(.account(.bootstrapResponse(.success(Self.makeProfile())))) {
            $0.account.profile = Self.makeProfile()
            $0.account.isBootstrapped = true
            $0.account.isBootstrapping = false
            $0.player.isLoggedIn = true
            $0.player.vipType = 11
            $0.home.isLoggedIn = true
            $0.daily.isLoggedIn = true
            $0.recents.userID = 42
            $0.playlistRoot.isLoggedIn = true
            $0.playlistRoot.vipType = 11
        }
        // Bootstrap chains into a library refresh; the mirror is already live.
        await store.receive(.account(.refreshLibrary))
        // "欢迎回来" fires once the profile is known.
        await store.receive(.toasts(.presented("欢迎回来，tester"))) {
            $0.toasts.current = Toast(id: toastID, message: "欢迎回来，tester")
        }
        await store.receive(.account(.libraryResponse(.success(
            AccountFeature.LibraryRefresh(playlists: [], likedTrackIDs: [])
        ))))
        await store.receive(.toasts(.autoDismissTimerCompleted(toastID))) {
            $0.toasts.current = nil
        }
    }

    // MARK: - Sidebar selection

    func testSidebarSelectionClearsTheDetailStack() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        }
        await store.send(.openDestination(.album(3))) {
            $0.path.append(.album(AlbumDetailFeature.State(albumID: 3)))
        }
        await store.send(.selectionChanged(.home)) {
            $0.selection = .home
            $0.path.removeAll()
        }
    }

    func testLikedSongsSelectionPointsThePlaylistRootAtTheLikedList() async {
        var state = AppFeature.State()
        state.account.userPlaylists = [Self.likedSongsPlaylist]
        let store = TestStore(initialState: state) {
            AppFeature()
        }
        await store.send(.selectionChanged(.likedSongs)) {
            $0.selection = .likedSongs
            $0.playlistRoot = PlaylistDetailFeature.State(playlistID: 9)
        }
        await store.send(.selectionChanged(.playlist(42))) {
            $0.selection = .playlist(42)
            $0.playlistRoot = PlaylistDetailFeature.State(playlistID: 42)
        }
    }

    func testLikedSongsSelectionKeepsTheRootWhenTheLibraryIsEmpty() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        }
        await store.send(.selectionChanged(.likedSongs)) {
            $0.selection = .likedSongs
        }
    }

    // MARK: - Destination stack

    func testOpenDestinationSnapshotsAccountContextIntoThePushedPlaylist() async {
        var state = AppFeature.State()
        state.account.hasAuthCookie = true
        state.account.profile = Self.makeProfile()
        state.settings.enableUnblock = false
        let store = TestStore(initialState: state) {
            AppFeature()
        }
        await store.send(.openDestination(.playlist(5))) {
            var detail = PlaylistDetailFeature.State(playlistID: 5)
            detail.isLoggedIn = true
            detail.vipType = 11
            detail.enableUnblock = false
            $0.path.append(.playlist(detail))
        }
    }

    func testOpenDestinationIgnoresTheSamePageTwice() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        }
        await store.send(.openDestination(.album(3))) {
            $0.path.append(.album(AlbumDetailFeature.State(albumID: 3)))
        }
        await store.send(.openDestination(.album(3)))
    }

    // MARK: - Login sheet

    func testPresentLoginShowsTheSheet() async {
        var state = AppFeature.State()
        // Already past the QR fetch so `onAppear` has nothing to start.
        state.login.phase = .waiting
        let store = TestStore(initialState: state) {
            AppFeature()
        }
        await store.send(.presentLogin) {
            $0.isLoginPresented = true
        }
        await store.receive(.login(.onAppear))
    }

    func testDismissLoginClosesTheSheet() async {
        var state = AppFeature.State()
        state.isLoginPresented = true
        let store = TestStore(initialState: state) {
            AppFeature()
        }
        await store.send(.dismissLogin) {
            $0.isLoginPresented = false
        }
        await store.receive(.login(.dismiss))
        await store.receive(.login(.stopPolling))
    }

    func testLoginSuccessClosesTheSheetAndBootstrapsTheAccount() async {
        var state = AppFeature.State()
        state.login.phase = .waiting
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            // No cookie yet: bootstrap settles without a profile fetch.
            $0.session.hasAuthCookie = { false }
        }
        await store.send(.login(.loginSucceeded)) {
            $0.isLoginPresented = false
            $0.login.phase = .success
        }
        await store.receive(.account(.bootstrap)) {
            $0.account.hasAuthCookie = false
            $0.account.isBootstrapped = true
        }
    }

    // MARK: - Delegate forwarding

    func testPlaylistRootPlayIsForwardedToThePlayer() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        }
        await store.send(.playlistRoot(.delegate(.play(tracks: [], source: .none, startAt: nil, context: nil))))
        await store.receive(.player(.play(tracks: [], source: .none, startAt: nil, context: nil)))
    }

    func testPathPlayIsForwardedToThePlayer() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        }
        await store.send(.openDestination(.album(3))) {
            $0.path.append(.album(AlbumDetailFeature.State(albumID: 3)))
        }
        await store.send(.path(.element(id: 0, action: .album(.delegate(.play(tracks: [], source: .album(3), startAt: nil, context: nil))))))
        await store.receive(.player(.play(tracks: [], source: .album(3), startAt: nil, context: nil)))
    }

    func testRecentsPlayForwardsTheStartTrack() async {
        let start = Self.track(7, "七")
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        }
        await store.send(.openDestination(.recents)) {
            $0.path.append(.recents(RecentsFeature.State()))
        }
        await store.send(.path(.element(id: 0, action: .recents(.delegate(.play(tracks: [], startAt: start, context: .recents))))))
        await store.receive(.player(.play(tracks: [], source: .none, startAt: start, context: .recents)))
    }

    func testPlaylistRootToastIsForwardedToTheToastOverlay() async {
        let toastID = UUID()
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            $0.uuid = .init { toastID }
        }
        await store.send(.playlistRoot(.delegate(.toast("已收藏"))))
        await store.receive(.toasts(.presented("已收藏"))) {
            $0.toasts.current = Toast(id: toastID, message: "已收藏")
        }
        await store.receive(.toasts(.autoDismissTimerCompleted(toastID))) {
            $0.toasts.current = nil
        }
    }

    func testLikeFailureIsForwardedToTheToastOverlay() async {
        let toastID = UUID()
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            $0.uuid = .init { toastID }
        }
        await store.send(.account(.toggleLikeFailed(AppError("登录后即可收藏歌曲"))))
        await store.receive(.toasts(.presented("登录后即可收藏歌曲"))) {
            $0.toasts.current = Toast(id: toastID, message: "登录后即可收藏歌曲")
        }
        await store.receive(.toasts(.autoDismissTimerCompleted(toastID))) {
            $0.toasts.current = nil
        }
    }

    func testSubscriptionChangedRefreshesTheLibrary() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        }
        await store.send(.playlistRoot(.delegate(.subscriptionChanged)))
        // No profile yet, so the refresh is a no-op.
        await store.receive(.account(.refreshLibrary))
    }

    func testCollectionsDelegateRefreshesTheSublists() async {
        let album = Self.makeAlbumSummary(1)
        let artist = Self.makeArtist()
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            var provider = MockMusicProvider()
            provider.likedAlbumsHandler = { _, _ in [album] }
            provider.likedArtistsHandler = { _, _ in [artist] }
            $0.musicProvider = provider
        }
        await store.send(.openDestination(.collections)) {
            $0.path.append(.collections(CollectionsFeature.State()))
        }
        await store.send(.path(.element(id: 0, action: .collections(.delegate(.refreshSublists)))))
        await store.receive(.account(.refreshSublists))
        await store.receive(.account(.sublistsResponse(.success(
            AccountFeature.SublistsRefresh(albums: [album], artists: [artist])
        )))) {
            $0.account.likedAlbums = [album]
            $0.account.likedArtists = [artist]
        }
    }

    // MARK: - Updater

    func testSetAutoCheckUpdatesIsForwardedToTheUpdater() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.persistence.setBool = { _, _ in }
            $0.updater.setAutomaticChecks = { XCTAssertEqual($0, true) }
        }
        await store.send(.settings(.setAutoCheckUpdates(true))) {
            $0.settings.autoCheckUpdates = true
            $0.playlistRoot.enableUnblock = true
        }
        await store.receive(.updater(.setAutomaticChecks(true)))
    }

    func testSettingsOnAppearPushesThePersistedAutoCheckToTheUpdater() async {
        var state = AppFeature.State()
        // Already loaded, so `onAppear` does not rehydrate from disk.
        state.settings.isLoaded = true
        state.settings.autoCheckUpdates = true
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.updater.setAutomaticChecks = { XCTAssertEqual($0, true) }
        }
        await store.send(.settings(.onAppear)) {
            $0.playlistRoot.enableUnblock = true
        }
        await store.receive(.updater(.setAutomaticChecks(true)))
    }

    func testCheckForUpdatesIsForwardedToTheUpdater() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.updater.checkForUpdates = {}
        }
        await store.send(.settings(.checkForUpdates)) {
            $0.playlistRoot.enableUnblock = true
        }
        await store.receive(.updater(.checkForUpdates))
    }

    // MARK: - Now Playing commands

    func testNowPlayingTransportCommandsRouteToThePlayer() async {
        let t0 = Date(timeIntervalSince1970: 1000)
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.date = .constant(t0)
        }
        // `next`/`previous` decompose inside the player: with an empty queue
        // `next` advances to nothing, and `previous` rewinds to zero.
        await store.send(.nowPlaying(.next))
        await store.receive(.player(.next))
        await store.receive(.player(.advanceToNext(userInitiated: true))) {
            $0.player.playbackIntent = true
        }
        await store.send(.nowPlaying(.previous))
        await store.receive(.player(.previous))
        await store.receive(.player(.seek(0))) {
            $0.player.playbackIntent = true
            $0.player.isPlaying = true
            $0.player.pendingSeekTarget = 0
            $0.player.seekGuardUntil = t0.addingTimeInterval(3)
        }
        await store.send(.nowPlaying(.togglePlayPause))
        await store.receive(.player(.togglePlayPause))
        await store.send(.nowPlaying(.seek(42)))
        await store.receive(.player(.seek(42))) {
            $0.player.progress = 42
            $0.player.playbackIntent = true
            $0.player.isPlaying = true
            $0.player.pendingSeekTarget = 42
            $0.player.seekGuardUntil = t0.addingTimeInterval(3)
        }
    }

    func testNowPlayingPlayPauseOnlyTogglesWhenTheStateDisagrees() async {
        var state = AppFeature.State()
        state.player.currentTrack = Self.track(1, "一")
        state.player.isPlaying = true
        let store = TestStore(initialState: state) {
            AppFeature()
        }
        // Already playing: `play` is a no-op, `pause` toggles.
        await store.send(.nowPlaying(.play))
        await store.send(.nowPlaying(.pause))
        await store.receive(.player(.togglePlayPause))
        await store.receive(.player(.pause)) {
            $0.player.isPlaying = false
        }
    }

    func testNowPlayingLikeTogglesTheCurrentTrack() async {
        var state = AppFeature.State()
        state.account.hasAuthCookie = true
        state.account.profile = Self.makeProfile()
        state.player.currentTrack = Self.track(9, "九")
        // The account mirror already propagated into the siblings, so the like
        // does not re-sync them.
        state.player.isLoggedIn = true
        state.player.vipType = 11
        state.home.isLoggedIn = true
        state.daily.isLoggedIn = true
        state.recents.userID = 42
        state.playlistRoot.isLoggedIn = true
        state.playlistRoot.vipType = 11
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.netease.likeTrack = { _, _ in }
        }
        await store.send(.nowPlaying(.like))
        await store.receive(.account(.toggleLike(9))) {
            $0.account.likedTrackIDs = [9]
        }
        await store.receive(.account(.likeResponse(.success(true), trackID: 9)))
    }

    func testNowPlayingLikeIsIgnoredWithoutACurrentTrack() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        }
        await store.send(.nowPlaying(.like))
    }

    func testNowPlayingShuffleAndRepeatOnlyChangeWhenDifferent() async {
        var state = AppFeature.State()
        state.player.shuffleEnabled = false
        state.player.repeatMode = .off
        let store = TestStore(initialState: state) {
            AppFeature()
        }
        await store.send(.nowPlaying(.shuffle(false)))
        await store.send(.nowPlaying(.shuffle(true)))
        await store.receive(.player(.toggleShuffle)) {
            $0.player.shuffleEnabled = true
        }
        await store.send(.nowPlaying(.repeatMode(.off)))
        await store.send(.nowPlaying(.repeatMode(.all)))
        await store.receive(.player(.setRepeatMode(.all))) {
            $0.player.repeatMode = .all
        }
    }

    func testNowPlayingStateIsMirroredToTheClient() async {
        var state = AppFeature.State()
        state.player.currentTrack = Self.track(9, "九")
        state.account.likedTrackIDs = [9]
        state.player.shuffleEnabled = true
        state.player.repeatMode = .one
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.nowPlaying.setLiked = { XCTAssertTrue($0) }
            $0.nowPlaying.setShuffle = { XCTAssertTrue($0) }
            $0.nowPlaying.setRepeat = { XCTAssertEqual($0, .one) }
        }
        await store.send(.player(.setVolume(0.5))) {
            $0.player.volume = 0.5
        }
    }

    func testLogoutDropsThePlayerLoginMirror() async {
        var state = AppFeature.State()
        state.account.hasAuthCookie = true
        state.account.profile = Self.makeProfile()
        state.player.isLoggedIn = true
        state.player.vipType = 11
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.session.clearAuth = {}
        }
        await store.send(.account(.logoutResponse)) {
            $0.account.hasAuthCookie = false
            $0.account.profile = nil
            $0.player.isLoggedIn = false
            $0.player.vipType = 0
        }
    }

    func testNowPlayingPresentationAndClearPath() async {
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
        await store.send(.presentNowPlaying) { $0.isNowPlayingPresented = true }
        await store.send(.dismissNowPlaying) { $0.isNowPlayingPresented = false }
        await store.send(.openDestination(.artist(7))) {
            $0.path.append(.artist(ArtistDetailFeature.State(artistID: 7)))
        }
        await store.send(.clearPath) { $0.path = StackState() }
        await store.send(.clearPath)
    }

    func testEveryDestinationMapsToItsFeatureState() {
        let cases: [(Destination, AppFeature.Path.State)] = [
            (.playlist(1), .playlist(PlaylistDetailFeature.State(playlistID: 1))),
            (.radarPlaylist(2), .radarPlaylist(PlaylistDetailFeature.State(playlistID: 2))),
            (.album(3), .album(AlbumDetailFeature.State(albumID: 3))),
            (.artist(4), .artist(ArtistDetailFeature.State(artistID: 4))),
            (.daily, .daily(DailySongsFeature.State())),
            (.toplists, .toplists(ToplistsFeature.State())),
            (.recents, .recents(RecentsFeature.State())),
            (.collections, .collections(CollectionsFeature.State())),
            (.cloud, .cloud(CloudFeature.State())),
            (.search("query"), .search(SearchFeature.State(query: "query"))),
        ]
        for (destination, expected) in cases {
            XCTAssertEqual(AppFeature.pathElement(for: destination), expected)
        }
    }

    func testRadarDestinationSnapshotsAccountAndSettings() async {
        var state = AppFeature.State()
        state.account.hasAuthCookie = true
        state.account.profile = Self.makeProfile()
        state.settings.enableUnblock = false
        let store = TestStore(initialState: state) { AppFeature() }
        await store.send(.openDestination(.radarPlaylist(12))) {
            var detail = PlaylistDetailFeature.State(playlistID: 12)
            detail.isLoggedIn = true
            detail.vipType = 11
            detail.enableUnblock = false
            $0.path.append(.radarPlaylist(detail))
        }
        await store.send(.openDestination(.radarPlaylist(12)))
    }

    func testHomeAndSearchPlayDelegatesForwardTheirArguments() async {
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
        await store.send(.home(.delegate(.play(tracks: [], source: .playlist(9), context: .heartbeat))))
        await store.receive(.player(.play(tracks: [], source: .playlist(9), startAt: nil, context: .heartbeat)))
        let start = Self.track(7, "seven")
        await store.send(.search(.delegate(.play(tracks: [], source: .none, startAt: start, context: nil))))
        await store.receive(.player(.play(tracks: [], source: .none, startAt: start, context: nil)))
    }

    func testAppearanceAttachesCommandsOnce() async {
        var state = AppFeature.State()
        state.player.isLoaded = true
        state.settings.isLoaded = true
        state.account.isBootstrapped = true
        state.updater.isStarted = true
        let commands = AsyncStream<NowPlayingCommand>.makeStream()
        nonisolated(unsafe) var attachments = 0
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.nowPlaying.attach = {
                attachments += 1
                return commands.stream
            }
            $0.updater.setAutomaticChecks = { XCTAssertTrue($0) }
        }
        await store.send(.onAppear) { $0.isAppeared = true }
        await store.receive(.player(.onAppear))
        await store.receive(.settings(.onAppear)) { $0.playlistRoot.enableUnblock = true }
        await store.receive(.account(.bootstrap))
        await store.receive(.updater(.onAppear))
        await store.receive(.updater(.setAutomaticChecks(true)))
        commands.continuation.yield(.like)
        await store.receive(.nowPlaying(.like))
        commands.continuation.finish()
        await store.finish()
        await store.send(.onAppear)
        XCTAssertEqual(attachments, 1)
    }

    func testHeartbeatRequiresLikedPlaylist() async {
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
        await store.send(.startHeartbeat)
        await store.send(.home(.delegate(.startHeartbeat)))
        await store.receive(.startHeartbeat)
    }

    func testHeartbeatWithoutSeedShowsInstruction() async {
        var state = AppFeature.State()
        state.account.userPlaylists = [Self.likedSongsPlaylist]
        let toastID = UUID()
        let message = String(localized: "先收藏一些喜欢的歌曲吧")
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.uuid = .init { toastID }
            $0.continuousClock = ImmediateClock()
        }
        await store.send(.startHeartbeat)
        await store.receive(.toasts(.presented(message))) {
            $0.toasts.current = Toast(id: toastID, message: message)
        }
        await store.receive(.toasts(.autoDismissTimerCompleted(toastID))) { $0.toasts.current = nil }
    }

    func testHeartbeatEmptyResultsAndNetworkFailureShowToast() async {
        for fails in [false, true] {
            var state = AppFeature.State()
            state.account.userPlaylists = [Self.likedSongsPlaylist]
            state.account.likedTrackIDs = [7]
            let failure = URLError(.notConnectedToInternet)
            let message = fails ? failure.localizedDescription : String(localized: "心动模式暂时不可用")
            let toastID = UUID()
            let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
                $0.uuid = .init { toastID }
                $0.continuousClock = ImmediateClock()
                $0.netease.intelligenceList = { seed, playlistID in
                    XCTAssertEqual(seed, 7)
                    XCTAssertEqual(playlistID, 9)
                    if fails { throw failure }
                    return []
                }
            }
            await store.send(.startHeartbeat)
            await store.receive(.toasts(.presented(message))) {
                $0.toasts.current = Toast(id: toastID, message: message)
            }
            await store.receive(.toasts(.autoDismissTimerCompleted(toastID))) { $0.toasts.current = nil }
        }
    }

    func testHeartbeatSuccessStartsRecommendedQueueAndShowsConfirmation() async {
        let clock = TestClock()
        let recommended = Self.track(7, "recommended")
        let toastID = UUID()
        let message = String(localized: "已开启心动模式")
        let url = URL(string: "https://example.com/track.mp3")!
        var state = AppFeature.State()
        state.account.userPlaylists = [Self.likedSongsPlaylist]
        state.account.likedTrackIDs = [7]
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.continuousClock = clock
            $0.uuid = .init { toastID }
            $0.unblock.resolve = { _ in nil }
            $0.netease.intelligenceList = { _, _ in [recommended] }
            $0.persistence.setData = { _, _ in }
            $0.playback.updateMetadata = { _, _, _, _ in }
            $0.playback.load = { loadedURL, autostart in
                XCTAssertEqual(loadedURL, url)
                XCTAssertTrue(autostart)
            }
            $0.netease.scrobbleStart = { trackID, sourceID in
                XCTAssertEqual(trackID, 7)
                XCTAssertEqual(sourceID, 9)
            }
            $0.netease.lyric = { _ in
                try await clock.sleep(for: .seconds(1))
                throw URLError(.badServerResponse)
            }
            $0.netease.songURL = { _, _ in
                try await clock.sleep(for: .seconds(2))
                return [SongURLData(id: 7, url: url.absoluteString, br: 0, size: 0, type: nil,
                                    level: "exhigh", fee: 0, freeTrialInfo: nil, time: 200)]
            }
        }
        await store.send(.startHeartbeat)
        await store.receive(.player(.play(tracks: [recommended], source: .playlist(9), startAt: nil, context: .heartbeat))) {
            $0.player.queue = [recommended]
            $0.player.currentIndex = 0
            $0.player.source = .playlist(9)
            $0.player.playbackIntent = true
            $0.player.recentContexts = [.heartbeat]
        }
        await store.receive(.player(.startPlaying(recommended))) {
            $0.player.currentTrack = recommended
            $0.player.duration = recommended.duration
            $0.player.isPlaying = true
            $0.player.resolveGeneration = 1
        }
        await store.receive(.toasts(.presented(message))) {
            $0.toasts.current = Toast(id: toastID, message: message)
        }
        await clock.advance(by: .seconds(1))
        await store.receive(.player(.lyricsResponse(generation: 1, nil)))
        await clock.advance(by: .seconds(1))
        await store.receive(.player(.urlResolved(generation: 1, autostart: true, PlayerFeature.ResolvedSource(
            url: url, servedQuality: "exhigh", isTrial: false, unblockSource: nil
        )))) {
            $0.player.servedQuality = "exhigh"
            $0.player.engineHasItem = true
            $0.player.startScrobbled = true
        }
        await clock.advance(by: .seconds(1))
        await store.receive(.toasts(.autoDismissTimerCompleted(toastID))) { $0.toasts.current = nil }
        await store.finish()
    }

    func testConsecutiveIdenticalDestinationDoesNotAppendAnotherPage() async {
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
        await store.send(.openDestination(.artist(7))) {
            $0.path.append(.artist(ArtistDetailFeature.State(artistID: 7)))
        }
        await store.send(.openDestination(.artist(7)))
        await store.finish()
        XCTAssertEqual(store.state.path.count, 1)
    }

}
