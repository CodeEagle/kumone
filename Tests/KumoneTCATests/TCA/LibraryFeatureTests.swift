import Foundation
import ComposableArchitecture
import Dependencies
import KumoneCore
@testable import KumoneTCA
import XCTest

@MainActor
final class RecentsFeatureTests: XCTestCase {
    nonisolated private static func makeSong(_ id: Int) -> Track {
        let json = """
            {"id": \(id), "name": "歌曲\(id)", "ar": [{"id": 1, "name": "歌手"}], \
            "al": {"id": 2, "name": "专辑\(id)"}, "dt": 100000}
            """
        return try! JSONDecoder().decode(Track.self, from: Data(json.utf8))
    }

    nonisolated private static func makeRecord(_ id: Int, _ playCount: Int) -> PlayRecordItem {
        let song = """
            {"id": \(id), "name": "歌曲\(id)", "ar": [{"id": 1, "name": "歌手"}], \
            "al": {"id": 2, "name": "专辑\(id)"}, "dt": 100000}
            """
        let json = "{\"playCount\": \(playCount), \"score\": 100, \"song\": \(song)}"
        return try! JSONDecoder().decode(PlayRecordItem.self, from: Data(json.utf8))
    }

    func testLoggedOutIsRejected() async {
        let store = TestStore(initialState: RecentsFeature.State()) { RecentsFeature() } withDependencies: {
            $0.netease.playRecords = { _, _ in fatalError("must not be called") }
        }
        await store.send(.onAppear) {
            $0.loadState = RecentsFeature.State.LoadState.error(String(localized: "登录后才能查看播放记录"))
        }
    }

    func testLoadsAllTimeRecords() async {
        var state = RecentsFeature.State()
        state.userID = 42
        let store = TestStore(initialState: state) { RecentsFeature() } withDependencies: {
            $0.netease.playRecords = { uid, week in
                XCTAssertEqual(uid, 42)
                XCTAssertFalse(week)
                return [Self.makeRecord(1, 9), Self.makeRecord(2, 4)]
            }
        }
        await store.send(.onAppear) { $0.loadState = RecentsFeature.State.LoadState.loading }
        await store.receive(.recordsResponse([Self.makeRecord(1, 9), Self.makeRecord(2, 4)])) {
            $0.records = [Self.makeRecord(1, 9), Self.makeRecord(2, 4)]
            $0.loadState = RecentsFeature.State.LoadState.loaded
        }
    }

    /// Switching the range keeps the old list visible and refetches.
    func testToggleWeekRefetchesTheOtherRange() async {
        var state = RecentsFeature.State()
        state.userID = 42
        state.records = [Self.makeRecord(1, 9)]
        state.loadState = RecentsFeature.State.LoadState.loaded
        let store = TestStore(initialState: state) { RecentsFeature() } withDependencies: {
            $0.netease.playRecords = { _, week in
                XCTAssertTrue(week)
                return [Self.makeRecord(3, 2)]
            }
        }
        await store.send(.toggleWeek) { $0.week = true }
        await store.receive(.recordsResponse([Self.makeRecord(3, 2)])) {
            $0.records = [Self.makeRecord(3, 2)]
        }
        XCTAssertTrue(store.state.week)
    }

    func testPlayAllAndPlayRecord() async {
        var state = RecentsFeature.State()
        state.records = [Self.makeRecord(1, 9), Self.makeRecord(2, 4)]
        let store = TestStore(initialState: state) { RecentsFeature() } withDependencies: {
            $0.netease.playRecords = { _, _ in [] }
        }
        await store.send(.playAll)
        await store.receive(.delegate(.play(
            tracks: [Self.makeSong(1), Self.makeSong(2)], startAt: nil, context: .recents
        )))
        await store.send(.playRecord(Self.makeRecord(2, 4)))
        await store.receive(.delegate(.play(
            tracks: [Self.makeSong(1), Self.makeSong(2)], startAt: Self.makeSong(2), context: .recents
        )))
    }
    func testNonIdleAppearanceDoesNotLoadRecords() async {
        for loadState in [RecentsFeature.State.LoadState.loading, .loaded, .error("offline")] {
            var state = RecentsFeature.State()
            state.userID = 42
            state.loadState = loadState
            let store = TestStore(initialState: state) { RecentsFeature() }
            await store.send(.onAppear)
        }
    }

    func testReloadFailureRetainsRecordsAndReportsError() async {
        let error = URLError(.notConnectedToInternet)
        var state = RecentsFeature.State()
        state.userID = 42
        state.week = true
        state.records = [Self.makeRecord(1, 9)]
        state.loadState = .loaded
        let store = TestStore(initialState: state) { RecentsFeature() } withDependencies: {
            $0.netease.playRecords = { uid, week in
                XCTAssertEqual(uid, 42)
                XCTAssertTrue(week)
                throw error
            }
        }
        await store.send(.reload)
        await store.receive(.loadFailed(error.localizedDescription)) {
            $0.loadState = .error(error.localizedDescription)
        }
    }

}

@MainActor
final class CloudFeatureTests: XCTestCase {
    nonisolated private static func makeSong(_ id: Int) -> Track {
        let json = """
            {"id": \(id), "name": "歌曲\(id)", "ar": [{"id": 1, "name": "歌手"}], \
            "al": {"id": 2, "name": "专辑\(id)"}, "dt": 100000}
            """
        return try! JSONDecoder().decode(Track.self, from: Data(json.utf8))
    }

    /// `CloudResponse` decodes itself (the quota fields arrive as numbers or
    /// numeric strings), so the fixture is assembled as JSON text.
    nonisolated private static func itemJSON(_ id: Int, simpleSong: Bool) -> String {
        let song = """
            {"id": \(id), "name": "歌曲\(id)", "ar": [{"id": 1, "name": "歌手"}], \
            "al": {"id": 2, "name": "专辑\(id)"}, "dt": 100000}
            """
        return """
            {"songId": \(id), "songName": "歌曲\(id)", "fileSize": 1000, \
            "simpleSong": \(simpleSong ? song : "null")}
            """
    }

    nonisolated private static func makeItem(_ id: Int, simpleSong: Bool) -> CloudSongItem {
        try! JSONDecoder().decode(
            CloudSongItem.self, from: Data(itemJSON(id, simpleSong: simpleSong).utf8))
    }

    nonisolated private static func makeCloudResponse(
        items: [String],
        size: Int64? = nil,
        maxSize: Int64? = nil
    ) -> NeteaseAPI.CloudResponse {
        var fields = ["\"data\": [\(items.joined(separator: ","))]", "\"hasMore\": false"]
        if let size { fields.append("\"size\": \(size)") }
        if let maxSize { fields.append("\"maxSize\": \(maxSize)") }
        let json = "{\(fields.joined(separator: ", "))}"
        return try! JSONDecoder().decode(
            NeteaseAPI.CloudResponse.self, from: Data(json.utf8))
    }

    func testLoadsItemsAndQuota() async {
        let store = TestStore(initialState: CloudFeature.State()) { CloudFeature() } withDependencies: {
            $0.netease.cloudSongs = { _, _ in
                Self.makeCloudResponse(
                    items: [
                        Self.itemJSON(1, simpleSong: true),
                        Self.itemJSON(2, simpleSong: false),
                    ],
                    size: 1_610_612_736, maxSize: 5_368_709_120)
            }
        }
        await store.send(.onAppear) { $0.loadState = CloudFeature.State.LoadState.loading }
        await store.receive(.itemsResponse(
            items: [Self.makeItem(1, simpleSong: true), Self.makeItem(2, simpleSong: false)],
            sizeInfo: String(localized: "已使用 1.5 GB / 5 GB")
        )) {
            $0.items = [Self.makeItem(1, simpleSong: true), Self.makeItem(2, simpleSong: false)]
            $0.sizeInfo = String(localized: "已使用 1.5 GB / 5 GB")
            $0.loadState = CloudFeature.State.LoadState.loaded
        }
        // Only items with an embedded playable track make it into the queue.
        XCTAssertEqual(store.state.tracks.map(\.id), [1])
    }

    func testMissingQuotaYieldsNoSizeInfo() async {
        let store = TestStore(initialState: CloudFeature.State()) { CloudFeature() } withDependencies: {
            $0.netease.cloudSongs = { _, _ in
                Self.makeCloudResponse(items: [])
            }
        }
        await store.send(.onAppear) { $0.loadState = CloudFeature.State.LoadState.loading }
        await store.receive(.itemsResponse(items: [], sizeInfo: nil)) {
            $0.loadState = CloudFeature.State.LoadState.loaded
        }
        XCTAssertNil(store.state.sizeInfo)
    }

    func testPlayAllHandsThePlayableTracksToThePlayer() async {
        var state = CloudFeature.State()
        state.items = [Self.makeItem(1, simpleSong: true), Self.makeItem(2, simpleSong: false)]
        let store = TestStore(initialState: state) { CloudFeature() } withDependencies: {
            $0.netease.cloudSongs = { _, _ in
                Self.makeCloudResponse(items: [])
            }
        }
        await store.send(.playAll)
        await store.receive(.delegate(.play(tracks: [Self.makeSong(1)], source: .cloud, context: .cloud)))
    }
    func testNonIdleAppearanceDoesNotLoadCloud() async {
        for loadState in [CloudFeature.State.LoadState.loading, .loaded, .error("offline")] {
            var state = CloudFeature.State()
            state.loadState = loadState
            let store = TestStore(initialState: state) { CloudFeature() }
            await store.send(.onAppear)
        }
    }

    func testReloadWithMissingDataClearsOldItemsAndQuota() async {
        var state = CloudFeature.State()
        state.items = [Self.makeItem(1, simpleSong: true)]
        state.sizeInfo = "old quota"
        state.loadState = .loaded
        let store = TestStore(initialState: state) { CloudFeature() } withDependencies: {
            $0.netease.cloudSongs = { limit, offset in
                XCTAssertEqual(limit, 100)
                XCTAssertEqual(offset, 0)
                return try JSONDecoder().decode(
                    NeteaseAPI.CloudResponse.self, from: Data(#"{"hasMore":false}"#.utf8))
            }
        }
        await store.send(.reload)
        await store.receive(.itemsResponse(items: [], sizeInfo: nil)) {
            $0.items = []
            $0.sizeInfo = nil
        }
    }

    func testCloudLoadFailureReportsError() async {
        let error = URLError(.notConnectedToInternet)
        let store = TestStore(initialState: CloudFeature.State()) { CloudFeature() } withDependencies: {
            $0.netease.cloudSongs = { _, _ in throw error }
        }
        await store.send(.onAppear) { $0.loadState = .loading }
        await store.receive(.loadFailed(error.localizedDescription)) {
            $0.loadState = .error(error.localizedDescription)
        }
    }

}

@MainActor
final class CollectionsFeatureTests: XCTestCase {
    func testEveryAppearanceRequestsSublistsRefresh() async {
        let store = TestStore(initialState: CollectionsFeature.State()) { CollectionsFeature() }
        await store.send(.onAppear)
        await store.receive(.delegate(.refreshSublists))
        await store.send(.onAppear)
        await store.receive(.delegate(.refreshSublists))
    }
}
