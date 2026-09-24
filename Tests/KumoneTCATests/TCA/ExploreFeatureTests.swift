import ComposableArchitecture
import Dependencies
import Foundation
import KumoneCore
@testable import KumoneTCA
import XCTest

@MainActor
final class ExploreFeatureTests: XCTestCase {
    // MARK: - Fixtures

    nonisolated private static func makePlaylist(_ id: Int, _ name: String) -> PlaylistSummary {
        let json = """
            {"id": \(id), "name": "\(name)", "picUrl": "https://music.example.com/p\(id).jpg", \
            "playCount": 100, "trackCount": 20}
            """
        return try! JSONDecoder().decode(PlaylistSummary.self, from: Data(json.utf8))
    }

    nonisolated private static func makeToplist(_ id: Int, _ name: String) -> ToplistItem {
        let json = """
            {"id": \(id), "name": "\(name)", "coverImgUrl": "https://music.example.com/t\(id).jpg", \
            "updateFrequency": "每日更新", "playCount": 50, \
            "tracks": [{"first": "歌", "second": "歌手"}]}
            """
        return try! JSONDecoder().decode(ToplistItem.self, from: Data(json.utf8))
    }

    /// The shape of a `/playlist/list` page: the API echoes the tail of the
    /// previous page at the head of the next one.
    private func stubPaging(
        _ deps: inout DependencyValues,
        pages: [[PlaylistSummary]],
        more: [Bool]
    ) {
        deps.netease.topPlaylists = { _, _, _, offset in
            let index = offset / ExploreFeature.pageSize
            return NeteaseAPI.TopPlaylistResponse(
                playlists: pages[min(index, pages.count - 1)],
                total: nil,
                more: more[min(index, more.count - 1)]
            )
        }
    }

    // loadEffect captures musicProvider before selecting a category, so even
    // categories still using netease need the provider override.

    // MARK: - First load

    /// The default category pages through /playlist/list.
    func testOnAppearLoadsTheFirstPage() async {
        let store = TestStore(initialState: ExploreFeature.State()) {
            ExploreFeature()
        } withDependencies: {
            $0.musicProvider = MockMusicProvider()
            stubPaging(&$0, pages: [[Self.makePlaylist(1, "歌单一")]], more: [true])
        }
        await store.send(.onAppear) {
            $0.loadState = ExploreFeature.State.LoadState.loading
        }
        await store.receive(.pageLoaded(.playlists(
            appended: [Self.makePlaylist(1, "歌单一")],
            hasMore: true,
            cursor: ExploreFeature.Cursor(offset: 50, highQualityBefore: 0)
        ))) {
            $0.playlists = [Self.makePlaylist(1, "歌单一")]
            $0.hasMore = true
            $0.offset = 50
            $0.loadState = ExploreFeature.State.LoadState.loaded
        }
    }

    /// `onAppear` is a load-once guard.
    func testOnAppearIsIdempotentOnceLoaded() async {
        let store = TestStore(initialState: ExploreFeature.State()) {
            ExploreFeature()
        } withDependencies: {
            $0.musicProvider = MockMusicProvider()
            stubPaging(&$0, pages: [[Self.makePlaylist(1, "歌单一")]], more: [false])
        }
        await store.send(.onAppear) { $0.loadState = ExploreFeature.State.LoadState.loading }
        await store.receive(.pageLoaded(.playlists(
            appended: [Self.makePlaylist(1, "歌单一")],
            hasMore: false,
            cursor: ExploreFeature.Cursor(offset: 50, highQualityBefore: 0)
        ))) {
            $0.playlists = [Self.makePlaylist(1, "歌单一")]
            $0.hasMore = false
            $0.offset = 50
            $0.loadState = ExploreFeature.State.LoadState.loaded
        }
        await store.send(.onAppear)
    }

    // MARK: - Categories

    /// 排行榜 replaces the grid with the toplist response and is a single page.
    func testToplistCategoryReplacesTheGrid() async {
        var state = ExploreFeature.State()
        state.playlists = [Self.makePlaylist(1, "旧歌单")]
        state.offset = 50
        let store = TestStore(initialState: state) {
            ExploreFeature()
        } withDependencies: {
            $0.musicProvider = MockMusicProvider()
            $0.netease.toplists = {
                [Self.makeToplist(19_723_756, "云音乐飙升榜"), Self.makeToplist(3_779_629, "新歌榜")]
            }
        }
        await store.send(.selectCategory("排行榜")) {
            $0.selectedCategory = "排行榜"
            $0.playlists = []
            $0.toplists = []
            $0.hasMore = true
            $0.offset = 0
            $0.highQualityBefore = 0
            $0.loadState = ExploreFeature.State.LoadState.loading
        }
        await store.receive(.pageLoaded(.toplists(
            [Self.makeToplist(19_723_756, "云音乐飙升榜"), Self.makeToplist(3_779_629, "新歌榜")]
        ))) {
            $0.toplists = [Self.makeToplist(19_723_756, "云音乐飙升榜"), Self.makeToplist(3_779_629, "新歌榜")]
            $0.hasMore = false
            $0.loadState = ExploreFeature.State.LoadState.loaded
        }
    }

    /// 推荐歌单 is a single page too.
    func testRecommendCategoryIsOnePage() async {
        let store = TestStore(initialState: ExploreFeature.State()) {
            ExploreFeature()
        } withDependencies: {
            var provider = MockMusicProvider()
            provider.personalizedPlaylistsHandler = { _ in
                (1...3).map { Self.makePlaylist($0, "推荐\($0)") }
            }
            $0.musicProvider = provider
            // loadEffect captures `netease` unconditionally alongside `provider`.
            $0.netease.toplists = { [] }
        }
        await store.send(.selectCategory("推荐歌单")) {
            $0.selectedCategory = "推荐歌单"
            $0.hasMore = true
            $0.loadState = ExploreFeature.State.LoadState.loading
        }
        await store.receive(.pageLoaded(.playlists(
            appended: (1...3).map { Self.makePlaylist($0, "推荐\($0)") },
            hasMore: false,
            cursor: ExploreFeature.Cursor()
        ))) {
            $0.playlists = (1...3).map { Self.makePlaylist($0, "推荐\($0)") }
            $0.hasMore = false
            $0.loadState = ExploreFeature.State.LoadState.loaded
        }
    }

    /// Selecting the category that is already shown (with data) is a no-op.
    func testSelectingTheSameCategoryIsIgnored() async {
        var state = ExploreFeature.State()
        state.selectedCategory = "华语"
        state.playlists = [Self.makePlaylist(1, "歌单一")]
        state.loadState = ExploreFeature.State.LoadState.loaded
        let store = TestStore(initialState: state) { ExploreFeature() } withDependencies: {
            $0.netease.topPlaylists = { _, _, _, _ in
                NeteaseAPI.TopPlaylistResponse(playlists: [], total: nil, more: false)
            }
        }
        await store.send(.selectCategory("华语"))
    }

    // MARK: - Paging

    /// loadMore advances the cursor and deduplicates the page the API repeats.
    func testLoadMoreAppendsTheNextPageAndAdvancesTheCursor() async {
        let store = TestStore(initialState: ExploreFeature.State()) {
            ExploreFeature()
        } withDependencies: {
            $0.musicProvider = MockMusicProvider()
            stubPaging(
                &$0,
                pages: [
                    [Self.makePlaylist(1, "歌单一")],
                    // id 1 is repeated by the API and must be collapsed.
                    [Self.makePlaylist(1, "歌单一"), Self.makePlaylist(2, "歌单二")],
                ],
                more: [true, false])
        }
        await store.send(.onAppear) { $0.loadState = ExploreFeature.State.LoadState.loading }
        await store.receive(.pageLoaded(.playlists(
            appended: [Self.makePlaylist(1, "歌单一")],
            hasMore: true,
            cursor: ExploreFeature.Cursor(offset: 50, highQualityBefore: 0)
        ))) {
            $0.playlists = [Self.makePlaylist(1, "歌单一")]
            $0.hasMore = true
            $0.offset = 50
            $0.loadState = ExploreFeature.State.LoadState.loaded
        }
        await store.send(.loadMore) { $0.loadState = ExploreFeature.State.LoadState.loading }
        await store.receive(.pageLoaded(.playlists(
            appended: [Self.makePlaylist(2, "歌单二")],
            hasMore: false,
            cursor: ExploreFeature.Cursor(offset: 100, highQualityBefore: 0)
        ))) {
            $0.playlists = [Self.makePlaylist(1, "歌单一"), Self.makePlaylist(2, "歌单二")]
            $0.hasMore = false
            $0.offset = 100
            $0.loadState = ExploreFeature.State.LoadState.loaded
        }
    }

    /// The default category stops paging at the offset cap even if the API
    /// keeps saying there is more.
    func testPagingStopsAtTheOffsetCap() async {
        var state = ExploreFeature.State()
        state.loadState = ExploreFeature.State.LoadState.loaded
        state.offset = 450
        state.hasMore = true
        let store = TestStore(initialState: state) {
            ExploreFeature()
        } withDependencies: {
            $0.musicProvider = MockMusicProvider()
            stubPaging(
                &$0,
                pages: [[Self.makePlaylist(9, "第九页")]],
                more: [true])
        }
        await store.send(.loadMore) { $0.loadState = ExploreFeature.State.LoadState.loading }
        await store.receive(.pageLoaded(.playlists(
            appended: [Self.makePlaylist(9, "第九页")],
            hasMore: false,
            cursor: ExploreFeature.Cursor(offset: 500, highQualityBefore: 0)
        ))) {
            $0.playlists = [Self.makePlaylist(9, "第九页")]
            $0.hasMore = false
            $0.offset = 500
            $0.loadState = ExploreFeature.State.LoadState.loaded
        }
    }

    /// 精品歌单 pages with the `lasttime` cursor instead of an offset.
    func testHighQualityCategoryPagesByLastTime() async {
        let store = TestStore(initialState: ExploreFeature.State()) {
            ExploreFeature()
        } withDependencies: {
            $0.musicProvider = MockMusicProvider()
            $0.netease.highQualityPlaylists = { _, _, before in
                NeteaseAPI.HighQualityResponse(
                    playlists: [Self.makePlaylist(before + 1, "精品\(before + 1)")],
                    lasttime: before + 1,
                    more: true)
            }
        }
        await store.send(.selectCategory("精品歌单")) {
            $0.selectedCategory = "精品歌单"
            $0.hasMore = true
            $0.loadState = ExploreFeature.State.LoadState.loading
        }
        await store.receive(.pageLoaded(.playlists(
            appended: [Self.makePlaylist(1, "精品1")],
            hasMore: true,
            cursor: ExploreFeature.Cursor(offset: 0, highQualityBefore: 1)
        ))) {
            $0.playlists = [Self.makePlaylist(1, "精品1")]
            $0.hasMore = true
            $0.highQualityBefore = 1
            $0.loadState = ExploreFeature.State.LoadState.loaded
        }
        await store.send(.loadMore) { $0.loadState = ExploreFeature.State.LoadState.loading }
        await store.receive(.pageLoaded(.playlists(
            appended: [Self.makePlaylist(2, "精品2")],
            hasMore: true,
            cursor: ExploreFeature.Cursor(offset: 0, highQualityBefore: 2)
        ))) {
            $0.playlists = [Self.makePlaylist(1, "精品1"), Self.makePlaylist(2, "精品2")]
            $0.hasMore = true
            $0.highQualityBefore = 2
            $0.loadState = ExploreFeature.State.LoadState.loaded
        }
    }

    /// A failed fetch settles the category as a single empty page instead of
    /// looping on a retry.
    func testFailedFetchEndsPaging() async {
        let store = TestStore(initialState: ExploreFeature.State()) {
            ExploreFeature()
        } withDependencies: {
            $0.musicProvider = MockMusicProvider()
            $0.netease.topPlaylists = { _, _, _, _ in throw URLError(.notConnectedToInternet) }
        }
        await store.send(.onAppear) { $0.loadState = ExploreFeature.State.LoadState.loading }
        await store.receive(.pageLoaded(.playlists(
            appended: [], hasMore: false,
            cursor: ExploreFeature.Cursor()
        ))) {
            $0.hasMore = false
            $0.loadState = ExploreFeature.State.LoadState.loaded
        }
        // Nothing more to load: a second loadMore is a no-op.
        await store.send(.loadMore)
    }

    func testPlaylistPlaybackUsesEmbeddedTracks() async throws {
        let detail = try JSONDecoder().decode(NeteaseAPI.PlaylistDetailResponse.self, from: Data(
            #"{"playlist":{"id":42,"name":"播放歌单","tracks":[{"id":7,"name":"歌曲","ar":[],"al":{"id":2,"name":"专辑"},"dt":1000}],"trackIds":[{"id":99}]}}"#.utf8))
        XCTAssertEqual(detail.playlist.tracks.count, 1)
        let store = TestStore(initialState: ExploreFeature.State()) {
            ExploreFeature()
        } withDependencies: {
            $0.netease.playlistDetail = { id in
                XCTAssertEqual(id, 42)
                return detail
            }
            $0.netease.songDetails = { _ in
                XCTFail("Embedded tracks must bypass songDetails")
                return NeteaseAPI.SongDetailResponse(songs: [], privileges: nil)
            }
        }
        await store.send(.playPlaylist(42))
        await store.receive(.delegate(.play(
            tracks: detail.playlist.tracks, source: .playlist(42),
            context: .playlist(id: 42, name: "播放歌单"))))
        await store.finish()
    }

    func testPlaylistPlaybackFetchesAtMost500TrackIDs() async throws {
        let trackIDs = (1...501).map { ["id": $0] }
        let playlist: [String: Any] = [
            "id": 42, "name": "完整歌单", "tracks": [Int](), "trackIds": trackIDs
        ]
        let data = try JSONSerialization.data(withJSONObject: ["playlist": playlist])
        let detail = try JSONDecoder().decode(NeteaseAPI.PlaylistDetailResponse.self, from: data)
        let songs = try JSONDecoder().decode(NeteaseAPI.SongDetailResponse.self, from: Data(
            #"{"songs":[{"id":1,"name":"补全歌曲","ar":[],"al":{"id":2,"name":"专辑"},"dt":1000}]}"#.utf8))
        let store = TestStore(initialState: ExploreFeature.State()) {
            ExploreFeature()
        } withDependencies: {
            $0.netease.playlistDetail = { id in
                XCTAssertEqual(id, 42)
                return detail
            }
            $0.netease.songDetails = { ids in
                XCTAssertEqual(ids, Array(1...500))
                return songs
            }
        }
        await store.send(.playPlaylist(42))
        await store.receive(.delegate(.play(
            tracks: songs.songs, source: .playlist(42),
            context: .playlist(id: 42, name: "完整歌单"))))
        await store.finish()
    }

    func testPlaylistPlaybackDetailFailureProducesNoDelegate() async {
        let store = TestStore(initialState: ExploreFeature.State()) {
            ExploreFeature()
        } withDependencies: {
            $0.netease.playlistDetail = { _ in throw URLError(.badServerResponse) }
            $0.netease.songDetails = { _ in
                XCTFail("Failed detail must stop playback")
                return NeteaseAPI.SongDetailResponse(songs: [], privileges: nil)
            }
        }
        await store.send(.playPlaylist(42))
        await store.finish()
    }

    func testPlaylistPlaybackSongDetailsFailureDelegatesEmptyTracks() async throws {
        let detail = try JSONDecoder().decode(NeteaseAPI.PlaylistDetailResponse.self, from: Data(
            #"{"playlist":{"id":42,"name":"空歌单","trackIds":[{"id":7}]}}"#.utf8))
        let store = TestStore(initialState: ExploreFeature.State()) {
            ExploreFeature()
        } withDependencies: {
            $0.netease.playlistDetail = { _ in detail }
            $0.netease.songDetails = { ids in
                XCTAssertEqual(ids, [7])
                throw URLError(.badServerResponse)
            }
        }
        await store.send(.playPlaylist(42))
        await store.receive(.delegate(.play(
            tracks: [], source: .playlist(42), context: .playlist(id: 42, name: "空歌单"))))
        await store.finish()
    }

    func testToplistFailureLoadsEmptySinglePage() async {
        var state = ExploreFeature.State()
        state.selectedCategory = "排行榜"
        let store = TestStore(initialState: state) {
            ExploreFeature()
        } withDependencies: {
            $0.musicProvider = MockMusicProvider()
            $0.netease.toplists = { throw URLError(.notConnectedToInternet) }
        }
        await store.send(.onAppear) { $0.loadState = .loading }
        await store.receive(.pageLoaded(.toplists([]))) {
            $0.hasMore = false
            $0.loadState = .loaded
        }
        await store.finish()
    }

    func testRecommendedPlaylistsUseLimit100AndDeduplicate() async {
        let first = Self.makePlaylist(1, "保留首项")
        let second = Self.makePlaylist(2, "新增")
        var state = ExploreFeature.State()
        state.selectedCategory = "推荐歌单"
        let store = TestStore(initialState: state) {
            ExploreFeature()
        } withDependencies: {
            var provider = MockMusicProvider()
            provider.personalizedPlaylistsHandler = { limit in
                XCTAssertEqual(limit, 100)
                return [first, first, second]
            }
            $0.musicProvider = provider
            $0.netease = NeteaseMusicClient()
        }
        await store.send(.onAppear) { $0.loadState = .loading }
        await store.receive(.pageLoaded(.playlists(
            appended: [first, second], hasMore: false, cursor: ExploreFeature.Cursor()))) {
            $0.playlists = [first, second]
            $0.hasMore = false
            $0.loadState = .loaded
        }
        await store.finish()
    }

    func testRecommendedPlaylistsFailureEndsPaging() async {
        var state = ExploreFeature.State()
        state.selectedCategory = "推荐歌单"
        let store = TestStore(initialState: state) {
            ExploreFeature()
        } withDependencies: {
            var provider = MockMusicProvider()
            provider.personalizedPlaylistsHandler = { limit in
                XCTAssertEqual(limit, 100)
                throw URLError(.badServerResponse)
            }
            $0.musicProvider = provider
            $0.netease = NeteaseMusicClient()
        }
        await store.send(.onAppear) { $0.loadState = .loading }
        await store.receive(.pageLoaded(.playlists(
            appended: [], hasMore: false, cursor: ExploreFeature.Cursor()))) {
            $0.hasMore = false
            $0.loadState = .loaded
        }
        await store.finish()
    }

    func testHighQualityMissingMetadataResetsTimestampAndEndsPaging() async {
        let old = Self.makePlaylist(1, "已有")
        let added = Self.makePlaylist(2, "新增")
        var state = ExploreFeature.State()
        state.selectedCategory = "精品歌单"
        state.playlists = [old]
        state.offset = 50
        state.highQualityBefore = 123
        state.loadState = .loaded
        let store = TestStore(initialState: state) {
            ExploreFeature()
        } withDependencies: {
            $0.musicProvider = MockMusicProvider()
            $0.netease.highQualityPlaylists = { category, limit, before in
                XCTAssertEqual(category, "全部")
                XCTAssertEqual(limit, 50)
                XCTAssertEqual(before, 123)
                return NeteaseAPI.HighQualityResponse(
                    playlists: [old, added, added], lasttime: nil, more: nil)
            }
        }
        await store.send(.loadMore) { $0.loadState = .loading }
        await store.receive(.pageLoaded(.playlists(
            appended: [added], hasMore: false,
            cursor: ExploreFeature.Cursor(offset: 50, highQualityBefore: 0)))) {
            $0.playlists = [old, added]
            $0.highQualityBefore = 0
            $0.hasMore = false
            $0.loadState = .loaded
        }
        await store.finish()
    }

    func testHighQualityFailurePreservesCursorAndExistingPlaylists() async {
        var state = ExploreFeature.State()
        state.selectedCategory = "精品歌单"
        state.playlists = [Self.makePlaylist(1, "已有")]
        state.highQualityBefore = 123
        state.loadState = .loaded
        let store = TestStore(initialState: state) {
            ExploreFeature()
        } withDependencies: {
            $0.musicProvider = MockMusicProvider()
            $0.netease.highQualityPlaylists = { _, _, _ in throw URLError(.badServerResponse) }
        }
        await store.send(.loadMore) { $0.loadState = .loading }
        await store.receive(.pageLoaded(.playlists(
            appended: [], hasMore: false,
            cursor: ExploreFeature.Cursor(offset: 0, highQualityBefore: 123)))) {
            $0.hasMore = false
            $0.loadState = .loaded
        }
        await store.finish()
    }

    func testOrdinaryPlaylistMissingMoreStopsBeforeOffsetCap() async {
        let store = TestStore(initialState: ExploreFeature.State()) {
            ExploreFeature()
        } withDependencies: {
            $0.musicProvider = MockMusicProvider()
            $0.netease.topPlaylists = { category, order, limit, offset in
                XCTAssertEqual(category, "全部")
                XCTAssertEqual(order, "hot")
                XCTAssertEqual(limit, 50)
                XCTAssertEqual(offset, 0)
                return NeteaseAPI.TopPlaylistResponse(playlists: [], total: nil, more: nil)
            }
        }
        await store.send(.onAppear) { $0.loadState = .loading }
        await store.receive(.pageLoaded(.playlists(
            appended: [], hasMore: false,
            cursor: ExploreFeature.Cursor(offset: 50, highQualityBefore: 0)))) {
            $0.offset = 50
            $0.hasMore = false
            $0.loadState = .loaded
        }
        await store.finish()
    }

    func testLoadMoreWhileLoadingDoesNothing() async {
        var state = ExploreFeature.State()
        state.loadState = .loading
        let store = TestStore(initialState: state) { ExploreFeature() }
        await store.send(.loadMore)
        await store.send(.onAppear)
        await store.finish()
    }
}
