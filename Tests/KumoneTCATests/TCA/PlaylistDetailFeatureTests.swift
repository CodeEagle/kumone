import Foundation
import ComposableArchitecture
import Dependencies
@testable import KumoneCore
@testable import KumoneTCA
import XCTest

@MainActor
final class PlaylistDetailFeatureTests: XCTestCase {
    // MARK: - Fixtures

    nonisolated private static func makeSong(_ id: Int, _ fee: Int = 0) -> Track {
        let json = """
            {"id": \(id), "name": "歌曲\(id)", "ar": [{"id": 1, "name": "歌手"}], \
            "al": {"id": 2, "name": "专辑\(id)"}, "dt": 100000, "fee": \(fee)}
            """
        return try! JSONDecoder().decode(Track.self, from: Data(json.utf8))
    }

    nonisolated private static func makeSongWithPrivilege(_ id: Int) -> Track {
        var song = makeSong(id)
        song.embeddedPrivilege = makePrivilege(id, 0)
        return song
    }

    nonisolated private static func makePrivilege(_ id: Int, _ fee: Int) -> TrackPrivilege {
        let json = "{\"id\": \(id), \"fee\": \(fee), \"pl\": 0, \"st\": 0, \"cs\": false, \"maxbr\": 0}"
        return try! JSONDecoder().decode(TrackPrivilege.self, from: Data(json.utf8))
    }

    nonisolated private static func makeDetail(
        id: Int = 1,
        trackIDs: [Int],
        tracks: [Track]
    ) -> PlaylistDetail {
        let trackIDsJSON = trackIDs.map { "{\"id\":\($0)}" }.joined(separator: ",")
        let tracksJSON = (try? JSONEncoder().encode(tracks)).map { String(data: $0, encoding: .utf8)! } ?? "[]"
        let json = """
            {"id": \(id), "name": "歌单\(id)", "trackCount": \(trackIDs.count), \
            "trackIds": [\(trackIDsJSON)], "tracks": \(tracksJSON)}
            """
        return try! JSONDecoder().decode(PlaylistDetail.self, from: Data(json.utf8))
    }

    /// Serves every requested ID as a track plus its privilege.
    private func stubSongDetails(_ provider: inout MockMusicProvider) {
        provider.songDetailsHandler = { ids in
            ids.map { Self.makeSongWithPrivilege(Int($0.sourceID)!) }
        }
    }

    // MARK: - Loading

    /// The detail response carries the first batch inline; the rest are paged
    /// in, and every privilege is folded into the map.
    func testLoadsDetailThenPagesTheRemainingTracks() async {
        var provider = MockMusicProvider()
        provider.playlistDetailHandler = { _ in
            PlaylistDetail(
                detail: Self.makeDetail(trackIDs: [10, 11, 12], tracks: [Self.makeSong(10)]),
                privileges: [Self.makePrivilege(10, 0)])
        }
        stubSongDetails(&provider)
        let store = TestStore(initialState: PlaylistDetailFeature.State(playlistID: 1)) {
            PlaylistDetailFeature()
        } withDependencies: {
            $0.musicProvider = provider
        }
        await store.send(.onAppear) { $0.loadState = PlaylistDetailFeature.State.LoadState.loading }
        await store.receive(.detailResponse(
            playlist: PlaylistDetail(
                detail: Self.makeDetail(trackIDs: [10, 11, 12], tracks: [Self.makeSong(10)]),
                privileges: [Self.makePrivilege(10, 0)]),
            privileges: [Self.makePrivilege(10, 0)]
        )) {
            $0.detail = PlaylistDetail(
                detail: Self.makeDetail(trackIDs: [10, 11, 12], tracks: [Self.makeSong(10)]),
                privileges: [Self.makePrivilege(10, 0)])
            $0.tracks = [Self.makeSong(10)]
            $0.privileges = [10: Self.makePrivilege(10, 0)]
            $0.loadState = PlaylistDetailFeature.State.LoadState.loaded
        }
        await store.receive(.isLoadingMoreChanged(true)) { $0.isLoadingMore = true }
        await store.receive(.chunkLoaded(songs: [Self.makeSongWithPrivilege(11), Self.makeSongWithPrivilege(12)], privileges: [
            Self.makePrivilege(11, 0), Self.makePrivilege(12, 0),
        ])) {
            $0.tracks = [Self.makeSong(10), Self.makeSongWithPrivilege(11), Self.makeSongWithPrivilege(12)]
            $0.privileges = [
                10: Self.makePrivilege(10, 0),
                11: Self.makePrivilege(11, 0),
                12: Self.makePrivilege(12, 0),
            ]
        }
        await store.receive(.chunksFinished) { $0.isLoadingMore = false }
        XCTAssertEqual(store.state.tracks.count, 3)
    }

    /// A short playlist does not page at all.
    func testShortPlaylistSkipsTheChunks() async {
        var provider = MockMusicProvider()
        provider.playlistDetailHandler = { _ in
            PlaylistDetail(
                detail: Self.makeDetail(trackIDs: [10], tracks: [Self.makeSong(10)]),
                privileges: nil)
        }
        stubSongDetails(&provider)
        let store = TestStore(initialState: PlaylistDetailFeature.State(playlistID: 1)) {
            PlaylistDetailFeature()
        } withDependencies: {
            $0.musicProvider = provider
        }
        await store.send(.onAppear) { $0.loadState = PlaylistDetailFeature.State.LoadState.loading }
        await store.receive(.detailResponse(
            playlist: Self.makeDetail(trackIDs: [10], tracks: [Self.makeSong(10)]),
            privileges: nil
        )) {
            $0.detail = Self.makeDetail(trackIDs: [10], tracks: [Self.makeSong(10)])
            $0.tracks = [Self.makeSong(10)]
            $0.loadState = PlaylistDetailFeature.State.LoadState.loaded
        }
        XCTAssertFalse(store.state.isLoadingMore)
    }

    /// A failed load with nothing to show surfaces the error; with cached
    /// tracks the old content stays put.
    func testFailedLoadSurfacesErrorOnlyWhenEmpty() async {
        let error = URLError(.badServerResponse)
        var provider = MockMusicProvider()
        provider.playlistDetailHandler = { _ in throw error }
        let store = TestStore(initialState: PlaylistDetailFeature.State(playlistID: 1)) {
            PlaylistDetailFeature()
        } withDependencies: {
            $0.musicProvider = provider
        }
        await store.send(.onAppear) { $0.loadState = PlaylistDetailFeature.State.LoadState.loading }
        await store.receive(.loadFailed(error.localizedDescription)) {
            $0.loadState = PlaylistDetailFeature.State.LoadState.error(error.localizedDescription)
        }

        // A reload keeps the page as-is; the refetch happens behind it.
        var state = PlaylistDetailFeature.State(playlistID: 1)
        state.detail = Self.makeDetail(trackIDs: [10], tracks: [Self.makeSong(10)])
        state.tracks = [Self.makeSong(10)]
        state.loadState = PlaylistDetailFeature.State.LoadState.loaded
        var retryProvider = MockMusicProvider()
        retryProvider.playlistDetailHandler = { _ in throw error }
        let store2 = TestStore(initialState: state) {
            PlaylistDetailFeature()
        } withDependencies: {
            $0.musicProvider = retryProvider
        }
        await store2.send(.reload)
        await store2.receive(.loadFailed(error.localizedDescription))
        XCTAssertEqual(store2.state.loadState, .loaded)
    }

    // MARK: - Filter

    func testFilterMatchesNameArtistAndAlbum() async {
        var state = PlaylistDetailFeature.State(playlistID: 1)
        state.tracks = [
            Self.makeSong(1),  // 歌曲1 / 歌手 / 专辑1
        ]
        var provider = MockMusicProvider()
        provider.playlistDetailHandler = { _ in throw URLError(.badServerResponse) }
        let store = TestStore(initialState: state) { PlaylistDetailFeature() } withDependencies: {
            $0.musicProvider = provider
        }
        await store.send(.setFilter("歌曲1")) { $0.filter = "歌曲1" }
        XCTAssertEqual(store.state.filteredTracks.map(\.id), [1])
        await store.send(.setFilter("歌手")) { $0.filter = "歌手" }
        XCTAssertEqual(store.state.filteredTracks.map(\.id), [1])
        await store.send(.setFilter("专辑1")) { $0.filter = "专辑1" }
        XCTAssertEqual(store.state.filteredTracks.map(\.id), [1])
        await store.send(.setFilter("不存在")) { $0.filter = "不存在" }
        XCTAssertTrue(store.state.filteredTracks.isEmpty)
    }

    // MARK: - Playability

    /// Without unblock, a VIP-only track is left out of 播放全部; with unblock
    /// on, everything is offered.
    func testPlayableTracksRespectsUnblockAndVIP() async {
        var state = PlaylistDetailFeature.State(playlistID: 1)
        state.tracks = [Self.makeSong(1, 1), Self.makeSong(2, 0)]
        state.privileges = [1: Self.makePrivilege(1, 1), 2: Self.makePrivilege(2, 0)]
        state.isLoggedIn = true
        state.vipType = 0
        var provider = MockMusicProvider()
        provider.playlistDetailHandler = { _ in throw URLError(.badServerResponse) }
        let store = TestStore(initialState: state) { PlaylistDetailFeature() } withDependencies: {
            $0.musicProvider = provider
        }
        XCTAssertEqual(store.state.playableTracks.map(\.id), [2])
        // VIP unlocks the paid track.
        var vipState = state
        vipState.vipType = 11
        var vipProvider = MockMusicProvider()
        vipProvider.playlistDetailHandler = { _ in throw URLError(.badServerResponse) }
        let vipStore = TestStore(initialState: vipState) { PlaylistDetailFeature() } withDependencies: {
            $0.musicProvider = vipProvider
        }
        XCTAssertEqual(vipStore.state.playableTracks.map(\.id), [1, 2])
        // Unblock includes everything regardless.
        var unblockState = state
        unblockState.enableUnblock = true
        var unblockProvider = MockMusicProvider()
        unblockProvider.playlistDetailHandler = { _ in throw URLError(.badServerResponse) }
        let unblockStore = TestStore(initialState: unblockState) { PlaylistDetailFeature() } withDependencies: {
            $0.musicProvider = unblockProvider
        }
        XCTAssertEqual(unblockStore.state.playableTracks.map(\.id), [1, 2])
    }

    // MARK: - Track list edits

    func testTrackRemovedDropsTheTrack() async {
        var state = PlaylistDetailFeature.State(playlistID: 1)
        state.tracks = [Self.makeSong(1), Self.makeSong(2)]
        var provider = MockMusicProvider()
        provider.playlistDetailHandler = { _ in throw URLError(.badServerResponse) }
        let store = TestStore(initialState: state) { PlaylistDetailFeature() } withDependencies: {
            $0.musicProvider = provider
        }
        await store.send(.trackRemoved(Self.makeSong(1))) {
            $0.tracks = [Self.makeSong(2)]
        }
    }

    /// A rejected recommendation is swapped out and kept out of later chunks.
    func testRejectedRecommendationStaysOutOfLaterLoads() async {
        var state = PlaylistDetailFeature.State(playlistID: 1)
        state.tracks = [Self.makeSong(1), Self.makeSong(2)]
        var provider = MockMusicProvider()
        provider.playlistDetailHandler = { _ in throw URLError(.badServerResponse) }
        let store = TestStore(initialState: state) { PlaylistDetailFeature() } withDependencies: {
            $0.musicProvider = provider
        }
        await store.send(.recommendationReduced(
            rejected: Self.makeSong(1), replacement: Self.makeSong(3)
        )) {
            $0.tracks = [Self.makeSong(3), Self.makeSong(2)]
            $0.reducedRecommendationIDs = [1]
        }
        // A later chunk sneaking track 1 back in is filtered.
        await store.send(.chunkLoaded(songs: [Self.makeSong(1), Self.makeSong(4)], privileges: [])) {
            $0.tracks = [Self.makeSong(3), Self.makeSong(2), Self.makeSong(4)]
        }
    }

    // MARK: - Subscribe

    /// The toggle is optimistic; success just confirms it and refreshes the
    /// library.
    func testSubscribeOptimisticThenConfirmed() async {
        var state = PlaylistDetailFeature.State(playlistID: 1)
        state.detail = Self.makeDetail(trackIDs: [], tracks: [])
        var provider = MockMusicProvider()
        provider.subscribePlaylistHandler = { _, _ in }
        let store = TestStore(initialState: state) { PlaylistDetailFeature() } withDependencies: {
            $0.musicProvider = provider
        }
        await store.send(.toggleSubscribe) {
            $0.detail?.subscribed = true
        }
        await store.receive(.delegate(.subscriptionChanged))
        XCTAssertTrue(store.state.detail?.subscribed ?? false)
    }

    func testSubscribeFailureRollsBackAndToasts() async {
        let error = URLError(.notConnectedToInternet)
        var state = PlaylistDetailFeature.State(playlistID: 1)
        state.detail = Self.makeDetail(trackIDs: [], tracks: [])
        var provider = MockMusicProvider()
        provider.subscribePlaylistHandler = { _, _ in throw error }
        let store = TestStore(initialState: state) { PlaylistDetailFeature() } withDependencies: {
            $0.musicProvider = provider
        }
        await store.send(.toggleSubscribe) {
            $0.detail?.subscribed = true
        }
        await store.receive(.subscribeReverted(to: false)) {
            $0.detail?.subscribed = false
        }
        await store.receive(.delegate(.toast(error.localizedDescription)))
        XCTAssertFalse(store.state.detail?.subscribed ?? true)
    }

    // MARK: - Heartbeat

    /// 心动模式 seeds off a playable track and hands the result to the player.
    func testHeartbeatPlaysTheIntelligentList() async {
        var state = PlaylistDetailFeature.State(playlistID: 7)
        state.tracks = [Self.makeSong(1)]
        state.enableUnblock = true
        var provider = MockMusicProvider()
        provider.intelligenceListHandler = { _, _ in [Self.makeSong(20), Self.makeSong(21)] }
        let store = TestStore(initialState: state) { PlaylistDetailFeature() } withDependencies: {
            $0.musicProvider = provider
            $0.intelligence = provider
        }
        await store.send(.startHeartbeat)
        await store.receive(.delegate(.play(
            tracks: [Self.makeSong(20), Self.makeSong(21)],
            source: .playlist(7),
            startAt: nil,
            context: .heartbeat
        )))
        await store.receive(.delegate(.toast(String(localized: "已开启心动模式"))))
    }

    /// Nothing intelligent came back: keep the queue and say so.
    func testHeartbeatWithNoResultsToastsUnavailable() async {
        var state = PlaylistDetailFeature.State(playlistID: 7)
        state.tracks = [Self.makeSong(1)]
        state.enableUnblock = true
        var provider = MockMusicProvider()
        provider.intelligenceListHandler = { _, _ in [] }
        let store = TestStore(initialState: state) { PlaylistDetailFeature() } withDependencies: {
            $0.musicProvider = provider
            $0.intelligence = provider
        }
        await store.send(.startHeartbeat)
        await store.receive(.delegate(.toast(String(localized: "心动模式暂时不可用"))))
    }

    /// Nothing playable to seed from: no request at all.
    func testHeartbeatWithoutPlayableTracksIsSkipped() async {
        var provider = MockMusicProvider()
        provider.intelligenceListHandler = { _, _ in [Self.makeSong(20)] }
        let store = TestStore(initialState: PlaylistDetailFeature.State(playlistID: 7)) {
            PlaylistDetailFeature()
        } withDependencies: {
            $0.musicProvider = provider
            $0.intelligence = provider
        }
        await store.send(.startHeartbeat)
    }
    func testWhitespaceFilterReturnsAllTracks() async {
        var state = PlaylistDetailFeature.State(playlistID: 1)
        state.tracks = [Self.makeSong(1), Self.makeSong(2)]
        let store = TestStore(initialState: state) { PlaylistDetailFeature() } withDependencies: {
            $0.musicProvider = MockMusicProvider()
        }
        XCTAssertEqual(store.state.filteredTracks, state.tracks)
        await store.send(.setFilter("   ")) { $0.filter = "   " }
        XCTAssertEqual(store.state.filteredTracks, state.tracks)
    }

    func testNonIdleAppearanceAndSubscribeWithoutDetailDoNothing() async {
        for loadState in [PlaylistDetailFeature.State.LoadState.loading, .loaded, .error("offline")] {
            var state = PlaylistDetailFeature.State(playlistID: 1)
            state.loadState = loadState
            let store = TestStore(initialState: state) { PlaylistDetailFeature() } withDependencies: {
                $0.musicProvider = MockMusicProvider()
            }
            await store.send(.onAppear)
            await store.send(.toggleSubscribe)
        }
    }

    func testChunkWithoutPrivilegesPreservesExistingPrivileges() async {
        let detail = Self.makeDetail(trackIDs: [10, 11], tracks: [Self.makeSong(10)])
        let privilege = Self.makePrivilege(10, 0)
        var provider = MockMusicProvider()
        provider.playlistDetailHandler = { id in
            XCTAssertEqual(id, MusicID(1))
            return PlaylistDetail(detail: detail, privileges: [privilege])
        }
        provider.songDetailsHandler = { ids in
            XCTAssertEqual(ids, [MusicID(11)])
            return [Self.makeSong(11)]
        }
        let store = TestStore(initialState: PlaylistDetailFeature.State(playlistID: 1)) {
            PlaylistDetailFeature()
        } withDependencies: {
            $0.musicProvider = provider
        }
        await store.send(.onAppear) { $0.loadState = .loading }
        await store.receive(.detailResponse(
            playlist: PlaylistDetail(detail: detail, privileges: [privilege]), privileges: [privilege])) {
            $0.detail = PlaylistDetail(detail: detail, privileges: [privilege])
            $0.tracks = [Self.makeSong(10)]
            $0.privileges = [10: privilege]
            $0.loadState = .loaded
        }
        await store.receive(.isLoadingMoreChanged(true)) { $0.isLoadingMore = true }
        await store.receive(.chunkLoaded(songs: [Self.makeSong(11)], privileges: [])) {
            $0.tracks.append(Self.makeSong(11))
        }
        await store.receive(.chunksFinished) { $0.isLoadingMore = false }
    }

    func testHeartbeatFailureToastsProviderError() async {
        let error = URLError(.notConnectedToInternet)
        var state = PlaylistDetailFeature.State(playlistID: 7)
        state.tracks = [Self.makeSong(1)]
        state.enableUnblock = true
        var provider = MockMusicProvider()
        provider.intelligenceListHandler = { songID, playlistID in
            XCTAssertEqual(songID, MusicID(1))
            XCTAssertEqual(playlistID, MusicID(7))
            throw error
        }
        let store = TestStore(initialState: state) { PlaylistDetailFeature() } withDependencies: {
            $0.musicProvider = provider
            $0.intelligence = provider
        }
        await store.send(.startHeartbeat)
        await store.receive(.delegate(.toast(error.localizedDescription)))
    }

    func testFirstRemainingChunkFailureStopsBeforeLaterChunks() async {
        let first = Self.makeSong(1)
        let detail = Self.makeDetail(
            trackIDs: Array(1...(PlaylistDetailFeature.chunkSize + 2)), tracks: [first])
        var state = PlaylistDetailFeature.State(playlistID: 1)
        state.detail = detail
        state.tracks = [first]
        state.loadState = .loaded
        nonisolated(unsafe) var requests: [[MusicID]] = []
        var provider = MockMusicProvider()
        provider.songDetailsHandler = { ids in
            requests.append(ids)
            if requests.count == 1 { throw URLError(.timedOut) }
            return ids.map { Self.makeSong(Int($0.sourceID)!) }
        }
        let store = TestStore(initialState: state) { PlaylistDetailFeature() } withDependencies: {
            $0.musicProvider = provider
        }
        await store.send(.detailResponse(playlist: detail, privileges: nil))
        await store.receive(.isLoadingMoreChanged(true)) { $0.isLoadingMore = true }
        await store.receive(.chunksFinished) { $0.isLoadingMore = false }
        await store.finish()
        XCTAssertEqual(requests, [(2...(PlaylistDetailFeature.chunkSize + 1)).map(MusicID.init)])
        XCTAssertEqual(store.state.tracks, [first])
    }

}
