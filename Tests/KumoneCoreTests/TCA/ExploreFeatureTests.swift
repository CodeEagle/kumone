import ComposableArchitecture
import Dependencies
@testable import KumoneCore
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

    // MARK: - First load

    /// The default category pages through /playlist/list.
    func testOnAppearLoadsTheFirstPage() async {
        let store = TestStore(initialState: ExploreFeature.State()) {
            ExploreFeature()
        } withDependencies: {
            stubPaging(&$0, pages: [[Self.makePlaylist(1, "歌单一")]], more: [true])
        }
        await store.send(.onAppear) {
            $0.loadState = .loading
        }
        await store.receive(.pageLoaded(.playlists(
            appended: [Self.makePlaylist(1, "歌单一")],
            hasMore: true,
            cursor: ExploreFeature.Cursor(offset: 50, highQualityBefore: 0)
        ))) {
            $0.playlists = [Self.makePlaylist(1, "歌单一")]
            $0.hasMore = true
            $0.offset = 50
            $0.loadState = .loaded
        }
    }

    /// `onAppear` is a load-once guard.
    func testOnAppearIsIdempotentOnceLoaded() async {
        let store = TestStore(initialState: ExploreFeature.State()) {
            ExploreFeature()
        } withDependencies: {
            stubPaging(&$0, pages: [[Self.makePlaylist(1, "歌单一")]], more: [false])
        }
        await store.send(.onAppear) { $0.loadState = .loading }
        await store.receive(.pageLoaded(.playlists(
            appended: [Self.makePlaylist(1, "歌单一")],
            hasMore: false,
            cursor: ExploreFeature.Cursor(offset: 50, highQualityBefore: 0)
        ))) {
            $0.playlists = [Self.makePlaylist(1, "歌单一")]
            $0.hasMore = false
            $0.offset = 50
            $0.loadState = .loaded
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
            $0.loadState = .loading
        }
        await store.receive(.pageLoaded(.toplists(
            [Self.makeToplist(19_723_756, "云音乐飙升榜"), Self.makeToplist(3_779_629, "新歌榜")]
        ))) {
            $0.toplists = [Self.makeToplist(19_723_756, "云音乐飙升榜"), Self.makeToplist(3_779_629, "新歌榜")]
            $0.hasMore = false
            $0.loadState = .loaded
        }
    }

    /// 推荐歌单 is a single page too.
    func testRecommendCategoryIsOnePage() async {
        let store = TestStore(initialState: ExploreFeature.State()) {
            ExploreFeature()
        } withDependencies: {
            $0.netease.personalizedPlaylists = { _ in
                (1...3).map { Self.makePlaylist($0, "推荐\($0)") }
            }
        }
        await store.send(.selectCategory("推荐歌单")) {
            $0.selectedCategory = "推荐歌单"
            $0.hasMore = true
            $0.loadState = .loading
        }
        await store.receive(.pageLoaded(.playlists(
            appended: (1...3).map { Self.makePlaylist($0, "推荐\($0)") },
            hasMore: false,
            cursor: ExploreFeature.Cursor()
        ))) {
            $0.playlists = (1...3).map { Self.makePlaylist($0, "推荐\($0)") }
            $0.hasMore = false
            $0.loadState = .loaded
        }
    }

    /// Selecting the category that is already shown (with data) is a no-op.
    func testSelectingTheSameCategoryIsIgnored() async {
        var state = ExploreFeature.State()
        state.selectedCategory = "华语"
        state.playlists = [Self.makePlaylist(1, "歌单一")]
        state.loadState = .loaded
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
            stubPaging(
                &$0,
                pages: [
                    [Self.makePlaylist(1, "歌单一")],
                    // id 1 is repeated by the API and must be collapsed.
                    [Self.makePlaylist(1, "歌单一"), Self.makePlaylist(2, "歌单二")],
                ],
                more: [true, false])
        }
        await store.send(.onAppear) { $0.loadState = .loading }
        await store.receive(.pageLoaded(.playlists(
            appended: [Self.makePlaylist(1, "歌单一")],
            hasMore: true,
            cursor: ExploreFeature.Cursor(offset: 50, highQualityBefore: 0)
        ))) {
            $0.playlists = [Self.makePlaylist(1, "歌单一")]
            $0.hasMore = true
            $0.offset = 50
            $0.loadState = .loaded
        }
        await store.send(.loadMore) { $0.loadState = .loading }
        await store.receive(.pageLoaded(.playlists(
            appended: [Self.makePlaylist(2, "歌单二")],
            hasMore: false,
            cursor: ExploreFeature.Cursor(offset: 100, highQualityBefore: 0)
        ))) {
            $0.playlists = [Self.makePlaylist(1, "歌单一"), Self.makePlaylist(2, "歌单二")]
            $0.hasMore = false
            $0.offset = 100
            $0.loadState = .loaded
        }
    }

    /// The default category stops paging at the offset cap even if the API
    /// keeps saying there is more.
    func testPagingStopsAtTheOffsetCap() async {
        var state = ExploreFeature.State()
        state.loadState = .loaded
        state.offset = 450
        state.hasMore = true
        let store = TestStore(initialState: state) {
            ExploreFeature()
        } withDependencies: {
            stubPaging(
                &$0,
                pages: [[Self.makePlaylist(9, "第九页")]],
                more: [true])
        }
        await store.send(.loadMore) { $0.loadState = .loading }
        await store.receive(.pageLoaded(.playlists(
            appended: [Self.makePlaylist(9, "第九页")],
            hasMore: false,
            cursor: ExploreFeature.Cursor(offset: 500, highQualityBefore: 0)
        ))) {
            $0.playlists = [Self.makePlaylist(9, "第九页")]
            $0.hasMore = false
            $0.offset = 500
            $0.loadState = .loaded
        }
    }

    /// 精品歌单 pages with the `lasttime` cursor instead of an offset.
    func testHighQualityCategoryPagesByLastTime() async {
        let store = TestStore(initialState: ExploreFeature.State()) {
            ExploreFeature()
        } withDependencies: {
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
            $0.loadState = .loading
        }
        await store.receive(.pageLoaded(.playlists(
            appended: [Self.makePlaylist(1, "精品1")],
            hasMore: true,
            cursor: ExploreFeature.Cursor(offset: 0, highQualityBefore: 1)
        ))) {
            $0.playlists = [Self.makePlaylist(1, "精品1")]
            $0.hasMore = true
            $0.highQualityBefore = 1
            $0.loadState = .loaded
        }
        await store.send(.loadMore) { $0.loadState = .loading }
        await store.receive(.pageLoaded(.playlists(
            appended: [Self.makePlaylist(2, "精品2")],
            hasMore: true,
            cursor: ExploreFeature.Cursor(offset: 0, highQualityBefore: 2)
        ))) {
            $0.playlists = [Self.makePlaylist(1, "精品1"), Self.makePlaylist(2, "精品2")]
            $0.hasMore = true
            $0.highQualityBefore = 2
            $0.loadState = .loaded
        }
    }

    /// A failed fetch settles the category as a single empty page instead of
    /// looping on a retry.
    func testFailedFetchEndsPaging() async {
        let store = TestStore(initialState: ExploreFeature.State()) {
            ExploreFeature()
        } withDependencies: {
            $0.netease.topPlaylists = { _, _, _, _ in throw URLError(.notConnectedToInternet) }
        }
        await store.send(.onAppear) { $0.loadState = .loading }
        await store.receive(.pageLoaded(.playlists(
            appended: [], hasMore: false,
            cursor: ExploreFeature.Cursor()
        ))) {
            $0.hasMore = false
            $0.loadState = .loaded
        }
        // Nothing more to load: a second loadMore is a no-op.
        await store.send(.loadMore)
    }
}
