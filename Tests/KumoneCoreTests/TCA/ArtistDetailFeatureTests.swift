import ComposableArchitecture
import Dependencies
@testable import KumoneCore
import XCTest

@MainActor
final class ArtistDetailFeatureTests: XCTestCase {
    // MARK: - Fixtures

    nonisolated private static func makeSong(_ id: Int) -> Track {
        let json = """
            {"id": \(id), "name": "歌曲\(id)", "ar": [{"id": 1, "name": "歌手"}], \
            "al": {"id": 2, "name": "专辑\(id)"}, "dt": 100000}
            """
        return try! JSONDecoder().decode(Track.self, from: Data(json.utf8))
    }

    nonisolated private static func makeArtist(_ followed: Bool = false) -> ArtistSummary {
        let json = """
            {"id": 7, "name": "歌手", "picUrl": "https://music.example.com/ar7.jpg", \
            "albumSize": 3, "musicSize": 9, "briefDesc": "简介", "alias": [], "followed": \(followed)}
            """
        return try! JSONDecoder().decode(ArtistSummary.self, from: Data(json.utf8))
    }

    nonisolated private static func makeAlbum(_ id: Int, _ size: Int) -> AlbumSummary {
        let json = """
            {"id": \(id), "name": "专辑\(id)", "picUrl": "https://music.example.com/a\(id).jpg", \
            "artist": {"name": "歌手"}, "publishTime": 1700000000000, "size": \(size)}
            """
        return try! JSONDecoder().decode(AlbumSummary.self, from: Data(json.utf8))
    }

    nonisolated private static func makeSimilar(_ id: Int) -> ArtistSummary {
        let json = """
            {"id": \(id), "name": "相似歌手\(id)", "picUrl": "https://music.example.com/s\(id).jpg", \
            "albumSize": 1, "musicSize": 2}
            """
        return try! JSONDecoder().decode(ArtistSummary.self, from: Data(json.utf8))
    }

    // MARK: - Loading

    /// Albums split by track count, and similar artists only for logged-in
    /// users.
    func testLoadsArtistSplitsAlbumsAndFetchesSimilarWhenLoggedIn() async {
        var state = ArtistDetailFeature.State(artistID: 7)
        state.isLoggedIn = true
        let store = TestStore(initialState: state) { ArtistDetailFeature() } withDependencies: {
            $0.netease.artist = { _ in
                NeteaseAPI.ArtistResponse(artist: Self.makeArtist(true), hotSongs: [Self.makeSong(1)])
            }
            $0.netease.artistAlbums = { _, _, _ in
                NeteaseAPI.ArtistAlbumsResponse(
                    hotAlbums: [Self.makeAlbum(10, 12), Self.makeAlbum(11, 1)], more: false)
            }
            $0.netease.similarArtists = { _ in [Self.makeSimilar(20), Self.makeSimilar(21)] }
        }
        await store.send(.onAppear) { $0.loadState = .loading }
        await store.receive(.artistResponse(
            artist: Self.makeArtist(true), hotSongs: [Self.makeSong(1)]
        )) {
            $0.artist = Self.makeArtist(true)
            $0.hotSongs = [Self.makeSong(1)]
            $0.isFollowed = true
            $0.loadState = .loaded
        }
        await store.receive(.albumsResponse([
            Self.makeAlbum(10, 12), Self.makeAlbum(11, 1),
        ])) {
            $0.albums = [Self.makeAlbum(10, 12)]
            $0.epsAndSingles = [Self.makeAlbum(11, 1)]
        }
        await store.receive(.similarResponse([Self.makeSimilar(20), Self.makeSimilar(21)])) {
            $0.similar = [Self.makeSimilar(20), Self.makeSimilar(21)]
        }
    }

    /// Logged out: the similar-artists endpoint is never hit (it is left
    /// unimplemented, so a call would trap).
    func testLoggedOutSkipsSimilarArtists() async {
        let store = TestStore(initialState: ArtistDetailFeature.State(artistID: 7)) {
            ArtistDetailFeature()
        } withDependencies: {
            $0.netease.artist = { _ in
                NeteaseAPI.ArtistResponse(artist: Self.makeArtist(), hotSongs: [])
            }
            $0.netease.artistAlbums = { _, _, _ in
                NeteaseAPI.ArtistAlbumsResponse(hotAlbums: [], more: false)
            }
        }
        await store.send(.onAppear) { $0.loadState = .loading }
        await store.receive(.artistResponse(artist: Self.makeArtist(), hotSongs: [])) {
            $0.artist = Self.makeArtist()
            $0.loadState = .loaded
        }
        await store.receive(.albumsResponse([]))
        XCTAssertTrue(store.state.similar.isEmpty)
    }

    func testFailedLoadSurfacesError() async {
        let error = URLError(.badServerResponse)
        let store = TestStore(initialState: ArtistDetailFeature.State(artistID: 7)) {
            ArtistDetailFeature()
        } withDependencies: {
            $0.netease.artist = { _ in throw error }
        }
        await store.send(.onAppear) { $0.loadState = .loading }
        await store.receive(.loadFailed(error.localizedDescription)) {
            $0.loadState = .error(error.localizedDescription)
        }
    }

    // MARK: - Play

    func testPlayAllHandsTheHotSongsToThePlayer() async {
        var state = ArtistDetailFeature.State(artistID: 7)
        state.artist = Self.makeArtist()
        state.hotSongs = [Self.makeSong(1), Self.makeSong(2)]
        let store = TestStore(initialState: state) { ArtistDetailFeature() } withDependencies: {
            $0.netease.artist = { _ in throw URLError(.badServerResponse) }
        }
        await store.send(.playAll)
        await store.receive(.delegate(.play(
            tracks: [Self.makeSong(1), Self.makeSong(2)],
            source: .artist(7),
            context: .artist(id: 7, name: "歌手")
        )))
    }

    // MARK: - Follow

    func testFollowOptimisticThenConfirmed() async {
        let store = TestStore(initialState: ArtistDetailFeature.State(artistID: 7)) {
            ArtistDetailFeature()
        } withDependencies: {
            $0.netease.artist = { _ in throw URLError(.badServerResponse) }
            $0.netease.subscribeArtist = { _, _ in }
        }
        await store.send(.toggleFollow) { $0.isFollowed = true }
        await store.receive(.delegate(.subscriptionChanged))
        await store.receive(.delegate(.toast(String(localized: "已关注歌手"))))
    }

    func testUnfollowToastsTheOtherMessage() async {
        var state = ArtistDetailFeature.State(artistID: 7)
        state.isFollowed = true
        let store = TestStore(initialState: state) { ArtistDetailFeature() } withDependencies: {
            $0.netease.artist = { _ in throw URLError(.badServerResponse) }
            $0.netease.subscribeArtist = { _, _ in }
        }
        await store.send(.toggleFollow) { $0.isFollowed = false }
        await store.receive(.delegate(.subscriptionChanged))
        await store.receive(.delegate(.toast(String(localized: "已取消关注"))))
    }

    func testFollowFailureRollsBackAndToasts() async {
        let error = URLError(.notConnectedToInternet)
        let store = TestStore(initialState: ArtistDetailFeature.State(artistID: 7)) {
            ArtistDetailFeature()
        } withDependencies: {
            $0.netease.artist = { _ in throw URLError(.badServerResponse) }
            $0.netease.subscribeArtist = { _, _ in throw error }
        }
        await store.send(.toggleFollow) { $0.isFollowed = true }
        await store.receive(.followReverted(to: false)) { $0.isFollowed = false }
        await store.receive(.delegate(.toast(error.localizedDescription)))
    }
}
