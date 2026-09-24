import ComposableArchitecture
import Dependencies
import Foundation
import KumoneCore
@testable import KumoneTCA
import XCTest

@MainActor
final class AccountFeatureTests: XCTestCase {
    /// `UserProfile` has a Decodable-only conformance, so build one from JSON.
    nonisolated private static func makeProfile(_ nickname: String = "tester") -> UserProfile {
        let json = "{\"userId\": 42, \"nickname\": \"\(nickname)\", \"vipType\": 11}"
        return try! JSONDecoder().decode(
            UserProfile.self, from: Data(json.utf8)
        )
    }

    func testBootstrapSkippedWithoutCookie() async {
        let store = TestStore(initialState: AccountFeature.State()) {
            AccountFeature()
        } withDependencies: {
            $0.session.hasAuthCookie = { false }
        }
        await store.send(.bootstrap) {
            $0.hasAuthCookie = false
            $0.isBootstrapped = true
        }
    }

    func testBootstrapLoadsProfileThenLibrary() async {
        let store = TestStore(initialState: AccountFeature.State()) {
            AccountFeature()
        } withDependencies: {
            $0.session.hasAuthCookie = { true }
            $0.persistence.doubleForKey = { _ in 0 }
            $0.persistence.setDouble = { _, _ in }
            $0.netease.userAccount = { Self.makeProfile() }
            $0.musicProvider = MockMusicProvider()
            $0.netease.userPlaylists = { _, _, _ in [] }
            $0.netease.likedTrackIDs = { _ in [1, 2, 3] }
        }
        await store.send(.bootstrap) {
            $0.hasAuthCookie = true
            $0.isBootstrapping = true
        }
        await store.receive(\.bootstrapResponse) {
            $0.profile = Self.makeProfile()
            $0.isBootstrapped = true
            $0.isBootstrapping = false
        }
        // Bootstrap chains into a library refresh.
        await store.receive(\.refreshLibrary)
        await store.receive(\.libraryResponse) {
            $0.userPlaylists = []
            $0.likedTrackIDs = [1, 2, 3]
        }
    }

    func testToggleLikeRequiresLogin() async {
        let store = TestStore(initialState: AccountFeature.State()) {
            AccountFeature()
        } withDependencies: {
            $0.session.hasAuthCookie = { false }
        }
        // Not logged in: nothing changes, but a failure is surfaced.
        await store.send(.toggleLike(7))
        await store.receive(\.toggleLikeFailed)
    }

    func testToggleLikeOptimisticThenRollback() async {
        nonisolated(unsafe) var liked = false
        let store = TestStore(initialState: AccountFeature.State(
            hasAuthCookie: true,
            profile: Self.makeProfile()
        )) {
            AccountFeature()
        } withDependencies: {
            $0.session.hasAuthCookie = { true }
            $0.netease.likeTrack = { _, like in
                liked = like
                throw URLError(.badServerResponse)
            }
        }
        // Optimistic insert.
        await store.send(.toggleLike(9)) {
            $0.likedTrackIDs = [9]
        }
        XCTAssertTrue(store.state.isLiked(9))
        // Server rejects → rolled back.
        await store.receive(\.likeResponse) {
            $0.likedTrackIDs = []
        }
        await store.receive(\.toggleLikeFailed)
        XCTAssertFalse(store.state.isLiked(9))
        // The request did fire (and set the flag) before failing.
        XCTAssertTrue(liked)
    }

    func testToggleLikeSuccess() async {
        nonisolated(unsafe) var liked = false
        let store = TestStore(initialState: AccountFeature.State(
            hasAuthCookie: true,
            profile: Self.makeProfile()
        )) {
            AccountFeature()
        } withDependencies: {
            $0.session.hasAuthCookie = { true }
            $0.netease.likeTrack = { _, like in liked = like }
        }
        await store.send(.toggleLike(3)) {
            $0.likedTrackIDs = [3]
        }
        await store.receive(\.likeResponse)
        XCTAssertTrue(store.state.isLiked(3))
        XCTAssertTrue(liked)
    }

    func testLogoutClearsEverything() async {
        let store = TestStore(initialState: AccountFeature.State(
            hasAuthCookie: true,
            profile: Self.makeProfile(),
            likedTrackIDs: [1],
            userPlaylists: [],
            likedAlbums: [],
            likedArtists: []
        )) {
            AccountFeature()
        } withDependencies: {
            $0.musicProvider = MockMusicProvider()
            $0.session.clearAuth = {}
        }
        await store.send(.logout)
        await store.receive(\.logoutResponse) {
            $0.hasAuthCookie = false
            $0.profile = nil
            $0.likedTrackIDs = []
            $0.userPlaylists = []
            $0.likedAlbums = []
            $0.likedArtists = []
        }
        XCTAssertFalse(store.state.isLoggedIn)
    }

    func testPlaylistPartitionsRequireProfileAndSeparateCreators() throws {
        let playlists = try JSONDecoder().decode([PlaylistSummary].self, from: Data("""
            [{"id":1,"specialType":5,"creator":{"userId":42}},
             {"id":2,"creator":{"userId":42}},
             {"id":3,"creator":{"userId":99}},
             {"id":4}]
            """.utf8))
        var state = AccountFeature.State(userPlaylists: playlists)
        XCTAssertEqual(state.createdPlaylists, [])
        XCTAssertEqual(state.subscribedPlaylists, [])
        state.profile = Self.makeProfile()
        XCTAssertEqual(state.createdPlaylists.map(\.id), [2])
        XCTAssertEqual(state.subscribedPlaylists.map(\.id), [3, 4])
        XCTAssertEqual(state.likedSongsPlaylist?.id, 1)
        state.userPlaylists = [playlists[1]]
        XCTAssertEqual(state.likedSongsPlaylist?.id, 2)
    }

    func testBootstrapDoesNothingAfterCompletion() async {
        let store = TestStore(initialState: AccountFeature.State(isBootstrapped: true)) {
            AccountFeature()
        } withDependencies: {
            $0.session.hasAuthCookie = { XCTFail("Must not re-read session"); return true }
        }
        await store.send(.bootstrap)
    }

    func testBootstrapFailureCompletesWithoutRefreshingLibrary() async {
        let failure = URLError(.notConnectedToInternet)
        let store = TestStore(initialState: AccountFeature.State()) {
            AccountFeature()
        } withDependencies: {
            $0.session.hasAuthCookie = { true }
            $0.persistence.doubleForKey = { _ in .greatestFiniteMagnitude }
            $0.netease.userAccount = { throw failure }
        }
        await store.send(.bootstrap) {
            $0.hasAuthCookie = true
            $0.isBootstrapping = true
        }
        await store.receive(.bootstrapResponse(.failure(AppError(wrapping: failure)))) {
            $0.isBootstrapped = true
            $0.isBootstrapping = false
        }
    }

    func testLibraryFailurePreservesPreviouslyLoadedData() async throws {
        let playlist = try JSONDecoder().decode(PlaylistSummary.self, from: Data(#"{"id":9}"#.utf8))
        for failingPlaylists in [true, false] {
            let store = TestStore(initialState: AccountFeature.State(
                profile: Self.makeProfile(), likedTrackIDs: [9], userPlaylists: [playlist]
            )) { AccountFeature() } withDependencies: {
                $0.netease.userPlaylists = { uid, limit, offset in
                    XCTAssertEqual(uid, 42)
                    XCTAssertEqual(limit, 2000)
                    XCTAssertEqual(offset, 0)
                    if failingPlaylists { throw URLError(.badServerResponse) }
                    return []
                }
                $0.netease.likedTrackIDs = { _ in
                    if !failingPlaylists { throw URLError(.badServerResponse) }
                    return []
                }
            }
            await store.send(.refreshLibrary)
            await store.receive(.libraryResponse(.failure(AppError(String(localized: "加载歌单失败")))))
        }
    }

    func testSublistsSuccessReplacesAndFailurePreservesCollections() async throws {
        let album = try JSONDecoder().decode(AlbumSummary.self, from: Data(#"{"id":1}"#.utf8))
        let artist = try JSONDecoder().decode(ArtistSummary.self, from: Data(#"{"id":2}"#.utf8))
        let store = TestStore(initialState: AccountFeature.State()) {
            AccountFeature()
        } withDependencies: {
            var provider = MockMusicProvider()
            provider.likedAlbumsHandler = { limit, offset in
                XCTAssertEqual(limit, 500)
                XCTAssertEqual(offset, 0)
                return [album]
            }
            provider.likedArtistsHandler = { _, _ in [artist] }
            $0.musicProvider = provider
        }
        await store.send(.refreshSublists)
        await store.receive(.sublistsResponse(.success(.init(albums: [album], artists: [artist])))) {
            $0.likedAlbums = [album]
            $0.likedArtists = [artist]
        }
        await store.send(.sublistsResponse(.failure(AppError("failed"))))
    }

    func testSublistsRequestFailuresProduceFailureResponse() async {
        for failingAlbums in [true, false] {
            let store = TestStore(initialState: AccountFeature.State()) {
                AccountFeature()
            } withDependencies: {
                var provider = MockMusicProvider()
                provider.likedAlbumsHandler = { _, _ in
                    if failingAlbums { throw URLError(.badServerResponse) }
                    return []
                }
                provider.likedArtistsHandler = { _, _ in
                    if !failingAlbums { throw URLError(.badServerResponse) }
                    return []
                }
                $0.musicProvider = provider
            }
            await store.send(.refreshSublists)
            await store.receive(.sublistsResponse(.failure(AppError(String(localized: "加载收藏失败")))))
        }
    }

    func testUnlikeSuccessAndFailureRollback() async {
        for succeeds in [true, false] {
            let failure = URLError(.badServerResponse)
            let store = TestStore(initialState: AccountFeature.State(
                hasAuthCookie: true, profile: Self.makeProfile(), likedTrackIDs: [7]
            )) { AccountFeature() } withDependencies: {
                $0.netease.likeTrack = { id, like in
                    XCTAssertEqual(id, 7)
                    XCTAssertFalse(like)
                    if !succeeds { throw failure }
                }
            }
            await store.send(.toggleLike(7)) { $0.likedTrackIDs = [] }
            if succeeds {
                await store.receive(.likeResponse(.success(false), trackID: 7))
            } else {
                await store.receive(.likeResponse(.failure(AppError(wrapping: failure)), trackID: 7)) {
                    $0.likedTrackIDs = [7]
                }
                await store.receive(.toggleLikeFailed(AppError(String(localized: "操作失败，请稍后重试"))))
            }
        }
    }
}
