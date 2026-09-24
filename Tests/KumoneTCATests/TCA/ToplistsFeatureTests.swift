import ComposableArchitecture
import Dependencies
import Foundation
import KumoneCore
@testable import KumoneTCA
import XCTest

@MainActor
final class ToplistsFeatureTests: XCTestCase {
    func testInitialStateAndSuccessfulFirstLoad() async throws {
        let lists = [try JSONDecoder().decode(
            ToplistItem.self, from: Data(#"{"id":1,"name":"排行榜"}"#.utf8))]
        let store = TestStore(initialState: ToplistsFeature.State()) {
            ToplistsFeature()
        } withDependencies: {
            $0.netease.toplists = { lists }
        }
        XCTAssertEqual(store.state.toplists, [])
        XCTAssertEqual(store.state.loadState, .idle)
        await store.send(.onAppear) { $0.loadState = .loading }
        await store.receive(.response(lists)) {
            $0.toplists = lists
            $0.loadState = .loaded
        }
        await store.finish()
    }

    func testOnAppearDoesNotFetchInAnyNonIdleState() async {
        for loadState in [ToplistsFeature.State.LoadState.loading, .loaded, .error("offline")] {
            var state = ToplistsFeature.State()
            state.loadState = loadState
            let store = TestStore(initialState: state) {
                ToplistsFeature()
            } withDependencies: {
                $0.netease.toplists = {
                    XCTFail("Non-idle onAppear must not fetch")
                    return []
                }
            }
            await store.send(.onAppear)
            await store.finish()
        }
    }

    func testFailurePreservesListsAndReloadRecovers() async throws {
        let old = try JSONDecoder().decode(
            ToplistItem.self, from: Data(#"{"id":1,"name":"旧榜"}"#.utf8))
        var state = ToplistsFeature.State()
        state.toplists = [old]
        let error = URLError(.notConnectedToInternet)
        let store = TestStore(initialState: state) {
            ToplistsFeature()
        } withDependencies: {
            $0.netease.toplists = { throw error }
        }
        await store.send(.onAppear) { $0.loadState = .loading }
        await store.receive(.loadFailed(error.localizedDescription)) {
            $0.loadState = .error(error.localizedDescription)
        }
        XCTAssertEqual(store.state.toplists, [old])
        store.dependencies.netease.toplists = { [] }
        await store.send(.reload) { $0.loadState = .loading }
        await store.receive(.response([])) {
            $0.toplists = []
            $0.loadState = .loaded
        }
        await store.send(.reload) { $0.loadState = .loading }
        await store.receive(.response([])) { $0.loadState = .loaded }
        await store.finish()
    }

    func testDelegateLeavesStateUnchanged() async {
        let store = TestStore(initialState: ToplistsFeature.State()) { ToplistsFeature() }
        await store.send(.delegate(.play(tracks: [], source: .playlist(1), context: nil)))
        await store.finish()
    }
}
