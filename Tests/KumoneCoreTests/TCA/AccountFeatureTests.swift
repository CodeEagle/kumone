import ComposableArchitecture
import Dependencies
@testable import KumoneCore
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
            $0.netease.refreshLogin = {}
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
            $0.netease.logout = {}
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
}
