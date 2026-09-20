import ComposableArchitecture
import Dependencies
@testable import KumoneCore
import XCTest

@MainActor
final class DailySongsFeatureTests: XCTestCase {
    nonisolated private static func makeSong(_ id: Int) -> Track {
        let json = """
            {"id": \(id), "name": "歌曲\(id)", "ar": [{"id": 1, "name": "歌手"}], \
            "al": {"id": 2, "name": "专辑\(id)"}, "dt": 100000}
            """
        return try! JSONDecoder().decode(Track.self, from: Data(json.utf8))
    }

    func testLoggedOutIsRejected() async {
        let store = TestStore(initialState: DailySongsFeature.State()) {
            DailySongsFeature()
        } withDependencies: {
            $0.netease.dailyRecommendSongs = { fatalError("must not be called") }
        }
        await store.send(.onAppear) {
            $0.loadState = .error(String(localized: "登录后才能查看每日推荐"))
        }
        XCTAssertEqual(
            store.state.loadState, .error(String(localized: "登录后才能查看每日推荐")))
    }

    func testLoggedInLoadsTheList() async {
        var state = DailySongsFeature.State()
        state.isLoggedIn = true
        let store = TestStore(initialState: state) { DailySongsFeature() } withDependencies: {
            $0.netease.dailyRecommendSongs = { [Self.makeSong(1), Self.makeSong(2)] }
        }
        await store.send(.onAppear) { $0.loadState = .loading }
        await store.receive(.songsResponse([Self.makeSong(1), Self.makeSong(2)])) {
            $0.tracks = [Self.makeSong(1), Self.makeSong(2)]
            $0.loadState = .loaded
        }
    }

    func testFailedLoadSurfacesError() async {
        let error = URLError(.badServerResponse)
        var state = DailySongsFeature.State()
        state.isLoggedIn = true
        let store = TestStore(initialState: state) { DailySongsFeature() } withDependencies: {
            $0.netease.dailyRecommendSongs = { throw error }
        }
        await store.send(.onAppear) { $0.loadState = .loading }
        await store.receive(.loadFailed(error.localizedDescription)) {
            $0.loadState = .error(error.localizedDescription)
        }
    }

    /// A rejected recommendation is replaced, not removed.
    func testRecommendationReducedSwapsInPlace() async {
        var state = DailySongsFeature.State()
        state.tracks = [Self.makeSong(1), Self.makeSong(2)]
        let store = TestStore(initialState: state) { DailySongsFeature() } withDependencies: {
            $0.netease.dailyRecommendSongs = { [] }
        }
        await store.send(.recommendationReduced(
            rejected: Self.makeSong(1), replacement: Self.makeSong(3)
        )) {
            $0.tracks = [Self.makeSong(3), Self.makeSong(2)]
        }
    }

    func testPlayAllHandsTheListToThePlayer() async {
        var state = DailySongsFeature.State()
        state.tracks = [Self.makeSong(1), Self.makeSong(2)]
        let store = TestStore(initialState: state) { DailySongsFeature() } withDependencies: {
            $0.netease.dailyRecommendSongs = { [] }
        }
        await store.send(.playAll)
        await store.receive(.delegate(.play(
            tracks: [Self.makeSong(1), Self.makeSong(2)], source: .daily, context: .daily
        )))
    }
}
