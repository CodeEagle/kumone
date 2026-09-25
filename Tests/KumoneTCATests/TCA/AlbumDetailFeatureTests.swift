import Foundation
import ComposableArchitecture
import Dependencies
@testable import KumoneCore
@testable import KumoneTCA
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
        var provider = MockMusicProvider()
        provider.albumHandler = { _ in
            AlbumDetail(detail: Self.makeAlbum(1), songs: [Self.makeSong(10), Self.makeSong(11)])
        }
        provider.albumDynamicHandler = { _ in
            AlbumDynamic(isSubscribed: true, subscriberCount: 1)
        }
        provider.artistAlbumsHandler = { artistID, _, _ in
            XCTAssertEqual(artistID, MusicID(5))
            return ArtistAlbums(
                albums: [Self.makeAlbumSummary(1, 10), Self.makeAlbumSummary(2, 8)], hasMore: false)
        }
        let store = TestStore(initialState: AlbumDetailFeature.State(albumID: 1)) {
            AlbumDetailFeature()
        } withDependencies: {
            $0.musicProvider = provider
        }
        await store.send(.onAppear) { $0.loadState = AlbumDetailFeature.State.LoadState.loading }
        await store.receive(.albumResponse(
            album: AlbumDetail(detail: Self.makeAlbum(1), songs: [Self.makeSong(10), Self.makeSong(11)]),
            songs: [Self.makeSong(10), Self.makeSong(11)]
        )) {
            $0.album = AlbumDetail(detail: Self.makeAlbum(1), songs: [Self.makeSong(10), Self.makeSong(11)])
            $0.tracks = [Self.makeSong(10), Self.makeSong(11)]
            $0.loadState = AlbumDetailFeature.State.LoadState.loaded
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
        var provider = MockMusicProvider()
        provider.albumHandler = { _ in throw error }
        let store = TestStore(initialState: AlbumDetailFeature.State(albumID: 1)) {
            AlbumDetailFeature()
        } withDependencies: {
            $0.musicProvider = provider
        }
        await store.send(.onAppear) { $0.loadState = AlbumDetailFeature.State.LoadState.loading }
        await store.receive(.loadFailed(error.localizedDescription)) {
            $0.loadState = AlbumDetailFeature.State.LoadState.error(error.localizedDescription)
        }
    }

    // MARK: - Play

    func testPlayAllHandsTheSongsToThePlayer() async {
        var state = AlbumDetailFeature.State(albumID: 1)
        state.album = Self.makeAlbum(1)
        state.tracks = [Self.makeSong(10), Self.makeSong(11)]
        var provider = MockMusicProvider()
        provider.albumHandler = { _ in throw URLError(.badServerResponse) }
        let store = TestStore(initialState: state) { AlbumDetailFeature() } withDependencies: {
            $0.musicProvider = provider
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
        var provider = MockMusicProvider()
        provider.albumHandler = { _ in throw URLError(.badServerResponse) }
        provider.subscribeAlbumHandler = { _, _ in }
        let store = TestStore(initialState: AlbumDetailFeature.State(albumID: 1)) {
            AlbumDetailFeature()
        } withDependencies: {
            $0.musicProvider = provider
        }
        await store.send(.toggleSubscribe) { $0.isSubscribed = true }
        await store.receive(.delegate(.subscriptionChanged))
        await store.receive(.delegate(.toast(String(localized: "已收藏专辑"))))
    }

    func testUnsubscribeToastsTheOtherMessage() async {
        var state = AlbumDetailFeature.State(albumID: 1)
        state.isSubscribed = true
        var provider = MockMusicProvider()
        provider.albumHandler = { _ in throw URLError(.badServerResponse) }
        provider.subscribeAlbumHandler = { _, _ in }
        let store = TestStore(initialState: state) { AlbumDetailFeature() } withDependencies: {
            $0.musicProvider = provider
        }
        await store.send(.toggleSubscribe) { $0.isSubscribed = false }
        await store.receive(.delegate(.subscriptionChanged))
        await store.receive(.delegate(.toast(String(localized: "已取消收藏"))))
    }

    func testSubscribeFailureRollsBackAndToasts() async {
        let error = URLError(.notConnectedToInternet)
        var provider = MockMusicProvider()
        provider.albumHandler = { _ in throw URLError(.badServerResponse) }
        provider.subscribeAlbumHandler = { _, _ in throw error }
        let store = TestStore(initialState: AlbumDetailFeature.State(albumID: 1)) {
            AlbumDetailFeature()
        } withDependencies: {
            $0.musicProvider = provider
        }
        await store.send(.toggleSubscribe) { $0.isSubscribed = true }
        await store.receive(.subscribeReverted(to: false)) { $0.isSubscribed = false }
        await store.receive(.delegate(.toast(error.localizedDescription)))
    }
    func testNonIdleAppearanceAndPlayWithoutAlbumDoNothing() async {
        for loadState in [AlbumDetailFeature.State.LoadState.loading, .loaded, .error("offline")] {
            var state = AlbumDetailFeature.State(albumID: 1)
            state.loadState = loadState
            let store = TestStore(initialState: state) { AlbumDetailFeature() }
            await store.send(.onAppear)
            await store.send(.playAll)
        }
    }

    func testReloadTreatsMissingSubscriptionFlagAsFalse() async {
        var state = AlbumDetailFeature.State(albumID: 1)
        state.album = Self.makeAlbum(1)
        state.loadState = .loaded
        state.isSubscribed = true
        var provider = MockMusicProvider()
        provider.albumHandler = { id in
            XCTAssertEqual(id, MusicID(1))
            return AlbumDetail(detail: Self.makeAlbum(1), songs: [Self.makeSong(10)])
        }
        provider.albumDynamicHandler = { _ in
            AlbumDynamic(isSubscribed: false, subscriberCount: 0)
        }
        provider.artistAlbumsHandler = { _, _, _ in
            ArtistAlbums(albums: [], hasMore: false)
        }
        let store = TestStore(initialState: state) { AlbumDetailFeature() } withDependencies: {
            $0.musicProvider = provider
        }
        await store.send(.reload) { $0.loadState = .loading }
        await store.receive(.albumResponse(album: AlbumDetail(detail: Self.makeAlbum(1), songs: [Self.makeSong(10)]), songs: [Self.makeSong(10)])) {
            $0.album = AlbumDetail(detail: Self.makeAlbum(1), songs: [Self.makeSong(10)])
            $0.tracks = [Self.makeSong(10)]
            $0.loadState = .loaded
        }
        await store.receive(.dynamicResponse(isSubscribed: false)) { $0.isSubscribed = false }
        await store.receive(.otherAlbumsResponse([]))
    }

}
