import ComposableArchitecture
import Dependencies
import Foundation
import KumoneCore
@testable import KumoneTCA
import XCTest

@MainActor
final class HomeFeatureTests: XCTestCase {
    // MARK: - Fixtures

    /// The content models are Decodable-only, so every fixture is built from
    /// the JSON shape the API actually returns.
    nonisolated private static func makePlaylist(_ id: Int, _ name: String) -> PlaylistSummary {
        let json = """
            {"id": \(id), "name": "\(name)", "picUrl": "https://music.example.com/p\(id).jpg", \
            "playCount": 1234, "trackCount": 20}
            """
        return try! JSONDecoder().decode(PlaylistSummary.self, from: Data(json.utf8))
    }

    nonisolated private static func makeAlbum(_ id: Int, _ name: String) -> AlbumSummary {
        let json = """
            {"id": \(id), "name": "\(name)", "picUrl": "https://music.example.com/a\(id).jpg", \
            "artist": {"name": "歌手\\(id)"}, "publishTime": 1700000000000, "size": 10}
            """
        return try! JSONDecoder().decode(AlbumSummary.self, from: Data(json.utf8))
    }

    nonisolated private static func makeArtist(_ id: Int, _ name: String) -> ArtistSummary {
        let json = """
            {"id": \(id), "name": "\(name)", "picUrl": "https://music.example.com/ar\(id).jpg", \
            "albumSize": 5, "musicSize": 40}
            """
        return try! JSONDecoder().decode(ArtistSummary.self, from: Data(json.utf8))
    }

    nonisolated private static func makeToplist(_ id: Int, _ name: String) -> ToplistItem {
        let json = """
            {"id": \(id), "name": "\(name)", "coverImgUrl": "https://music.example.com/t\(id).jpg", \
            "updateFrequency": "每日更新", "playCount": 999, \
            "tracks": [{"first": "歌一", "second": "歌手一"}]}
            """
        return try! JSONDecoder().decode(ToplistItem.self, from: Data(json.utf8))
    }

    nonisolated private static func makeDailyTrack(_ cover: String) -> Track {
        let json = """
            {"id": 777, "name": "每日推荐", "ar": [{"id": 1, "name": "歌手"}], \
            "al": {"id": 2, "name": "专辑", "picUrl": "\(cover)"}, "dt": 180000}
            """
        return try! JSONDecoder().decode(Track.self, from: Data(json.utf8))
    }

    nonisolated private static func makeBrief(
        _ id: Int, _ name: String, _ cover: String
    ) -> NeteaseAPI.PlaylistBrief.Body {
        let json = """
            {"id": \(id), "name": "\(name)", "coverImgUrl": "\(cover)"}
            """
        return try! JSONDecoder().decode(
            NeteaseAPI.PlaylistBrief.Body.self, from: Data(json.utf8)
        )
    }

    // MARK: - Logged out

    /// A logged-out user gets the public sections only.
    func testLoggedOutLoadsPublicSectionsOnly() async {
        let store = TestStore(initialState: HomeFeature.State()) {
            HomeFeature()
        } withDependencies: {
            var provider = MockMusicProvider()
            provider.personalizedPlaylistsHandler = { _ in
                [Self.makePlaylist(1, "个性歌单一"), Self.makePlaylist(2, "个性歌单二")]
            }
            $0.netease.toplists = {
                // Only the featured subset survives the filter.
                [Self.makeToplist(19_723_756, "云音乐飙升榜"), Self.makeToplist(999, "别榜")]
            }
            provider.newAlbumsHandler = { _, _, _ in [Self.makeAlbum(10, "新专辑一")] }
            provider.topArtistsHandler = { _ in [Self.makeArtist(20, "歌手一")] }
            $0.musicProvider = provider
        }
        await store.send(.onAppear) {
            $0.loadState = HomeFeature.State.LoadState.loading
        }
        let sections = HomeFeature.Sections(
            recommendPlaylists: [
                Self.makePlaylist(1, "个性歌单一"), Self.makePlaylist(2, "个性歌单二"),
            ],
            radarPlaylists: [],
            toplists: [Self.makeToplist(19_723_756, "云音乐飙升榜")],
            newAlbums: [Self.makeAlbum(10, "新专辑一")],
            topArtists: [Self.makeArtist(20, "歌手一")],
            dailyFirstCover: nil)
        await store.receive(.loaded(sections)) {
            $0.recommendPlaylists = sections.recommendPlaylists
            $0.toplists = sections.toplists
            $0.newAlbums = [Self.makeAlbum(10, "新专辑一")]
            $0.topArtists = [Self.makeArtist(20, "歌手一")]
            $0.loadState = HomeFeature.State.LoadState.loaded
        }
        XCTAssertFalse(store.state.isLoggedIn)
        XCTAssertTrue(store.state.radarPlaylists.isEmpty)
        XCTAssertNil(store.state.dailyFirstCover)
    }

    // MARK: - Logged in

    /// Logged in: the day-of recommend resource is prepended (deduplicated
    /// against the personalized list), the radar family splits its "原因|家族"
    /// titles, the daily cover is picked off the first recommend song, and a
    /// radar brief that fails is dropped.
    func testLoggedInLoadsRadarAndDailyCover() async {
        var state = HomeFeature.State()
        state.isLoggedIn = true
        let store = TestStore(initialState: state) {
            HomeFeature()
        } withDependencies: {
            var provider = MockMusicProvider()
            provider.recommendResourceHandler = { [Self.makePlaylist(1, "每日歌单")] }
            // id 1 duplicates the head and must be collapsed away.
            provider.personalizedPlaylistsHandler = { _ in
                [Self.makePlaylist(1, "重复歌单"), Self.makePlaylist(2, "个性歌单")]
            }
            $0.netease.toplists = { [] }
            provider.newAlbumsHandler = { _, _, _ in [Self.makeAlbum(10, "新专辑一")] }
            // A single artist keeps the shuffled prefix deterministic.
            provider.topArtistsHandler = { _ in [Self.makeArtist(20, "歌手一")] }
            provider.dailyRecommendSongsHandler = { [Self.makeDailyTrack("https://music.example.com/daily.jpg")] }
            $0.netease.playlistBrief = { id in
                switch id {
                case 3_136_952_023:
                    return Self.makeBrief(id, "今天从《夜曲》听起|私人雷达", "https://music.example.com/r1.jpg")
                case 2_829_883_282:
                    // No separator: the whole name is the title.
                    return Self.makeBrief(id, "华语私人雷达", "https://music.example.com/r2.jpg")
                case 2_829_816_518:
                    return Self.makeBrief(id, "今天从《稻香》听起|欧美私人雷达", "https://music.example.com/r3.jpg")
                default:
                    // The last radar family fails to load and is dropped.
                    throw URLError(.badServerResponse)
                }
            }
            $0.musicProvider = provider
        }
        await store.send(.onAppear) {
            $0.loadState = HomeFeature.State.LoadState.loading
        }
        let sections = HomeFeature.Sections(
            recommendPlaylists: [
                Self.makePlaylist(1, "每日歌单"), Self.makePlaylist(2, "个性歌单"),
            ],
            radarPlaylists: [
                HomeFeature.State.RadarPlaylist(
                    id: 3_136_952_023, title: "私人雷达",
                    subtitle: "今天从《夜曲》听起", coverURL: "https://music.example.com/r1.jpg"),
                HomeFeature.State.RadarPlaylist(
                    id: 2_829_883_282, title: "华语私人雷达",
                    subtitle: nil, coverURL: "https://music.example.com/r2.jpg"),
                HomeFeature.State.RadarPlaylist(
                    id: 2_829_816_518, title: "欧美私人雷达",
                    subtitle: "今天从《稻香》听起", coverURL: "https://music.example.com/r3.jpg"),
            ],
            toplists: [],
            newAlbums: [Self.makeAlbum(10, "新专辑一")],
            topArtists: [Self.makeArtist(20, "歌手一")],
            dailyFirstCover: "https://music.example.com/daily.jpg")
        await store.receive(.loaded(sections)) {
            $0.recommendPlaylists = sections.recommendPlaylists
            $0.radarPlaylists = sections.radarPlaylists
            $0.newAlbums = sections.newAlbums
            $0.topArtists = sections.topArtists
            $0.dailyFirstCover = sections.dailyFirstCover
            $0.loadState = HomeFeature.State.LoadState.loaded
        }
    }

    // MARK: - Failure surface

    /// Both discovery anchors empty is how the page reports a broken network.
    func testEmptySectionsReportNetworkError() async {
        let store = TestStore(initialState: HomeFeature.State()) {
            HomeFeature()
        } withDependencies: {
            var provider = MockMusicProvider()
            provider.personalizedPlaylistsHandler = { _ in [] }
            $0.netease.toplists = { [Self.makeToplist(19_723_756, "云音乐飙升榜")] }
            provider.newAlbumsHandler = { _, _, _ in [] }
            provider.topArtistsHandler = { _ in [] }
            $0.musicProvider = provider
        }
        await store.send(.onAppear) {
            $0.loadState = HomeFeature.State.LoadState.loading
        }
        let sections = HomeFeature.Sections(
            recommendPlaylists: [], radarPlaylists: [],
            toplists: [Self.makeToplist(19_723_756, "云音乐飙升榜")],
            newAlbums: [], topArtists: [], dailyFirstCover: nil)
        await store.receive(.loaded(sections)) {
            $0.toplists = sections.toplists
            $0.loadState = HomeFeature.State.LoadState.error(String(localized: "网络连接失败"))
        }
        XCTAssertEqual(store.state.loadState, .error(String(localized: "网络连接失败")))
    }

    // MARK: - Reload semantics

    /// `onAppear` is a load-once guard: a second arrival does nothing.
    func testOnAppearIsIdempotentOnceLoaded() async {
        let store = TestStore(initialState: HomeFeature.State()) {
            HomeFeature()
        } withDependencies: {
            var provider = MockMusicProvider()
            provider.personalizedPlaylistsHandler = { _ in [Self.makePlaylist(1, "个性歌单一")] }
            $0.netease.toplists = { [] }
            provider.newAlbumsHandler = { _, _, _ in [Self.makeAlbum(10, "新专辑一")] }
            provider.topArtistsHandler = { _ in [] }
            $0.musicProvider = provider
        }
        await store.send(.onAppear) { $0.loadState = HomeFeature.State.LoadState.loading }
        let sections = HomeFeature.Sections(
            recommendPlaylists: [Self.makePlaylist(1, "个性歌单一")],
            radarPlaylists: [], toplists: [],
            newAlbums: [Self.makeAlbum(10, "新专辑一")],
            topArtists: [], dailyFirstCover: nil)
        await store.receive(.loaded(sections)) {
            $0.recommendPlaylists = sections.recommendPlaylists
            $0.newAlbums = sections.newAlbums
            $0.loadState = HomeFeature.State.LoadState.loaded
        }
        // Already loaded: no state change, no new effect.
        await store.send(.onAppear)
    }

    /// `reload` bypasses the guard and re-fetches (pull to refresh, or a login
    /// state change).
    func testReloadRefetchesEverything() async {
        var state = HomeFeature.State()
        state.isLoggedIn = true
        state.loadState = HomeFeature.State.LoadState.loaded
        state.recommendPlaylists = [Self.makePlaylist(1, "旧歌单")]
        let store = TestStore(initialState: state) {
            HomeFeature()
        } withDependencies: {
            var provider = MockMusicProvider()
            provider.personalizedPlaylistsHandler = { _ in [Self.makePlaylist(2, "新歌单")] }
            provider.recommendResourceHandler = { [] }
            $0.netease.toplists = { [] }
            provider.newAlbumsHandler = { _, _, _ in [] }
            provider.topArtistsHandler = { _ in [] }
            provider.dailyRecommendSongsHandler = { [] }
            $0.netease.playlistBrief = { _ in Self.makeBrief(0, "雷达歌单", "https://music.example.com/x.jpg") }
            $0.musicProvider = provider
        }
        await store.send(.reload) { $0.loadState = HomeFeature.State.LoadState.loading }
        let sections = HomeFeature.Sections(
            recommendPlaylists: [Self.makePlaylist(2, "新歌单")],
            radarPlaylists: HomeFeature.radarPlaylistIDs.map {
                HomeFeature.State.RadarPlaylist(
                    id: $0, title: "雷达歌单",
                    subtitle: nil, coverURL: "https://music.example.com/x.jpg")
            },
            toplists: [], newAlbums: [], topArtists: [], dailyFirstCover: nil)
        await store.receive(.loaded(sections)) {
            $0.recommendPlaylists = sections.recommendPlaylists
            $0.radarPlaylists = sections.radarPlaylists
            $0.loadState = HomeFeature.State.LoadState.loaded
        }
        XCTAssertEqual(store.state.radarPlaylists.count, 4)
    }

    func testPlaylistPlaybackUsesEmbeddedTracks() async throws {
        let detail = try JSONDecoder().decode(NeteaseAPI.PlaylistDetailResponse.self, from: Data(
            #"{"playlist":{"id":42,"name":"播放歌单","tracks":[{"id":7,"name":"歌曲","ar":[],"al":{"id":2,"name":"专辑"},"dt":1000}],"trackIds":[{"id":99}]}}"#.utf8))
        XCTAssertEqual(detail.playlist.tracks.count, 1)
        let store = TestStore(initialState: HomeFeature.State()) {
            HomeFeature()
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
        let store = TestStore(initialState: HomeFeature.State()) {
            HomeFeature()
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
        let store = TestStore(initialState: HomeFeature.State()) {
            HomeFeature()
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
        let store = TestStore(initialState: HomeFeature.State()) {
            HomeFeature()
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

    func testAlbumPlaybackDelegatesSongsAndSelectedAlbumContext() async throws {
        let album = try JSONDecoder().decode(
            AlbumSummary.self, from: Data(#"{"id":42,"name":"选中专辑"}"#.utf8))
        let detail = try JSONDecoder().decode(AlbumDetailResponse.self, from: Data(
            #"{"album":{"id":42,"name":"详情名称"},"songs":[{"id":7,"name":"歌曲","ar":[],"al":{"id":42,"name":"专辑"},"dt":1000}]}"#.utf8))
        let store = TestStore(initialState: HomeFeature.State()) {
            HomeFeature()
        } withDependencies: {
            $0.netease.album = { id in
                XCTAssertEqual(id, 42)
                return detail
            }
        }
        await store.send(.playAlbum(album))
        await store.receive(.delegate(.play(
            tracks: detail.songs, source: .album(42),
            context: .album(id: 42, name: "选中专辑"))))
        await store.finish()
    }

    func testAlbumPlaybackFailureProducesNoDelegate() async throws {
        let album = try JSONDecoder().decode(
            AlbumSummary.self, from: Data(#"{"id":42,"name":"选中专辑"}"#.utf8))
        let store = TestStore(initialState: HomeFeature.State()) {
            HomeFeature()
        } withDependencies: {
            $0.netease.album = { id in
                XCTAssertEqual(id, 42)
                throw URLError(.badServerResponse)
            }
        }
        await store.send(.playAlbum(album))
        await store.finish()
    }

    func testHeartbeatDelegatesWithoutChangingHomeState() async {
        let store = TestStore(initialState: HomeFeature.State()) { HomeFeature() }
        await store.send(.startHeartbeat)
        await store.receive(.delegate(.startHeartbeat))
        await store.finish()
    }

    func testLoggedInLoadDeduplicatesRecommendationsCapsArtistsAndHandlesRadarNames() async throws {
        let head = Self.makePlaylist(1, "每日优先")
        let duplicate = Self.makePlaylist(1, "忽略重复")
        let tail = Self.makePlaylist(2, "个性推荐")
        let album = try JSONDecoder().decode(
            AlbumSummary.self, from: Data(#"{"id":10,"name":"新专辑"}"#.utf8))
        let artist = Self.makeArtist(20, "歌手")
        var state = HomeFeature.State()
        state.isLoggedIn = true
        let store = TestStore(initialState: state) {
            HomeFeature()
        } withDependencies: {
            var provider = MockMusicProvider()
            provider.recommendResourceHandler = { [head, head] }
            provider.personalizedPlaylistsHandler = { limit in
                XCTAssertEqual(limit, 30)
                return [duplicate, tail, tail]
            }
            provider.newAlbumsHandler = { area, limit, offset in
                XCTAssertEqual(area, "ALL")
                XCTAssertEqual(limit, 20)
                XCTAssertEqual(offset, 0)
                return [album]
            }
            provider.topArtistsHandler = { limit in
                XCTAssertEqual(limit, 100)
                // Identical entries make shuffle deterministic while exercising the cap.
                return Array(repeating: artist, count: 7)
            }
            provider.dailyRecommendSongsHandler = { [] }
            $0.musicProvider = provider
            $0.netease.toplists = { throw URLError(.badServerResponse) }
            $0.netease.playlistBrief = { id in
                switch id {
                case 3_136_952_023:
                    return Self.makeBrief(id, "第一段|第二段|私人雷达", "https://music.example.com/r1.jpg")
                case 2_829_883_282:
                    return try JSONDecoder().decode(
                        NeteaseAPI.PlaylistBrief.Body.self, from: Data(#"{"id":2829883282}"#.utf8))
                case 2_829_816_518:
                    return Self.makeBrief(id, "", "https://music.example.com/r3.jpg")
                default:
                    throw URLError(.badServerResponse)
                }
            }
        }
        let sections = HomeFeature.Sections(
            recommendPlaylists: [head, tail],
            radarPlaylists: [
                HomeFeature.State.RadarPlaylist(
                    id: 3_136_952_023, title: "私人雷达", subtitle: "第一段|第二段",
                    coverURL: "https://music.example.com/r1.jpg"),
                HomeFeature.State.RadarPlaylist(
                    id: 2_829_883_282, title: String(localized: "雷达歌单"), subtitle: nil, coverURL: nil),
                HomeFeature.State.RadarPlaylist(
                    id: 2_829_816_518, title: "", subtitle: nil,
                    coverURL: "https://music.example.com/r3.jpg")
            ],
            toplists: [], newAlbums: [album],
            topArtists: Array(repeating: artist, count: 6), dailyFirstCover: nil)
        await store.send(.onAppear) { $0.loadState = .loading }
        await store.receive(.loaded(sections)) {
            $0.recommendPlaylists = sections.recommendPlaylists
            $0.radarPlaylists = sections.radarPlaylists
            $0.newAlbums = sections.newAlbums
            $0.topArtists = sections.topArtists
            $0.loadState = .loaded
        }
        await store.finish()
    }

    func testAllDiscoveryFailuresSettleForLoggedInAndLoggedOutUsers() async {
        for loggedIn in [false, true] {
            var state = HomeFeature.State()
            state.isLoggedIn = loggedIn
            let store = TestStore(initialState: state) {
                HomeFeature()
            } withDependencies: {
                var provider = MockMusicProvider()
                provider.personalizedPlaylistsHandler = { limit in
                    XCTAssertEqual(limit, 30)
                    throw URLError(.notConnectedToInternet)
                }
                provider.recommendResourceHandler = {
                    XCTAssertTrue(loggedIn)
                    throw URLError(.notConnectedToInternet)
                }
                provider.newAlbumsHandler = { _, _, _ in throw URLError(.notConnectedToInternet) }
                provider.topArtistsHandler = { _ in throw URLError(.notConnectedToInternet) }
                provider.dailyRecommendSongsHandler = {
                    XCTAssertTrue(loggedIn)
                    throw URLError(.notConnectedToInternet)
                }
                $0.musicProvider = provider
                $0.netease.toplists = { throw URLError(.notConnectedToInternet) }
                $0.netease.playlistBrief = { _ in
                    XCTAssertTrue(loggedIn)
                    throw URLError(.notConnectedToInternet)
                }
            }
            await store.send(.onAppear) { $0.loadState = .loading }
            await store.receive(.loaded(HomeFeature.Sections(
                recommendPlaylists: [], radarPlaylists: [], toplists: [],
                newAlbums: [], topArtists: [], dailyFirstCover: nil))) {
                $0.loadState = .error(String(localized: "网络连接失败"))
            }
            await store.finish()
        }
    }
}
