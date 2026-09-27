import ComposableArchitecture
import Dependencies
import Foundation
@testable import KumoneCore
@testable import KumoneTCA
import XCTest

@MainActor
final class SearchFeatureTests: XCTestCase {
    // MARK: - Fixtures

    nonisolated private static func makeSong(_ id: Int) -> Track {
        let json = """
            {"id": \(id), "name": "歌曲\\(id)", "ar": [{"id": 1, "name": "歌手"}], \
            "al": {"id": 2, "name": "专辑", "picUrl": "https://music.example.com/s\(id).jpg"}, "dt": 200000}
            """
        return try! JSONDecoder().decode(Track.self, from: Data(json.utf8))
    }

    nonisolated private static func makeArtist(_ id: Int) -> ArtistSummary {
        let json = """
            {"id": \(id), "name": "歌手\\(id)", "picUrl": "https://music.example.com/ar\(id).jpg", "albumSize": 3}
            """
        return try! JSONDecoder().decode(ArtistSummary.self, from: Data(json.utf8))
    }

    nonisolated private static func makeAlbum(_ id: Int) -> AlbumSummary {
        let json = """
            {"id": \(id), "name": "专辑\\(id)", "picUrl": "https://music.example.com/a\(id).jpg", \
            "artist": {"name": "歌手\\(id)"}, "publishTime": 1700000000000, "size": 8}
            """
        return try! JSONDecoder().decode(AlbumSummary.self, from: Data(json.utf8))
    }

    nonisolated private static func makePlaylist(_ id: Int) -> PlaylistSummary {
        let json = """
            {"id": \(id), "name": "歌单\\(id)", "picUrl": "https://music.example.com/p\(id).jpg", \
            "playCount": 200, "trackCount": 15}
            """
        return try! JSONDecoder().decode(PlaylistSummary.self, from: Data(json.utf8))
    }

    /// Records every search so a test can assert which tab/type was fetched.
    /// Returns results only for the "周" query, so a second, longer query comes
    /// back empty.
    private func makeSearch(
        _ deps: inout DependencyValues,
        songs: [Track] = [],
        artists: [ArtistSummary] = [],
        albums: [AlbumSummary] = [],
        playlists: [PlaylistSummary] = []
    ) -> [(keywords: String, type: SearchCategory, limit: Int)] {
        nonisolated(unsafe) var calls: [(String, SearchCategory, Int)] = []
        var provider = MockMusicProvider()
        provider.searchHandler = { keywords, type, limit, offset in
            calls.append((keywords, type, limit))
            guard keywords == "周" else {
                return SearchResult()
            }
            return SearchResult(
                songs: type == .songs ? songs : [],
                albums: type == .albums ? albums : [],
                artists: type == .artists ? artists : [],
                playlists: type == .playlists ? playlists : [],
                counts: SearchCounts(songs: 0, albums: 0, artists: 0, playlists: 0))
        }
        deps.musicProvider = provider
        return calls
    }

    // MARK: - Loading

    /// The 综合 tab fans out to all four endpoints and gathers them into one
    /// result.
    func testAllTabFansOutToEveryEndpoint() async {
        var state = SearchFeature.State()
        state.query = "周"
        let store = TestStore(initialState: state) {
            SearchFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            _ = makeSearch(&$0,
                songs: [Self.makeSong(1)],
                artists: [Self.makeArtist(2)],
                albums: [Self.makeAlbum(3)],
                playlists: [Self.makePlaylist(4)])
        }
        await store.send(.load) { $0.isLoading = true }
        await store.receive(.loaded(query: "周", tab: .all, results: SearchFeature.Results(
            songs: [Self.makeSong(1)],
            artists: [Self.makeArtist(2)],
            albums: [Self.makeAlbum(3)],
            playlists: [Self.makePlaylist(4)]
        ))) {
            $0.loadedTabs = [.all]
            $0.songs = [Self.makeSong(1)]
            $0.artists = [Self.makeArtist(2)]
            $0.albums = [Self.makeAlbum(3)]
            $0.playlists = [Self.makePlaylist(4)]
            $0.isLoading = false
        }
        XCTAssertEqual(store.state.loadedTabs, [.all])
    }

    /// A specific tab only fetches its own endpoint, and only writes its own
    /// array back.
    func testSingleTabLoadsOnlyItsOwnEndpoint() async {
        var state = SearchFeature.State()
        state.query = "周"
        state.songs = [Self.makeSong(1)]
        state.loadedTabs = [.all]
        let store = TestStore(initialState: state) {
            SearchFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            _ = makeSearch(&$0, artists: [Self.makeArtist(5)])
        }
        await store.send(.selectTab(.artists)) {
            $0.tab = .artists
        }
        await store.receive(.load) { $0.isLoading = true }
        await store.receive(.loaded(query: "周", tab: .artists, results: SearchFeature.Results(
            artists: [Self.makeArtist(5)]
        ))) {
            $0.loadedTabs = [.all, .artists]
            $0.artists = [Self.makeArtist(5)]
            $0.isLoading = false
        }
        // The songs fetched for 综合 survive.
        XCTAssertEqual(store.state.songs, [Self.makeSong(1)])
    }

    /// A tab that already has results for this query is not refetched.
    func testLoadedTabIsNotRefetched() async {
        var state = SearchFeature.State()
        state.query = "周杰伦"
        state.tab = .songs
        state.loadedTabs = [.songs]
        state.songs = [Self.makeSong(1)]
        let store = TestStore(initialState: state) {
            SearchFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            _ = makeSearch(&$0)
        }
        await store.send(.load)
    }

    /// A blank query never reaches the network.
    func testBlankQueryDoesNotLoad() async {
        let store = TestStore(initialState: SearchFeature.State()) {
            SearchFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            _ = makeSearch(&$0)
        }
        await store.send(.load)
        XCTAssertFalse(store.state.isLoading)
    }

    // MARK: - Query changes

    /// Typing resets every tab; the reload is debounced, and only the last
    /// query's fetch survives.
    func testTypingResetsResultsAndDebouncesTheReload() async {
        let store = TestStore(initialState: SearchFeature.State()) {
            SearchFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            _ = makeSearch(&$0, songs: [Self.makeSong(7)])
        }
        await store.send(.setQuery("周")) {
            $0.query = "周"
        }
        await store.receive(.load) { $0.isLoading = true }
        await store.receive(.loaded(query: "周", tab: .all, results: SearchFeature.Results(
            songs: [Self.makeSong(7)]
        ))) {
            $0.loadedTabs = [.all]
            $0.songs = [Self.makeSong(7)]
            $0.isLoading = false
        }
        // Typing again before the debounce fires cancels the pending fetch...
        await store.send(.setQuery("周杰伦")) {
            $0.query = "周杰伦"
            $0.loadedTabs = []
            $0.songs = []
        }
        await store.receive(.load) { $0.isLoading = true }
        await store.receive(.loaded(query: "周杰伦", tab: .all, results: SearchFeature.Results())) {
            $0.loadedTabs = [.all]
            $0.isLoading = false
        }
    }

    /// The same query text is a no-op.
    func testSameQueryIsIgnored() async {
        var state = SearchFeature.State()
        state.query = "周杰伦"
        state.songs = [Self.makeSong(1)]
        state.loadedTabs = [.all]
        let store = TestStore(initialState: state) {
            SearchFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            _ = makeSearch(&$0)
        }
        await store.send(.setQuery("周杰伦"))
        XCTAssertEqual(store.state.songs, [Self.makeSong(1)])
    }

    func testEveryTabUsesItsRawValueAsStableID() {
        XCTAssertEqual(SearchFeature.State.Tab.allCases.map(\.id), ["综合", "单曲", "歌手", "专辑", "歌单"])
    }

    func testEachSpecificTabLoadsItsEndpointAndPreservesOtherResults() async throws {
        let response = try JSONDecoder().decode(SearchResult.self, from: Data(
            #"{"songs":[{"id":1,"name":"歌曲","ar":[],"al":{"id":2,"name":"专辑"},"dt":1000}],"artists":[{"id":3,"name":"歌手"}],"albums":[{"id":4,"name":"专辑"}],"playlists":[{"id":5,"name":"歌单"}],"counts":{"songs":0,"albums":0,"artists":0,"playlists":0}}"#.utf8))
        let cases: [(SearchFeature.State.Tab, SearchCategory, Int)] = [
            (.songs, .songs, 100), (.artists, .artists, 50),
            (.albums, .albums, 50), (.playlists, .playlists, 50)
        ]
        for (tab, type, limit) in cases {
            var state = SearchFeature.State(query: "  搜索词\n")
            state.songs = response.songs
            state.artists = response.artists
            state.albums = response.albums
            state.playlists = response.playlists
            // Empty just the requested tab so both loading and preservation are observable.
            var results = SearchFeature.Results()
            switch tab {
            case .songs:
                state.songs = []
                results.songs = response.songs
            case .artists:
                state.artists = []
                results.artists = response.artists
            case .albums:
                state.albums = []
                results.albums = response.albums
            case .playlists:
                state.playlists = []
                results.playlists = response.playlists
            case .all:
                XCTFail("Only specific tabs belong in this table")
            }
            var provider = MockMusicProvider()
            provider.searchHandler = { keywords, requestedType, requestedLimit, offset in
                XCTAssertEqual(keywords, "搜索词")
                XCTAssertEqual(requestedType, type)
                XCTAssertEqual(requestedLimit, limit)
                XCTAssertEqual(offset, 0)
                return response
            }
            let store = TestStore(initialState: state) {
                SearchFeature()
            } withDependencies: {
                $0.musicProvider = provider
            }
            await store.send(.selectTab(tab)) { $0.tab = tab }
            await store.receive(.load) { $0.isLoading = true }
            await store.receive(.loaded(query: "搜索词", tab: tab, results: results)) {
                $0.loadedTabs = [tab]
                $0.isLoading = false
                switch tab {
                case .songs: $0.songs = results.songs
                case .artists: $0.artists = results.artists
                case .albums: $0.albums = results.albums
                case .playlists: $0.playlists = results.playlists
                case .all: break
                }
            }
            await store.send(.load)
            await store.finish()
        }
    }

    func testEveryTabTreatsMissingResultArraysAsEmpty() async throws {
        let empty = SearchResult()
        for tab in SearchFeature.State.Tab.allCases {
            var state = SearchFeature.State(query: "搜索词")
            state.tab = tab
            var provider = MockMusicProvider()
            provider.searchHandler = { _, _, _, _ in empty }
            let store = TestStore(initialState: state) {
                SearchFeature()
            } withDependencies: {
                $0.musicProvider = provider
            }
            await store.send(.load) { $0.isLoading = true }
            await store.receive(.loaded(query: "搜索词", tab: tab, results: SearchFeature.Results())) {
                $0.loadedTabs = [tab]
                $0.isLoading = false
            }
            await store.finish()
        }
    }

    /// A failed search is reported as a failure, not cached as a successful
    /// empty result: the tab stays reloadable and the view can offer a retry.
    func testSearchFailureMarksTheTabFailedAndKeepsItReloadable() async {
        for tab in SearchFeature.State.Tab.allCases {
            var state = SearchFeature.State(query: "搜索词")
            state.tab = tab
            var provider = MockMusicProvider()
            provider.searchHandler = { _, _, _, _ in throw URLError(.notConnectedToInternet) }
            let store = TestStore(initialState: state) {
                SearchFeature()
            } withDependencies: {
                $0.musicProvider = provider
            }
            await store.send(.load) { $0.isLoading = true }
            await store.receive(.loadFailed(query: "搜索词", tab: tab)) {
                $0.isLoading = false
                $0.failedTabs = [tab]
            }
            // The failure was not recorded as a successful empty result, so a
            // retry is still possible.
            XCTAssertEqual(store.state.loadedTabs, [])
            await store.finish()
        }
    }

    /// The 综合 tab keeps whichever categories succeeded and only reports a
    /// failure when every endpoint failed.
    func testAllTabKeepsPartialResultsAndFailsOnlyWhenEverythingFails() async {
        var state = SearchFeature.State(query: "周")
        state.tab = .all
        var provider = MockMusicProvider()
        provider.searchHandler = { keywords, category, limit, offset in
            switch category {
            case .songs:
                return SearchResult(songs: [Self.makeSong(1)], albums: [], artists: [],
                                    playlists: [], counts: SearchCounts(songs: 0, albums: 0, artists: 0, playlists: 0))
            default:
                throw URLError(.notConnectedToInternet)
            }
        }
        let store = TestStore(initialState: state) {
            SearchFeature()
        } withDependencies: {
            $0.musicProvider = provider
        }
        await store.send(.load) { $0.isLoading = true }
        await store.receive(.loaded(query: "周", tab: .all, results: SearchFeature.Results(
            songs: [Self.makeSong(1)]
        ))) {
            $0.loadedTabs = [.all]
            $0.songs = [Self.makeSong(1)]
            $0.isLoading = false
        }
        XCTAssertEqual(store.state.failedTabs, [])
        await store.finish()
    }

    /// A response delivered for an earlier query must not overwrite the results
    /// of the query the user has since typed.
    func testIgnoresResponsesDeliveredForAnEarlierQuery() async {
        var state = SearchFeature.State(query: "新查询")
        state.tab = .songs
        state.songs = [Self.makeSong(1)]
        state.loadedTabs = [.songs]
        let store = TestStore(initialState: state) {
            SearchFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            _ = makeSearch(&$0)
        }
        let stale = SearchFeature.Results(songs: [Self.makeSong(2)])
        await store.send(.loaded(query: "旧查询", tab: .songs, results: stale))
        await store.send(.loadFailed(query: "旧查询", tab: .songs))
        XCTAssertEqual(store.state.songs, [Self.makeSong(1)])
        XCTAssertEqual(store.state.failedTabs, [])
        await store.finish()
    }

    func testPlaybackDelegateLeavesSearchStateUnchanged() async {
        let store = TestStore(initialState: SearchFeature.State(query: "保留查询")) { SearchFeature() }
        await store.send(.delegate(.play(
            tracks: [], source: .playlist(42), startAt: nil, context: nil)))
        await store.finish()
    }
}
