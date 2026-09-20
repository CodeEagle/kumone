import ComposableArchitecture
import Dependencies
@testable import KumoneCore
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
    ) -> [(keywords: String, type: NeteaseAPI.SearchType, limit: Int)] {
        nonisolated(unsafe) var calls: [(String, NeteaseAPI.SearchType, Int)] = []
        deps.netease.search = { keywords, type, limit, _ in
            calls.append((keywords, type, limit))
            guard keywords == "周" else {
                return NeteaseAPI.SearchResult(
                    songs: nil, albums: nil, artists: nil, playlists: nil,
                    songCount: nil, albumCount: nil, artistCount: nil, playlistCount: nil)
            }
            return NeteaseAPI.SearchResult(
                songs: type == .songs ? songs : nil,
                albums: type == .albums ? albums : nil,
                artists: type == .artists ? artists : nil,
                playlists: type == .playlists ? playlists : nil,
                songCount: nil, albumCount: nil, artistCount: nil, playlistCount: nil)
        }
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
        await store.receive(.loaded(tab: .all, results: SearchFeature.Results(
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
        await store.receive(.loaded(tab: .artists, results: SearchFeature.Results(
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
        await store.receive(.loaded(tab: .all, results: SearchFeature.Results(
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
        await store.receive(.loaded(tab: .all, results: SearchFeature.Results())) {
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
}
