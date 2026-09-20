import ComposableArchitecture
import Dependencies
@testable import KumoneCore
import XCTest

@MainActor
final class AlbumDetailFeatureTests: XCTestCase {
    // MARK: - Fixtures

    nonisolated private static func makeSong(_ id: Int) -> Track {
        let json = """
            {"id": \(id), "name": "歌曲\(id)", "ar": [{"id": 1, "name": "歌手"}], \
            "al": {"id": 2, "name": "专辑\(id)"}, "dt": 100000}
            """
        return try! JSONDecoder().decode(Track.self, from: Data(json.utf8))
    }

    nonisolated private static func makeAlbum(
        _ id: Int, artistID: Int = 5, size: Int = 10
    ) -> AlbumDetail {
        let json = """
            {"id": \(id), "name": "专辑\(id)", "picUrl": "https://music.example.com/a\(id).jpg", \
            "artist": {"id": \(artistID), "name": "歌手", "picUrl": "https://music.example.com/ar.jpg", \
            "albumSize": 3, "musicSize": 9, "alias": [], "followed": false}, \
            "publishTime": 1700000000000, "description": "专辑简介", "company": "厂牌", "size": \(size), \
            "subType": "专辑"}
            """
        return try! JSONDecoder().decode(AlbumDetail.self, from: Data(json.utf8))
    }

    nonisolated private static func makeAlbumSummary(_ id: Int, _ size: Int) -> AlbumSummary {
        let json = """
            {"id": \(id), "name": "其他专辑\(id)", "picUrl": "https://music.example.com/o\(id).jpg", \
            "artist": {"name": "歌手"}, "publishTime": 1700000000000, "size": \(size)}
            """
        return try! JSONDecoder().decode(AlbumSummary.self, from: Data(json.utf8))
    }

    // MARK: - Loading

    /// The album lands first, then the collection state, then the artist's
    /// other releases (with this album itself filtered out).
    func testLoadsAlbumThenDynamicThenOtherAlbums() async {
        let store = TestStore(initialState: AlbumDetailFeature.State(albumID: 1)) {
            AlbumDetailFeature()
        } withDependencies: {
            $0.netease.album = { _ in
                AlbumDetailResponse(album: Self.makeAlbum(1), songs: [Self.makeSong(10), Self.makeSong(11)])
            }
            $0.netease.albumDynamic = { _ in
                NeteaseAPI.AlbumDynamicResponse(isSub: true, subCount: 1)
            }
            $0.netease.artistAlbums = { artistID, _, _ in
                XCTAssertEqual(artistID, 5)
                return NeteaseAPI.ArtistAlbumsResponse(
                    hotAlbums: [Self.makeAlbumSummary(1, 10), Self.makeAlbumSummary(2, 8)], more: false)
            }
        }
        await store.send(.onAppear) { $0.loadState = .loading }
        await store.receive(.albumResponse(
            album: Self.makeAlbum(1), songs: [Self.makeSong(10), Self.makeSong(11)]
        )) {
            $0.album = Self.makeAlbum(1)
            $0.tracks = [Self.makeSong(10), Self.makeSong(11)]
            $0.loadState = .loaded
        }
        await store.receive(.dynamicResponse(isSubscribed: true)) {
            $0.isSubscribed = true
        }
        await store.receive(.otherAlbumsResponse([
            Self.makeAlbumSummary(1, 10), Self.makeAlbumSummary(2, 8),
        ])) {
            // The album being viewed is not listed among its own siblings.
            $0.otherAlbums = [Self.makeAlbumSummary(2, 8)]
        }
    }

    func testFailedLoadSurfacesError() async {
        let error = URLError(.badServerResponse)
        let store = TestStore(initialState: AlbumDetailFeature.State(albumID: 1)) {
            AlbumDetailFeature()
        } withDependencies: {
            $0.netease.album = { _ in throw error }
        }
        await store.send(.onAppear) { $0.loadState = .loading }
        await store.receive(.loadFailed(error.localizedDescription)) {
            $0.loadState = .error(error.localizedDescription)
        }
    }

    // MARK: - Play

    func testPlayAllHandsTheSongsToThePlayer() async {
        var state = AlbumDetailFeature.State(albumID: 1)
        state.album = Self.makeAlbum(1)
        state.tracks = [Self.makeSong(10), Self.makeSong(11)]
        let store = TestStore(initialState: state) { AlbumDetailFeature() } withDependencies: {
            $0.netease.album = { _ in throw URLError(.badServerResponse) }
        }
        await store.send(.playAll)
        await store.receive(.delegate(.play(
            tracks: [Self.makeSong(10), Self.makeSong(11)],
            source: .album(1),
            startAt: nil,
            context: .album(id: 1, name: "专辑1")
        )))
    }

    // MARK: - Subscribe

    func testSubscribeOptimisticThenConfirmed() async {
        let store = TestStore(initialState: AlbumDetailFeature.State(albumID: 1)) {
            AlbumDetailFeature()
        } withDependencies: {
            $0.netease.album = { _ in throw URLError(.badServerResponse) }
            $0.netease.subscribeAlbum = { _, _ in }
        }
        await store.send(.toggleSubscribe) { $0.isSubscribed = true }
        await store.receive(.delegate(.subscriptionChanged))
        await store.receive(.delegate(.toast(String(localized: "已收藏专辑"))))
    }

    func testUnsubscribeToastsTheOtherMessage() async {
        var state = AlbumDetailFeature.State(albumID: 1)
        state.isSubscribed = true
        let store = TestStore(initialState: state) { AlbumDetailFeature() } withDependencies: {
            $0.netease.album = { _ in throw URLError(.badServerResponse) }
            $0.netease.subscribeAlbum = { _, _ in }
        }
        await store.send(.toggleSubscribe) { $0.isSubscribed = false }
        await store.receive(.delegate(.subscriptionChanged))
        await store.receive(.delegate(.toast(String(localized: "已取消收藏"))))
    }

    func testSubscribeFailureRollsBackAndToasts() async {
        let error = URLError(.notConnectedToInternet)
        let store = TestStore(initialState: AlbumDetailFeature.State(albumID: 1)) {
            AlbumDetailFeature()
        } withDependencies: {
            $0.netease.album = { _ in throw URLError(.badServerResponse) }
            $0.netease.subscribeAlbum = { _, _ in throw error }
        }
        await store.send(.toggleSubscribe) { $0.isSubscribed = true }
        await store.receive(.subscribeReverted(to: false)) { $0.isSubscribed = false }
        await store.receive(.delegate(.toast(error.localizedDescription)))
    }
}
