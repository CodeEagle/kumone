import ComposableArchitecture
import Dependencies
@testable import KumoneCore
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

    /// A logged-out user gets the public sections only: the radar and daily
    /// rows must not even be requested (those endpoints are left unimplemented,
    /// so a call traps the test).
    func testLoggedOutLoadsPublicSectionsOnly() async {
        let store = TestStore(initialState: HomeFeature.State()) {
            HomeFeature()
        } withDependencies: {
            $0.netease.personalizedPlaylists = { _ in
                [Self.makePlaylist(1, "个性歌单一"), Self.makePlaylist(2, "个性歌单二")]
            }
            $0.netease.toplists = {
                // Only the featured subset survives the filter.
                [Self.makeToplist(19_723_756, "云音乐飙升榜"), Self.makeToplist(999, "别榜")]
            }
            $0.netease.newAlbums = { _, _, _ in [Self.makeAlbum(10, "新专辑一")] }
            $0.netease.topArtists = { _ in [Self.makeArtist(20, "歌手一")] }
        }
        await store.send(.onAppear) {
            $0.loadState = .loading
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
            $0.loadState = .loaded
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
            $0.netease.recommendResource = { [Self.makePlaylist(1, "每日歌单")] }
            // id 1 duplicates the head and must be collapsed away.
            $0.netease.personalizedPlaylists = { _ in
                [Self.makePlaylist(1, "重复歌单"), Self.makePlaylist(2, "个性歌单")]
            }
            $0.netease.toplists = { [] }
            $0.netease.newAlbums = { _, _, _ in [Self.makeAlbum(10, "新专辑一")] }
            // A single artist keeps the shuffled prefix deterministic.
            $0.netease.topArtists = { _ in [Self.makeArtist(20, "歌手一")] }
            $0.netease.dailyRecommendSongs = { [Self.makeDailyTrack("https://music.example.com/daily.jpg")] }
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
        }
        await store.send(.onAppear) {
            $0.loadState = .loading
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
            $0.loadState = .loaded
        }
    }

    // MARK: - Failure surface

    /// Both discovery anchors empty is how the page reports a broken network.
    func testEmptySectionsReportNetworkError() async {
        let store = TestStore(initialState: HomeFeature.State()) {
            HomeFeature()
        } withDependencies: {
            $0.netease.personalizedPlaylists = { _ in [] }
            $0.netease.toplists = { [Self.makeToplist(19_723_756, "云音乐飙升榜")] }
            $0.netease.newAlbums = { _, _, _ in [] }
            $0.netease.topArtists = { _ in [] }
        }
        await store.send(.onAppear) {
            $0.loadState = .loading
        }
        let sections = HomeFeature.Sections(
            recommendPlaylists: [], radarPlaylists: [],
            toplists: [Self.makeToplist(19_723_756, "云音乐飙升榜")],
            newAlbums: [], topArtists: [], dailyFirstCover: nil)
        await store.receive(.loaded(sections)) {
            $0.toplists = sections.toplists
            $0.loadState = .error(String(localized: "网络连接失败"))
        }
        XCTAssertEqual(store.state.loadState, .error(String(localized: "网络连接失败")))
    }

    // MARK: - Reload semantics

    /// `onAppear` is a load-once guard: a second arrival does nothing.
    func testOnAppearIsIdempotentOnceLoaded() async {
        let store = TestStore(initialState: HomeFeature.State()) {
            HomeFeature()
        } withDependencies: {
            $0.netease.personalizedPlaylists = { _ in [Self.makePlaylist(1, "个性歌单一")] }
            $0.netease.toplists = { [] }
            $0.netease.newAlbums = { _, _, _ in [Self.makeAlbum(10, "新专辑一")] }
            $0.netease.topArtists = { _ in [] }
        }
        await store.send(.onAppear) { $0.loadState = .loading }
        let sections = HomeFeature.Sections(
            recommendPlaylists: [Self.makePlaylist(1, "个性歌单一")],
            radarPlaylists: [], toplists: [],
            newAlbums: [Self.makeAlbum(10, "新专辑一")],
            topArtists: [], dailyFirstCover: nil)
        await store.receive(.loaded(sections)) {
            $0.recommendPlaylists = sections.recommendPlaylists
            $0.newAlbums = sections.newAlbums
            $0.loadState = .loaded
        }
        // Already loaded: no state change, no new effect.
        await store.send(.onAppear)
    }

    /// `reload` bypasses the guard and re-fetches (pull to refresh, or a login
    /// state change).
    func testReloadRefetchesEverything() async {
        var state = HomeFeature.State()
        state.isLoggedIn = true
        state.loadState = .loaded
        state.recommendPlaylists = [Self.makePlaylist(1, "旧歌单")]
        let store = TestStore(initialState: state) {
            HomeFeature()
        } withDependencies: {
            $0.netease.personalizedPlaylists = { _ in [Self.makePlaylist(2, "新歌单")] }
            $0.netease.recommendResource = { [] }
            $0.netease.toplists = { [] }
            $0.netease.newAlbums = { _, _, _ in [] }
            $0.netease.topArtists = { _ in [] }
            $0.netease.dailyRecommendSongs = { [] }
            $0.netease.playlistBrief = { _ in Self.makeBrief(0, "雷达歌单", "https://music.example.com/x.jpg") }
        }
        await store.send(.reload) { $0.loadState = .loading }
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
            $0.loadState = .loaded
        }
        XCTAssertEqual(store.state.radarPlaylists.count, 4)
    }
}
