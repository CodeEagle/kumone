import Foundation
import ComposableArchitecture
import Dependencies
@testable import KumoneCore
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

    nonisolated private static func makeProviderRecord(_ id: Int, _ playCount: Int) -> PlayRecord {
        PlayRecord(playCount: playCount, score: 100, song: makeSong(id))
    }

    func testLoggedOutIsRejected() async {
        var provider = MockMusicProvider()
        provider.playRecordsHandler = { _, _ in fatalError("must not be called") }
        let store = TestStore(initialState: RecentsFeature.State()) { RecentsFeature() } withDependencies: {
            $0.playHistory = provider
        }
        await store.send(.onAppear) {
            $0.loadState = RecentsFeature.State.LoadState.error(String(localized: "登录后才能查看播放记录"))
        }
    }

    func testLoadsAllTimeRecords() async {
        var state = RecentsFeature.State()
        state.userID = 42
        var provider = MockMusicProvider()
        provider.playRecordsHandler = { uid, week in
            XCTAssertEqual(uid, MusicID(42))
            XCTAssertFalse(week)
            return [Self.makeProviderRecord(1, 9), Self.makeProviderRecord(2, 4)]
        }
        let store = TestStore(initialState: state) { RecentsFeature() } withDependencies: {
            $0.playHistory = provider
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
        var provider = MockMusicProvider()
        provider.playRecordsHandler = { _, week in
            XCTAssertTrue(week)
            return [Self.makeProviderRecord(3, 2)]
        }
        let store = TestStore(initialState: state) { RecentsFeature() } withDependencies: {
            $0.playHistory = provider
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
        var provider = MockMusicProvider()
        provider.playRecordsHandler = { _, _ in [] }
        let store = TestStore(initialState: state) { RecentsFeature() } withDependencies: {
            $0.playHistory = provider
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
        var provider = MockMusicProvider()
        provider.playRecordsHandler = { uid, week in
            XCTAssertEqual(uid, MusicID(42))
            XCTAssertTrue(week)
            throw error
        }
        let store = TestStore(initialState: state) { RecentsFeature() } withDependencies: {
            $0.playHistory = provider
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
    ) -> CloudStoragePage {
        CloudStoragePage(
            items: items.map { try! JSONDecoder().decode(CloudSongItem.self, from: Data($0.utf8)) },
            hasMore: false, usedBytes: size ?? 0, maxBytes: maxSize ?? 0)
    }

    func testLoadsItemsAndQuota() async {
        var provider = MockMusicProvider()
        provider.cloudSongsHandler = { _, _ in
            Self.makeCloudResponse(
                items: [
                    Self.itemJSON(1, simpleSong: true),
                    Self.itemJSON(2, simpleSong: false),
                ],
                size: 1_610_612_736, maxSize: 5_368_709_120)
        }
        let store = TestStore(initialState: CloudFeature.State()) { CloudFeature() } withDependencies: {
            $0.cloudStorage = provider
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
        var provider = MockMusicProvider()
        provider.cloudSongsHandler = { _, _ in
            Self.makeCloudResponse(items: [])
        }
        let store = TestStore(initialState: CloudFeature.State()) { CloudFeature() } withDependencies: {
            $0.cloudStorage = provider
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
        var provider = MockMusicProvider()
        provider.cloudSongsHandler = { _, _ in
            Self.makeCloudResponse(items: [])
        }
        let store = TestStore(initialState: state) { CloudFeature() } withDependencies: {
            $0.cloudStorage = provider
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
        var provider = MockMusicProvider()
        provider.cloudSongsHandler = { limit, offset in
            XCTAssertEqual(limit, 100)
            XCTAssertEqual(offset, 0)
            return Self.makeCloudResponse(items: [])
        }
        let store = TestStore(initialState: state) { CloudFeature() } withDependencies: {
            $0.cloudStorage = provider
        }
        await store.send(.reload)
        await store.receive(.itemsResponse(items: [], sizeInfo: nil)) {
            $0.items = []
            $0.sizeInfo = nil
        }
    }

    func testCloudLoadFailureReportsError() async {
        let error = URLError(.notConnectedToInternet)
        var provider = MockMusicProvider()
        provider.cloudSongsHandler = { _, _ in throw error }
        let store = TestStore(initialState: CloudFeature.State()) { CloudFeature() } withDependencies: {
            $0.cloudStorage = provider
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
