import ComposableArchitecture
import Dependencies
import Foundation
@testable import KumoneCore
@testable import KumoneTCA
import XCTest

@MainActor
final class PlayerFeatureTests: XCTestCase {
    nonisolated static func track(_ id: Int, _ name: String, durationMS: Int = 200_000) -> Track {
        Track(
            id: id, name: name, artists: [],
            album: AlbumRef(id: 0, name: "Album", picUrl: nil),
            durationMS: durationMS, alias: [], transNames: [], fee: 0, mvID: 0, trackNo: 0,
            disc: nil, noCopyright: false, isCloud: false, embeddedPrivilege: nil)
    }

    nonisolated static let t1 = track(1, "one")
    nonisolated static let t2 = track(2, "two")
    nonisolated static let t3 = track(3, "three")

    nonisolated static func emptyLyrics() -> LyricResponse {
        LyricResponse(lrc: nil, tlyric: nil, romalrc: nil, yrc: nil, ytlrc: nil,
                      yromalrc: nil, lyricUser: nil, transUser: nil, nolyric: nil,
                      uncollected: nil)
    }

    /// Mocks every dependency an unblocked resolve touches, so a test that just
    /// wants queue logic can ignore the engine.
    private func configureResolve(_ deps: inout DependencyValues) {
        var provider = MockMusicProvider()
        provider.songURLHandler = { _, _ in
            [SongURLData(id: 1, url: "https://example.com/a", br: 0, size: 0, type: nil,
                         level: "exhigh", fee: 0, freeTrialInfo: nil, time: 200)]
        }
        provider.lyricHandler = { _ in Self.emptyLyrics() }
        provider.scrobbleStartHandler = { _, _ in }
        provider.scrobbleFinishHandler = { _, _, _ in }
        deps.musicProvider = provider
        deps.persistence.setData = { _, _ in }
        // Fire-and-forget no-ops — the tests assert state, not engine calls.
        // (@DependencyClient's default init traps on any call, so every closure
        // is spelled out.)
        deps.playback = PlaybackEngineClient(
            load: { _, _, _ in },
            play: {},
            pause: {},
            seek: { _ in },
            setVolume: { _ in },
            clear: {},
            updateMetadata: { _, _, _, _ in },
            currentTime: { 0 },
            timeTicks: { .never },
            itemEnded: { .never },
            bufferingChanged: { .never },
            isPlayingChanged: { .never })
        // No third-party source will ever be needed; returning nil keeps the
        // resolve flowing down the normal NetEase path.
        deps.unblock = UnblockClient(resolve: { _ in nil })
    }

    func testTrackChangeIgnoresOutgoingTicksBeforeNewLyricsArrive() async {
        let response = LyricResponse(
            lrc: LyricResponse.LyricBody(lyric: "[00:00.00]First\n[00:10.00]Second\n[00:20.00]Third"),
            tlyric: nil, romalrc: nil, yrc: nil, ytlrc: nil, yromalrc: nil,
            lyricUser: nil, transUser: nil, nolyric: nil, uncollected: nil)
        let lyrics = LyricsParser.parse(response)
        var state = PlayerFeature.State(queue: [Self.t1, Self.t2], currentIndex: 0)
        state.currentTrack = Self.t1
        state.duration = 200
        state.progress = 25
        state.lyrics = lyrics
        state.lyricsCursorIndex = 2
        state.engineHasItem = true
        state.resolveGeneration = 1
        let clock = TestClock()
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            var provider = $0.musicProvider as! MockMusicProvider
            provider.lyricHandler = { _ in
                try await clock.sleep(for: .seconds(1))
                return response
            }
            let songURL = provider.songURLHandler
            provider.songURLHandler = { ids, quality in
                try await clock.sleep(for: .seconds(2))
                return try await songURL(ids, quality)
            }
            $0.musicProvider = provider
        }

        await store.send(.next)
        await store.receive(\.advanceToNext) {
            $0.playbackIntent = true
            $0.currentIndex = 1
        }
        await store.receive(\.startPlaying) {
            $0.currentTrack = Self.t2
            $0.progress = 0
            $0.lyrics = nil
            $0.lyricsCursorIndex = nil
            $0.engineHasItem = false
            $0.isPlaying = true
            $0.resolveGeneration = 2
        }
        // The outgoing engine keeps emitting while the new URL is resolving.
        await store.send(.timeTick(26))
        await store.send(.lyricsResponse(generation: 1, lyrics))
        await clock.advance(by: .seconds(1))
        await store.receive(\.lyricsResponse) {
            $0.lyrics = lyrics
            $0.lyricsCursorIndex = 0
        }
        await clock.advance(by: .seconds(1))
        await store.receive(\.urlResolved) {
            $0.servedQuality = "exhigh"
            $0.engineHasItem = true
            $0.startScrobbled = true
        }
        await store.send(.timeTick(11)) {
            $0.progress = 11
            $0.lyricsCursorIndex = 1
        }
    }

    func testLateLyricsFollowNewPlaybackAndIntroKeepsCursorNil() async {
        let lyrics = LyricsParser.parse(LyricResponse(
            lrc: LyricResponse.LyricBody(lyric: "[00:05.00]First\n[00:10.00]Second"),
            tlyric: nil, romalrc: nil, yrc: nil, ytlrc: nil, yromalrc: nil,
            lyricUser: nil, transUser: nil, nolyric: nil, uncollected: nil))
        var state = PlayerFeature.State()
        state.currentTrack = Self.t2
        state.engineHasItem = true
        state.resolveGeneration = 2
        let store = TestStore(initialState: state) { PlayerFeature() }
        // nil means no sung line yet; the UI should still position the first row.
        await store.send(.lyricsResponse(generation: 2, lyrics)) {
            $0.lyrics = lyrics
        }
        await store.send(.timeTick(11)) {
            $0.progress = 11
            $0.lyricsCursorIndex = 1
        }
        await store.send(.lyricsResponse(generation: 2, lyrics))
    }

    // MARK: - Queue entry points

    func testPlayStartsAtRequestedTrack() async {
        let store = TestStore(initialState: PlayerFeature.State()) {
            PlayerFeature()
        } withDependencies: {
            configureResolve(&$0)
        }
        await store.send(.play(tracks: [Self.t1, Self.t2], source: .playlist(9), startAt: Self.t2, context: nil)) {
            $0.queue = [Self.t1, Self.t2]
            $0.source = .playlist(9)
            $0.playbackIntent = true
            $0.currentIndex = 1
        }
        await store.receive(\.startPlaying) {
            $0.currentTrack = Self.t2
            $0.duration = Self.t2.duration
            $0.isPlaying = true
            $0.resolveGeneration = 1
        }
        await store.receive(\.lyricsResponse) {
            $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
        }
        await store.receive(\.urlResolved) {
            $0.servedQuality = "exhigh"
            $0.engineHasItem = true
            $0.startScrobbled = true
        }
    }

    func testPlayTrackQueuesAloneWhenUnknown() async {
        let store = TestStore(initialState: PlayerFeature.State()) {
            PlayerFeature()
        } withDependencies: {
            configureResolve(&$0)
        }
        await store.send(.playTrack(Self.t1)) {
            $0.playbackIntent = true
        }
        await store.receive(\.play) {
            $0.queue = [Self.t1]
            $0.currentIndex = 0
        }
        await store.receive(\.startPlaying) {
            $0.currentTrack = Self.t1
            $0.duration = Self.t1.duration
            $0.isPlaying = true
            $0.resolveGeneration = 1
        }
        await store.receive(\.lyricsResponse) {
            $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
        }
        await store.receive(\.urlResolved) {
            $0.servedQuality = "exhigh"
            $0.engineHasItem = true
            $0.startScrobbled = true
        }
    }

    func testPlayTrackJumpsWhenAlreadyQueued() async {
        var state = PlayerFeature.State(queue: [Self.t1, Self.t2], currentIndex: 0)
        state.currentTrack = Self.t1
        let store = TestStore(initialState: state) {
            PlayerFeature()
        } withDependencies: {
            configureResolve(&$0)
        }
        await store.send(.playTrack(Self.t2)) {
            $0.playbackIntent = true
            $0.currentIndex = 1
        }
        await store.receive(\.startPlaying) {
            $0.currentTrack = Self.t2
            $0.duration = Self.t2.duration
            $0.isPlaying = true
            $0.resolveGeneration = 1
        }
        await store.receive(\.lyricsResponse) {
            $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
        }
        await store.receive(\.urlResolved) {
            $0.servedQuality = "exhigh"
            $0.engineHasItem = true
            $0.startScrobbled = true
        }
    }

    // MARK: - Shuffle / repeat

    func testUnshuffleRestoresQueueIndex() async {
        var state = PlayerFeature.State(queue: [Self.t1, Self.t2, Self.t3], currentIndex: 1)
        state.currentTrack = Self.t2
        state.shuffleEnabled = true
        state.shuffledQueue = [Self.t2, Self.t1, Self.t3]
        let store = TestStore(initialState: state) { PlayerFeature() }
        await store.send(.toggleShuffle) {
            $0.shuffleEnabled = false
            $0.currentIndex = 1
        }
    }

    func testRepeatModeCycles() async {
        let store = TestStore(initialState: PlayerFeature.State()) { PlayerFeature() }
        await store.send(.cycleRepeatMode) { $0.repeatMode = .all }
        await store.send(.cycleRepeatMode) { $0.repeatMode = .one }
        await store.send(.cycleRepeatMode) { $0.repeatMode = .off }
    }

    // MARK: - Advancing

    func testNextTellsUserAtEndOfList() async {
        var state = PlayerFeature.State(queue: [Self.t1], currentIndex: 0)
        state.currentTrack = Self.t1
        state.isPlaying = true
        state.engineHasItem = true
        let store = TestStore(initialState: state) { PlayerFeature() }
        await store.send(.next)
        await store.receive(\.advanceToNext) {
            $0.playbackIntent = true
        }
        await store.receive(\.toast)
    }

    func testNextWrapsAroundWithRepeatAll() async {
        var state = PlayerFeature.State(queue: [Self.t1, Self.t2], currentIndex: 1)
        state.currentTrack = Self.t2
        state.isPlaying = true
        state.engineHasItem = true
        state.repeatMode = .all
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
        }
        await store.send(.next)
        await store.receive(\.advanceToNext) {
            $0.playbackIntent = true
            $0.currentIndex = 0
        }
        await store.receive(\.startPlaying) {
            $0.currentTrack = Self.t1
            $0.duration = Self.t1.duration
            $0.engineHasItem = false
            $0.resolveGeneration = 1
        }
        await store.receive(\.lyricsResponse) {
            $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
        }
        await store.receive(\.urlResolved) {
            $0.servedQuality = "exhigh"
            $0.engineHasItem = true
            $0.startScrobbled = true
        }
    }

    // APlay reports `isPlaying=false` for the end-of-item transition, and that
    // event can land before `itemEnded` (or after the next track's
    // `startPlaying`). The queue must still advance, and the next track must
    // still autostart — the load must not silently degrade to prepare-only.
    func testItemEndedAdvancesPastTheEnginePauseEvent() async {
        var state = PlayerFeature.State(queue: [Self.t1, Self.t2], currentIndex: 0)
        state.currentTrack = Self.t1
        state.isPlaying = true
        state.playbackIntent = true
        state.engineHasItem = true
        nonisolated(unsafe) var loads: [(url: URL, autostart: Bool)] = []
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            $0.playback.load = { url, autostart, _ in loads.append((url, autostart)) }
        }
        // The engine's end-of-item pause arrives first.
        await store.send(.isPlayingChanged(false)) {
            $0.isPlaying = false
        }
        await store.send(.itemEnded)
        await store.receive(\.advanceToNext) {
            $0.currentIndex = 1
        }
        await store.receive(\.startPlaying) {
            $0.currentTrack = Self.t2
            $0.duration = Self.t2.duration
            $0.isPlaying = true
            $0.engineHasItem = false
            $0.startScrobbled = false
            $0.resolveGeneration = 1
        }
        await store.receive(\.lyricsResponse) {
            $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
        }
        await store.receive(\.urlResolved) {
            $0.servedQuality = "exhigh"
            $0.engineHasItem = true
            $0.startScrobbled = true
        }
        XCTAssertEqual(loads.count, 1)
        XCTAssertTrue(loads.first?.autostart == true)
    }

    // Netease lyrics routinely carry timestamps past the real stream length,
    // and a jump is an explicit "keep playing" gesture: the target is pulled
    // back from the very end so the engine's end-of-track detection cannot
    // fire a second later, and the queue's intent follows the user, not the
    // engine's state mirror.
    func testSeekClampsPastDurationAndMarksIntent() async {
        var state = PlayerFeature.State()
        state.currentTrack = Self.t1
        state.duration = 200
        nonisolated(unsafe) var seekTargets: [TimeInterval] = []
        let t0 = Date(timeIntervalSince1970: 1000)
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            $0.date = .constant(t0)
            $0.playback.seek = { seekTargets.append($0) }
        }
        await store.send(.seek(250)) {
            $0.progress = 198.5
            $0.playbackIntent = true
            $0.isPlaying = true
            $0.pendingSeekTarget = 198.5
            $0.seekGuardUntil = t0.addingTimeInterval(3)
        }
        XCTAssertEqual(seekTargets, [198.5])
    }

    func testSeekBackWhileBufferingExplicitlyResumesWithoutItemEnded() async {
        var state = PlayerFeature.State(queue: [Self.t1, Self.t2], currentIndex: 0)
        state.currentTrack = Self.t1
        state.duration = 200
        state.progress = 10
        state.isPlaying = true
        state.playbackIntent = true
        state.engineHasItem = true
        let commands = LockIsolated<[String]>([])
        let t0 = Date(timeIntervalSince1970: 1000)
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            $0.date = .constant(t0)
            $0.playback.seek = { seconds in
                commands.withValue { $0.append("seek:\(seconds)") }
            }
            $0.playback.play = { commands.withValue { $0.append("play") } }
            $0.playback.pause = { commands.withValue { $0.append("pause") } }
        }

        await store.send(.bufferingChanged(0.2)) {
            $0.bufferProgress = 0.2
        }
        await store.send(.seek(150)) {
            $0.progress = 150
            $0.pendingSeekTarget = 150
            $0.seekGuardUntil = t0.addingTimeInterval(3)
        }
        await store.send(.isPlayingChanged(false)) {
            $0.isPlaying = false
        }
        await store.send(.bufferingChanged(0.25)) {
            $0.bufferProgress = 0.25
            $0.isBuffering = true
        }
        // No itemEnded arrives while APlay is still waiting for the stream.
        await store.send(.seek(5)) {
            $0.progress = 5
            $0.isPlaying = true
            $0.pendingSeekTarget = 5
        }
        await store.finish()
        // Optimistic isPlaying=true alone is insufficient: the engine must
        // actually receive a resume after rebuilding the seek's composer.
        XCTAssertEqual(commands.value, ["seek:150.0", "play", "seek:5.0", "play"])
        XCTAssertEqual(store.state.currentTrack?.id, Self.t1.id)
        XCTAssertEqual(store.state.currentIndex, 0)

        await store.send(.pause) {
            $0.isPlaying = false
            $0.playbackIntent = false
            $0.pendingSeekTarget = nil
            $0.seekGuardUntil = nil
        }
        await store.send(.isPlayingChanged(false))
        await store.finish()
        XCTAssertEqual(commands.value.last, "pause")
    }

    // A jump that lands past the real stream length — or one whose ranged
    // re-download stalls long enough for the engine's frozen-time end
    // detection to trip — reports end-of-item before playback ever moved on.
    // That end is the jump, not the song finishing: playback picks back up
    // where the jump landed instead of advancing the queue.
    func testItemEndedRightAfterASeekResumes() async {
        var state = PlayerFeature.State(queue: [Self.t1, Self.t2], currentIndex: 0)
        state.currentTrack = Self.t1
        state.duration = 200
        state.isPlaying = true
        state.playbackIntent = true
        state.progress = 30
        state.pendingSeekTarget = 30
        state.engineHasItem = true
        nonisolated(unsafe) var resumed = false
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            $0.playback.play = { resumed = true }
        }
        await store.send(.itemEnded) {
            $0.scrobbled = true
            $0.pendingSeekTarget = nil
            $0.startScrobbled = true
        }
        XCTAssertTrue(resumed)
    }

    // The real field sequence: a jump backwards, the playhead reaching the
    // target (which clears the pending marker), a network stall that pauses the
    // engine, and the frozen-time end detection firing *after* all of that.
    // With the duration known, the position check still catches it.
    func testLateItemEndedAfterASettledBackwardSeekResumes() async {
        var state = PlayerFeature.State(queue: [Self.t1, Self.t2], currentIndex: 0)
        state.currentTrack = Self.t1
        state.duration = 200
        state.isPlaying = true
        state.playbackIntent = true
        state.progress = 100
        state.engineHasItem = true
        nonisolated(unsafe) var resumed = false
        let t0 = Date(timeIntervalSince1970: 1000)
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            $0.date = .constant(t0)
            $0.playback.seek = { _ in }
            $0.playback.play = { resumed = true }
        }
        await store.send(.seek(30)) {
            $0.progress = 30
            $0.playbackIntent = true
            $0.isPlaying = true
            $0.pendingSeekTarget = 30
            $0.seekGuardUntil = t0.addingTimeInterval(3)
        }
        await store.send(.timeTick(31)) {
            $0.progress = 31
            $0.pendingSeekTarget = nil
        }
        await store.send(.isPlayingChanged(false)) {
            $0.isPlaying = false
        }
        await store.send(.itemEnded) {
            $0.scrobbled = true
            $0.startScrobbled = true
            $0.isPlaying = true
        }
        XCTAssertTrue(resumed)
    }

    // Same sequence with the duration unknown — a track whose length the API
    // never reported. The position check has nothing to compare against, so a
    // late end used to slip past it and advance the queue: the field report of
    // a seek that still skips. The jump's own grace window is what has to
    // carry this case.
    func testLateItemEndedWithUnknownDurationDoesNotAdvance() async {
        var state = PlayerFeature.State(queue: [Self.t1, Self.t2], currentIndex: 0)
        state.currentTrack = Self.t1
        state.duration = 0
        state.isPlaying = true
        state.playbackIntent = true
        state.progress = 100
        state.engineHasItem = true
        nonisolated(unsafe) var resumed = false
        let t0 = Date(timeIntervalSince1970: 1000)
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            $0.date = .constant(t0)
            $0.playback.seek = { _ in }
            $0.playback.play = { resumed = true }
        }
        await store.send(.seek(30)) {
            $0.progress = 30
            $0.playbackIntent = true
            $0.isPlaying = true
            $0.pendingSeekTarget = 30
            $0.seekGuardUntil = t0.addingTimeInterval(3)
        }
        await store.send(.timeTick(31)) {
            $0.progress = 31
            $0.pendingSeekTarget = nil
        }
        await store.send(.isPlayingChanged(false)) {
            $0.isPlaying = false
        }
        await store.send(.itemEnded) {
            $0.scrobbled = true
            $0.startScrobbled = true
            $0.isPlaying = true
        }
        XCTAssertTrue(resumed)
    }

    // Once playback has genuinely moved on from a jump, a later end-of-item is
    // the song finishing and the queue advances as normal.
    func testTimeTickClearsASettledSeek() async {
        var state = PlayerFeature.State(queue: [Self.t1, Self.t2], currentIndex: 0)
        state.currentTrack = Self.t1
        state.duration = 200
        state.isPlaying = true
        state.playbackIntent = true
        state.progress = 30
        state.pendingSeekTarget = 30
        state.engineHasItem = true
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
        }
        await store.send(.timeTick(199)) {
            $0.progress = 199
            $0.pendingSeekTarget = nil
        }
        await store.send(.itemEnded) {
            $0.scrobbled = true
        }
        await store.receive(\.advanceToNext) {
            $0.currentIndex = 1
        }
        await store.receive(\.startPlaying) {
            $0.currentTrack = Self.t2
            $0.duration = Self.t2.duration
            $0.progress = 0
            $0.lyrics = nil
            $0.lyricsCursorIndex = nil
            $0.scrobbled = false
            $0.startScrobbled = false
            $0.isPlaying = true
            $0.engineHasItem = false
            $0.bufferProgress = 0
            $0.pendingSeekTarget = nil
            $0.resolveGeneration = 1
        }
        await store.receive(\.lyricsResponse) {
            $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
        }
        await store.receive(\.urlResolved) {
            $0.servedQuality = "exhigh"
            $0.engineHasItem = true
            $0.startScrobbled = true
        }
    }

    func testPreviousRestartsTrackWhenFarIn() async {
        var state = PlayerFeature.State(queue: [Self.t1, Self.t2], currentIndex: 1)
        state.currentTrack = Self.t2
        state.progress = 30
        state.isPlaying = true
        state.engineHasItem = true
        let t0 = Date(timeIntervalSince1970: 1000)
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            $0.date = .constant(t0)
        }
        await store.send(.previous)
        await store.receive(\.seek) {
            $0.progress = 0
            $0.playbackIntent = true
            $0.pendingSeekTarget = 0
            $0.seekGuardUntil = t0.addingTimeInterval(3)
        }
    }

    func testPreviousGoesBackWhenNearTheStart() async {
        var state = PlayerFeature.State(queue: [Self.t1, Self.t2], currentIndex: 1)
        state.currentTrack = Self.t2
        state.progress = 1
        state.isPlaying = true
        state.engineHasItem = true
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
        }
        await store.send(.previous) {
            $0.playbackIntent = true
            $0.currentIndex = 0
        }
        await store.receive(\.startPlaying) {
            $0.currentTrack = Self.t1
            $0.duration = Self.t1.duration
            $0.progress = 0
            $0.engineHasItem = false
            $0.resolveGeneration = 1
        }
        await store.receive(\.lyricsResponse) {
            $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
        }
        await store.receive(\.urlResolved) {
            $0.servedQuality = "exhigh"
            $0.engineHasItem = true
            $0.startScrobbled = true
        }
    }

    // MARK: - Play next list

    func testAddToPlayNextBumpsToCurrentWhenNothingIsPlaying() async {
        let store = TestStore(initialState: PlayerFeature.State()) {
            PlayerFeature()
        } withDependencies: {
            configureResolve(&$0)
        }
        await store.send(.addToPlayNext(Self.t1, playNow: false)) {
            $0.playNextList = [Self.t1]
        }
        await store.receive(\.advanceToNext) {
            $0.playNextList = []
            $0.playbackIntent = true
        }
        await store.receive(\.startPlaying) {
            $0.currentTrack = Self.t1
            $0.duration = Self.t1.duration
            $0.isPlaying = true
            $0.resolveGeneration = 1
        }
        await store.receive(\.lyricsResponse) {
            $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
        }
        await store.receive(\.urlResolved) {
            $0.servedQuality = "exhigh"
            $0.engineHasItem = true
            $0.startScrobbled = true
        }
    }

    func testJumpToConsumesThePlayNextPrefix() async {
        var state = PlayerFeature.State()
        state.playNextList = [Self.t1, Self.t2]
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
        }
        await store.send(.jumpTo(Self.t1)) {
            $0.playNextList = [Self.t2]
            $0.playbackIntent = true
        }
        await store.receive(\.startPlaying) {
            $0.currentTrack = Self.t1
            $0.duration = Self.t1.duration
            $0.isPlaying = true
            $0.resolveGeneration = 1
        }
        await store.receive(\.lyricsResponse) {
            $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
        }
        await store.receive(\.urlResolved) {
            $0.servedQuality = "exhigh"
            $0.engineHasItem = true
            $0.startScrobbled = true
        }
    }

    func testRemoveFromUpcomingDropsFromPlayNextList() async {
        var state = PlayerFeature.State()
        state.playNextList = [Self.t1, Self.t2]
        let store = TestStore(initialState: state) { PlayerFeature() }
        await store.send(.removeFromUpcoming(Self.t1)) {
            $0.playNextList = [Self.t2]
        }
    }

    // MARK: - Unplayable tracks

    func testUnplayableTrackStopsWhenNotPlaying() async {
        var state = PlayerFeature.State(queue: [Self.t1], currentIndex: 0)
        state.currentTrack = Self.t1
        state.resolveGeneration = 5
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
        }
        await store.send(.urlResolved(generation: 5, autostart: false, .init(url: nil, servedQuality: nil, isTrial: false, unblockSource: nil))) {
            $0.consecutiveFailures = 1
        }
        await store.receive(\.toast)
        await store.receive(\.stopPlayback)
    }

    func testUnplayableTrackSkipsAheadWhilePlaying() async {
        var state = PlayerFeature.State(queue: [Self.t1, Self.t2], currentIndex: 0)
        state.currentTrack = Self.t1
        state.isPlaying = true
        state.playbackIntent = true
        state.resolveGeneration = 5
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
        }
        await store.send(.urlResolved(generation: 5, autostart: true, .init(url: nil, servedQuality: nil, isTrial: false, unblockSource: nil))) {
            $0.consecutiveFailures = 1
        }
        await store.receive(\.toast)
        await store.receive(\.advanceToNext) {
            $0.playbackIntent = true
            $0.currentIndex = 1
        }
        await store.receive(\.startPlaying) {
            $0.currentTrack = Self.t2
            $0.duration = Self.t2.duration
            $0.resolveGeneration = 6
        }
        await store.receive(\.lyricsResponse) {
            $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
        }
        await store.receive(\.urlResolved) {
            $0.servedQuality = "exhigh"
            $0.engineHasItem = true
            $0.consecutiveFailures = 0
            $0.startScrobbled = true
        }
    }

    // MARK: - Scrobbling

    func testScrobbleFinishOnTrackChangeAndStartOnResolve() async {
        nonisolated(unsafe) var started: [(trackID: Int, sourceID: Int)] = []
        nonisolated(unsafe) var finished: [(trackID: Int, sourceID: Int, seconds: Int)] = []
        var state = PlayerFeature.State(queue: [Self.t1, Self.t2], currentIndex: 0)
        state.currentTrack = Self.t1
        state.source = .playlist(3)
        state.progress = 5
        state.isPlaying = true
        state.engineHasItem = true
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            var provider = $0.musicProvider as! MockMusicProvider
            provider.scrobbleStartHandler = { started.append((Int($0.sourceID)!, Int($1.sourceID)!)) }
            provider.scrobbleFinishHandler = { finished.append((Int($0.sourceID)!, Int($1.sourceID)!, $2)) }
            $0.musicProvider = provider
        }
        await store.send(.next)
        await store.receive(\.advanceToNext) {
            $0.playbackIntent = true
            $0.currentIndex = 1
        }
        await store.receive(\.startPlaying) {
            $0.currentTrack = Self.t2
            $0.duration = Self.t2.duration
            $0.progress = 0
            $0.engineHasItem = false
            $0.resolveGeneration = 1
        }
        await store.receive(\.lyricsResponse) {
            $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
        }
        await store.receive(\.urlResolved) {
            $0.servedQuality = "exhigh"
            $0.engineHasItem = true
            $0.startScrobbled = true
        }
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(finished.first?.trackID, 1)
        XCTAssertEqual(finished.first?.sourceID, 3)
        XCTAssertEqual(finished.first?.seconds, 5)
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started.first?.trackID, 2)
        XCTAssertEqual(started.first?.sourceID, 3)
    }

    // MARK: - Sleep timer

    func testSleepTimerPausesWhenItFires() async {
        var state = PlayerFeature.State()
        state.currentTrack = Self.t1
        state.isPlaying = true
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            $0.continuousClock = ImmediateClock()
            $0.date.now = Date(timeIntervalSince1970: 1000)
        }
        await store.send(.sleepTimer(.schedule(minutes: 30))) {
            $0.sleepTimer.mode = .countdown(deadline: Date(timeIntervalSince1970: 2800))
        }
        await store.receive(\.sleepTimer) {
            $0.sleepTimer.mode = .inactive
            $0.isPlaying = false
        }
        await store.receive(\.pause)
    }

    func testEndOfCurrentTrackTimerStopsAtTheEnd() async {
        var state = PlayerFeature.State()
        state.currentTrack = Self.t1
        state.isPlaying = true
        state.progress = 5
        state.duration = Self.t1.duration
        state.sleepTimer.mode = .endOfCurrentTrack
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
        }
        await store.send(.itemEnded) {
            $0.scrobbled = true
            $0.sleepTimer.mode = .inactive
            $0.progress = Self.t1.duration
            $0.isPlaying = false
        }
        await store.receive(\.pause)
    }

    // MARK: - Personal FM

    func testFMFetchesThenAdvances() async {
        var state = PlayerFeature.State()
        state.isFMMode = true
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            $0.personalFM = MockPersonalFM(tracks: [Self.t1])
        }
        await store.send(.fmNext) {
            $0.playbackIntent = true
        }
        await store.receive(\.fmAdvance)
        await store.receive(\.fmFetch)
        await store.receive(\.fmResponse) {
            $0.fmUpcoming = [Self.t1]
        }
        await store.receive(\.fmAdvance) {
            $0.fmUpcoming = []
        }
        await store.receive(\.startPlaying) {
            $0.currentTrack = Self.t1
            $0.duration = Self.t1.duration
            $0.isPlaying = true
            $0.resolveGeneration = 1
        }
        // The batch ran dry, so a refill was requested alongside playback.
        await store.receive(\.fmFetch)
        // The refill arrived; with autostart off it just tops up the buffer.
        await store.receive(\.fmResponse) {
            $0.fmUpcoming = [Self.t1]
        }
        await store.receive(\.lyricsResponse) {
            $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
        }
        await store.receive(\.urlResolved) {
            $0.servedQuality = "exhigh"
            $0.engineHasItem = true
            $0.startScrobbled = true
        }
    }

    // MARK: - Recents

    func testRecentsMoveToTheFront() async {
        var state = PlayerFeature.State()
        state.recentContexts = [.playlist(id: 1, name: "A"), .playlist(id: 2, name: "B")]
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
        }
        await store.send(.play(tracks: [Self.t1], source: .none, startAt: nil,
                              context: .playlist(id: 1, name: "A"))) {
            $0.queue = [Self.t1]
            $0.playbackIntent = true
            $0.currentIndex = 0
            $0.recentContexts = [.playlist(id: 1, name: "A"), .playlist(id: 2, name: "B")]
        }
        await store.receive(\.startPlaying) {
            $0.currentTrack = Self.t1
            $0.duration = Self.t1.duration
            $0.isPlaying = true
            $0.resolveGeneration = 1
        }
        await store.receive(\.lyricsResponse) {
            $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
        }
        await store.receive(\.urlResolved) {
            $0.servedQuality = "exhigh"
            $0.engineHasItem = true
            $0.startScrobbled = true
        }
    }

    // MARK: - Persistence

    func testQueueSurvivesRelaunch() async {
        nonisolated(unsafe) var saved: Data?
        do {
            let store = TestStore(initialState: PlayerFeature.State()) {
                PlayerFeature()
            } withDependencies: {
                configureResolve(&$0)
                $0.persistence.setData = { data, _ in saved = data }
            }
            await store.send(.play(tracks: [Self.t1], source: .none, startAt: nil, context: nil)) {
                $0.queue = [Self.t1]
                $0.playbackIntent = true
                $0.currentIndex = 0
            }
            await store.receive(\.startPlaying) {
                $0.currentTrack = Self.t1
                $0.duration = Self.t1.duration
                $0.isPlaying = true
                $0.resolveGeneration = 1
            }
            await store.receive(\.lyricsResponse) {
                $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
            }
            await store.receive(\.urlResolved) {
                $0.servedQuality = "exhigh"
                $0.engineHasItem = true
                $0.startScrobbled = true
            }
        }
        XCTAssertNotNil(saved)

        // Relaunch: the queue comes back, paused.
        let store2 = TestStore(initialState: PlayerFeature.State()) {
            PlayerFeature()
        } withDependencies: {
            configureResolve(&$0)
            $0.persistence.dataForKey = { _ in saved }
        }
        await store2.send(.onAppear) {
            $0.isLoaded = true
            $0.queue = [Self.t1]
            $0.currentIndex = 0
            $0.currentTrack = Self.t1
            $0.duration = Self.t1.duration
        }
        await store2.receive(\.setVolume)
        // The engine's four listener streams live for the app's lifetime; in
        // tests they never yield, so they are still in flight at the end.
        await store2.skipInFlightEffects()
    }

    // MARK: - Additional state and persistence coverage

    func testQueueProjectionsAndUpcomingLimit() {
        var state = PlayerFeature.State()
        state.playNextList = [Self.t3]
        XCTAssertEqual(state.activeQueue, [])
        XCTAssertEqual(state.upcomingTracks, [Self.t3])
        XCTAssertFalse(state.hasCurrentTrack)
        state.queue = [Self.t1, Self.t2]
        XCTAssertEqual(state.upcomingTracks, [Self.t3])
        state.currentIndex = 0
        state.currentTrack = Self.t1
        XCTAssertTrue(state.hasCurrentTrack)
        XCTAssertEqual(state.upcomingTracks, [Self.t3, Self.t2])
        state.shuffleEnabled = true
        state.shuffledQueue = [Self.t2, Self.t1]
        XCTAssertEqual(state.activeQueue, [Self.t2, Self.t1])
        XCTAssertEqual(state.upcomingTracks, [Self.t3, Self.t1])
        state.currentIndex = 99
        XCTAssertEqual(state.upcomingTracks, [Self.t3])
        state.shuffleEnabled = false
        state.queue = Array(repeating: Self.t1, count: 250)
        state.currentIndex = 0
        XCTAssertEqual(state.upcomingTracks.count, 201)
    }

    func testSleepTimerStateTransitions() {
        var timer = PlayerFeature.SleepTimerState()
        XCTAssertFalse(timer.isActive)
        XCTAssertFalse(timer.consumeEndOfCurrentTrack())
        timer.schedule(minutes: 2, now: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(timer.mode, .countdown(deadline: Date(timeIntervalSince1970: 130)))
        XCTAssertTrue(timer.isActive)
        XCTAssertFalse(timer.consumeEndOfCurrentTrack())
        timer.scheduleAtEndOfCurrentTrack()
        XCTAssertTrue(timer.consumeEndOfCurrentTrack())
        XCTAssertFalse(timer.isActive)
        timer.scheduleAtEndOfCurrentTrack()
        timer.cancel()
        XCTAssertFalse(timer.isActive)
    }

    func testReshufflePinsTrackAndRecentContextsAreCapped() {
        var state = PlayerFeature.State(queue: [Self.t1, Self.t2, Self.t3])
        state.reshuffle(keeping: Self.t2)
        XCTAssertEqual(state.shuffledQueue.first, Self.t2)
        XCTAssertEqual(Set(state.shuffledQueue.map(\.id)), Set([1, 2, 3]))
        for id in 1...8 { state.recordRecent(.playlist(id: id, name: "list")) }
        XCTAssertEqual(state.recentContexts.map(\.id), [8, 7, 6, 5, 4, 3])
        state.recordRecent(.playlist(id: 5, name: "renamed"))
        XCTAssertEqual(state.recentContexts.map(\.id), [5, 8, 7, 6, 4, 3])
    }

    func testPersistenceRejectsNonFiniteVolumeAndCapsQueue() throws {
        let saved = LockIsolated<Data?>(nil)
        let keys = LockIsolated<[String]>([])
        var persistence = PersistenceClient()
        persistence.setData = { data, key in
            saved.setValue(data)
            keys.withValue { $0.append(key) }
        }
        var state = PlayerFeature.State()
        state.volume = .infinity
        state.persist(using: persistence)
        XCTAssertTrue(keys.value.isEmpty)
        state.volume = 0.5
        state.queue = Array(repeating: Self.t1, count: 1001)
        state.currentTrack = Self.t1
        state.persist(using: persistence)
        XCTAssertEqual(keys.value, [PlayerFeature.persistedStateKey])
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(saved.value)) as? [String: Any])
        XCTAssertEqual((json["queue"] as? [Any])?.count, 1000)
        XCTAssertEqual(json["currentID"] as? Int, 1)
        XCTAssertEqual(json["volume"] as? Double, 0.5)
    }

    func testRestoreMissingAndInvalidDataPreservesState() {
        var state = PlayerFeature.State(queue: [Self.t1])
        let original = state
        var client = PersistenceClient()
        client.dataForKey = { _ in nil }
        state.restore(using: client)
        XCTAssertEqual(state, original)
        client.dataForKey = { _ in Data("invalid".utf8) }
        state.restore(using: client)
        XCTAssertEqual(state, original)
    }

    func testRestoreEmptyQueueKeepsRecentsAndDefaultsUnknownRepeat() throws {
        let contexts = (1...8).map { PlayContext.playlist(id: $0, name: "list") }
        let contextJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(contexts))
        let data = try JSONSerialization.data(withJSONObject: [
            "queue": [], "repeatMode": "unknown", "shuffle": true,
            "volume": 0.25, "recentContexts": contextJSON
        ])
        var state = PlayerFeature.State()
        var client = PersistenceClient()
        client.dataForKey = { _ in data }
        state.restore(using: client)
        XCTAssertEqual(state.recentContexts, Array(contexts.prefix(6)))
        XCTAssertEqual(state.repeatMode, .off)
        XCTAssertTrue(state.shuffleEnabled)
        XCTAssertEqual(state.volume, 0.25)
        XCTAssertNil(state.currentTrack)
    }

    func testRestoreShuffledQueueFindsCurrentTrackAndSupportsOldState() throws {
        let saved = LockIsolated<Data?>(nil)
        var state = PlayerFeature.State(queue: [Self.t1, Self.t2, Self.t3])
        state.currentTrack = Self.t2
        state.shuffleEnabled = true
        state.repeatMode = .one
        var client = PersistenceClient()
        client.setData = { data, _ in saved.setValue(data) }
        state.persist(using: client)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(saved.value)) as? [String: Any])
        json.removeValue(forKey: "recentContexts")
        let data = try JSONSerialization.data(withJSONObject: json)
        var restored = PlayerFeature.State()
        client.dataForKey = { _ in data }
        restored.restore(using: client)
        XCTAssertEqual(restored.queue, state.queue)
        XCTAssertEqual(Set(restored.activeQueue.map(\.id)), Set([1, 2, 3]))
        XCTAssertEqual(restored.activeQueue[restored.currentIndex], Self.t2)
        XCTAssertEqual(restored.currentTrack, Self.t2)
        XCTAssertEqual(restored.duration, Self.t2.duration)
        XCTAssertEqual(restored.repeatMode, .one)
        XCTAssertEqual(restored.recentContexts, [])
    }

    func testResolveUnsupportedContextsAndDaily() async throws {
        for context in [PlayContext.fm, .recents, .heartbeat] {
            let resolved = try await PlayerFeature.resolve(context, using: MockMusicProvider())
            XCTAssertNil(resolved)
        }
        var provider = MockMusicProvider()
        provider.dailyRecommendSongsHandler = { [Self.t1] }
        let resolved = try await PlayerFeature.resolve(.daily, using: provider)
        XCTAssertEqual(resolved?.tracks, [Self.t1])
        XCTAssertEqual(resolved?.source, .daily)
    }

    func testResolveAlbumArtistAndCloud() async throws {
        var client = MockMusicProvider()
        client.albumHandler = { id in
            XCTAssertEqual(id, MusicID(7))
            return AlbumDetail(detail: try JSONDecoder().decode(AlbumDetail.self, from: Data(#"{"id":7}"#.utf8)),
                songs: [Self.t1])
        }
        client.artistHandler = { id in
            XCTAssertEqual(id, MusicID(8))
            return ArtistDetail(
                artist: try JSONDecoder().decode(ArtistSummary.self, from: Data(#"{"id":8}"#.utf8)),
                hotSongs: [Self.t2])
        }
        let album = try await PlayerFeature.resolve(.album(id: 7, name: "album"), using: client)
        XCTAssertEqual(album?.tracks, [Self.t1])
        XCTAssertEqual(album?.source, .album(7))
        let artist = try await PlayerFeature.resolve(.artist(id: 8, name: "artist"), using: client)
        XCTAssertEqual(artist?.tracks, [Self.t2])
        XCTAssertEqual(artist?.source, .artist(8))
        let song = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.t3))
        let cloudData = try JSONSerialization.data(withJSONObject: [
            "items": [["simpleSong": song], ["songId": 4]],
            "hasMore": false, "usedBytes": 0, "maxBytes": 0
        ])
        var cloudStorage = MockCloudStorage()
        cloudStorage.cloudSongsHandler = { limit, offset in
            XCTAssertEqual(limit, 100)
            XCTAssertEqual(offset, 0)
            return try JSONDecoder().decode(CloudStoragePage.self, from: cloudData)
        }
        let cloud = try await withDependencies {
            $0.cloudStorage = cloudStorage
        } operation: {
            try await PlayerFeature.resolve(.cloud, using: client)
        }
        XCTAssertEqual(cloud?.tracks, [Self.t3])
        XCTAssertEqual(cloud?.source, .cloud)
        cloudStorage.cloudSongsHandler = { _, _ in
            CloudStoragePage(items: [], hasMore: false, usedBytes: 0, maxBytes: 0)
        }
        let empty = try await withDependencies {
            $0.cloudStorage = cloudStorage
        } operation: {
            try await PlayerFeature.resolve(.cloud, using: client)
        }
        XCTAssertEqual(empty?.tracks, [])
    }

    func testResolvePlaylistChunksRemainingIDsAndStopsAfterFailure() async throws {
        let first = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.t1))
        let data = try JSONSerialization.data(withJSONObject: [
            "id": 9, "tracks": [first], "trackIds": (1...502).map { ["id": $0] }
        ])
        let calls = LockIsolated<[[Int]]>([])
        var client = MockMusicProvider()
        client.playlistDetailHandler = { id in
            XCTAssertEqual(id, MusicID(9))
            return try JSONDecoder().decode(PlaylistDetail.self, from: data)
        }
        client.songDetailsHandler = { ids in
            calls.withValue { $0.append(ids.map { Int($0.sourceID)! }) }
            return ids.map { Self.track(Int($0.sourceID)!, "song") }
        }
        let result = try await PlayerFeature.resolve(.playlist(id: 9, name: "list"), using: client)
        XCTAssertEqual(result?.tracks.map(\.id), Array(1...502))
        XCTAssertEqual(result?.source, .playlist(9))
        XCTAssertEqual(calls.value, [Array(2...501), [502]])
        calls.setValue([])
        client.songDetailsHandler = { ids in
            calls.withValue { $0.append(ids.map { Int($0.sourceID)! }) }
            throw URLError(.badServerResponse)
        }
        let partial = try await PlayerFeature.resolve(.playlist(id: 9, name: "list"), using: client)
        XCTAssertEqual(partial?.tracks, [Self.t1])
        XCTAssertEqual(calls.value, [Array(2...501)])
    }

    // MARK: - Additional reducer branches

    func testLoadedOnAppearAndEmptyTransportGuards() async {
        var state = PlayerFeature.State()
        state.isLoaded = true
        let store = TestStore(initialState: state) { PlayerFeature() }
        await store.send(.onAppear)
        await store.send(.togglePlayPause)
        await store.send(.fmNext)
        await store.send(.fmAdvance)
        await store.send(.fmTrash)
        await store.send(.play(tracks: [], source: .none, startAt: nil, context: nil))
        await store.send(.bufferingChanged(0.004))
        await store.send(.urlResolved(generation: 99, autostart: true,
            .init(url: nil, servedQuality: "stale", isTrial: true, unblockSource: "stale")))
        await store.finish()
    }

    func testFMGuardsIgnoreQueueModesAndRepeatedStart() async {
        var state = PlayerFeature.State()
        state.isFMMode = true
        state.isPlaying = true
        let store = TestStore(initialState: state) { PlayerFeature() }
        await store.send(.previous)
        await store.send(.toggleShuffle)
        await store.send(.setRepeatMode(.all))
        await store.send(.cycleRepeatMode)
        await store.send(.cyclePlaybackMode)
        await store.send(.startFM)
        await store.send(.fmTrash)
        await store.send(.playContext(.fm))
        await store.receive(.startFM)
        await store.finish()
    }

    func testTogglePauseAndResumeLoadedItemScrobblesOnce() async {
        var state = PlayerFeature.State()
        state.currentTrack = Self.t1
        state.engineHasItem = true
        state.isPlaying = true
        state.playbackIntent = true
        let commands = LockIsolated<[String]>([])
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            var provider = $0.musicProvider as! MockMusicProvider
            $0.playback.pause = { commands.withValue { $0.append("pause") } }
            $0.playback.play = { commands.withValue { $0.append("play") } }
            provider.scrobbleStartHandler = { _, _ in commands.withValue { $0.append("start") } }
            $0.musicProvider = provider
        }
        await store.send(.togglePlayPause)
        await store.receive(.pause) {
            $0.isPlaying = false
            $0.playbackIntent = false
        }
        await store.finish()
        await store.send(.togglePlayPause) {
            $0.isPlaying = true
            $0.playbackIntent = true
            $0.startScrobbled = true
        }
        await store.finish()
        await store.send(.togglePlayPause)
        await store.receive(.pause) {
            $0.isPlaying = false
            $0.playbackIntent = false
        }
        await store.finish()
        await store.send(.togglePlayPause) {
            $0.isPlaying = true
            $0.playbackIntent = true
        }
        await store.finish()
        XCTAssertEqual(commands.value.filter { $0 == "pause" }.count, 2)
        XCTAssertEqual(commands.value.filter { $0 == "play" }.count, 2)
        XCTAssertEqual(commands.value.filter { $0 == "start" }.count, 1)
    }

    func testRemoveUpcomingProtectsCurrentAndRemovesShuffledEntry() async {
        var state = PlayerFeature.State(queue: [Self.t1, Self.t2, Self.t3], currentIndex: 0)
        state.shuffledQueue = [Self.t3, Self.t2, Self.t1]
        let store = TestStore(initialState: state) { PlayerFeature() }
        await store.send(.removeFromUpcoming(Self.t1)) {
            $0.shuffledQueue = [Self.t3, Self.t2]
        }
        await store.send(.removeFromUpcoming(Self.t2)) {
            $0.queue = [Self.t1, Self.t3]
            $0.shuffledQueue = [Self.t3]
        }
        await store.send(.removeFromUpcoming(Self.t2))
        await store.send(.toggleShuffle) { $0.shuffleEnabled = true }
        await store.send(.removeFromUpcoming(Self.t1)) { $0.queue = [Self.t3] }
        await store.finish()
    }

    func testShufflePinsCurrentAndPlaybackModeCompletesCycle() async {
        var state = PlayerFeature.State(queue: [Self.t1, Self.t2], currentIndex: 1)
        state.currentTrack = Self.t2
        let store = TestStore(initialState: state) { PlayerFeature() }
        await store.send(.cyclePlaybackMode) { $0.repeatMode = .all }
        await store.send(.cyclePlaybackMode) { $0.repeatMode = .one }
        await store.send(.cyclePlaybackMode) { $0.repeatMode = .off }
        await store.receive(.toggleShuffle) {
            $0.shuffleEnabled = true
            $0.shuffledQueue = [Self.t2, Self.t1]
            $0.currentIndex = 0
        }
        await store.send(.cyclePlaybackMode) {
            $0.shuffleEnabled = false
            $0.currentIndex = 1
        }
        await store.send(.toggleShuffle) {
            $0.shuffleEnabled = true
            $0.currentIndex = 0
        }
        await store.send(.toggleShuffle) {
            $0.shuffleEnabled = false
            $0.currentIndex = 1
        }
        await store.send(.setRepeatMode(.one)) { $0.repeatMode = .one }
        await store.finish()
    }

    func testShuffleFallbackIndexAndCycleWithoutCurrentTrack() async {
        var state = PlayerFeature.State(queue: [Self.t1], currentIndex: 3)
        state.currentTrack = Self.t2
        state.shuffleEnabled = true
        let store = TestStore(initialState: state) { PlayerFeature() }
        await store.send(.toggleShuffle) {
            $0.shuffleEnabled = false
            $0.currentIndex = 0
        }
        await store.send(.toggleShuffle) {
            $0.shuffleEnabled = true
            $0.shuffledQueue = [Self.t2, Self.t1]
        }
        await store.send(.cyclePlaybackMode) { $0.shuffleEnabled = false }
        let empty = TestStore(initialState: PlayerFeature.State()) { PlayerFeature() }
        await empty.send(.toggleShuffle) { $0.shuffleEnabled = true }
        await empty.send(.cyclePlaybackMode) { $0.shuffleEnabled = false }
        await store.finish()
        await empty.finish()
    }

    func testPanelAndSleepTimerActions() async {
        let store = TestStore(initialState: PlayerFeature.State()) { PlayerFeature() }
        await store.send(.togglePanel(.lyrics)) { $0.activePanel = .lyrics }
        await store.send(.togglePanel(.queue)) { $0.activePanel = .queue }
        await store.send(.togglePanel(.queue)) { $0.activePanel = nil }
        await store.send(.sleepTimer(.endOfCurrentTrack)) { $0.sleepTimer.mode = .endOfCurrentTrack }
        await store.send(.sleepTimer(.cancel)) { $0.sleepTimer.mode = .inactive }
        await store.send(.unblockApplied("test"))
        await store.receive(.toast(String(localized: "已使用第三方音源：\("test")")))
        await store.finish()
    }

    func testPreviousAtBeginningSeeksWithoutRepeat() async {
        var state = PlayerFeature.State(queue: [Self.t1], currentIndex: 0)
        state.currentTrack = Self.t1
        let now = Date(timeIntervalSince1970: 1000)
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            $0.date = .constant(now)
        }
        await store.send(.previous) { $0.playbackIntent = true }
        await store.receive(.seek(0)) {
            $0.isPlaying = true
            $0.pendingSeekTarget = 0
            $0.seekGuardUntil = now.addingTimeInterval(3)
        }
        await store.finish()
    }

    // MARK: - Additional effects and engine events

    func testOnAppearForwardsAllEngineStreamsAndOnlySubscribesOnce() async {
        let ticks = AsyncStream<TimeInterval>.makeStream()
        let ended = AsyncStream<Void>.makeStream()
        let buffering = AsyncStream<Double>.makeStream()
        let playing = AsyncStream<Bool>.makeStream()
        let volumes = LockIsolated<[Float]>([])
        let store = TestStore(initialState: PlayerFeature.State()) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            $0.persistence.dataForKey = { _ in nil }
            $0.playback.timeTicks = { ticks.stream }
            $0.playback.itemEnded = { ended.stream }
            $0.playback.bufferingChanged = { buffering.stream }
            $0.playback.isPlayingChanged = { playing.stream }
            $0.playback.setVolume = { volume in volumes.withValue { $0.append(volume) } }
        }
        await store.send(.onAppear) { $0.isLoaded = true }
        await store.receive(.setVolume(0.8))
        ticks.continuation.yield(12)
        await store.receive(.timeTick(12))
        ended.continuation.yield(())
        await store.receive(.itemEnded)
        buffering.continuation.yield(0.5)
        await store.receive(.bufferingChanged(0.5)) { $0.bufferProgress = 0.5 }
        playing.continuation.yield(true)
        await store.receive(.isPlayingChanged(true)) { $0.isPlaying = true }
        await store.send(.onAppear)
        ticks.continuation.finish()
        ended.continuation.finish()
        buffering.continuation.finish()
        playing.continuation.finish()
        await store.finish()
        XCTAssertEqual(volumes.value, [0.8])
    }

    func testExpiredSeekGuardClearsWithoutPlaybackIntent() async {
        var state = PlayerFeature.State()
        state.seekGuardUntil = Date(timeIntervalSince1970: 999)
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            $0.date = .constant(Date(timeIntervalSince1970: 1000))
        }
        await store.send(.itemEnded) { $0.seekGuardUntil = nil }
        await store.finish()
    }

    func testRepeatOneRewindsAndResumesAtItemEnd() async {
        var state = PlayerFeature.State()
        state.currentTrack = Self.t1
        state.duration = 200
        state.progress = 200
        state.playbackIntent = true
        state.repeatMode = .one
        state.startScrobbled = true
        let calls = LockIsolated<[String]>([])
        let now = Date(timeIntervalSince1970: 1000)
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            var provider = $0.musicProvider as! MockMusicProvider
            $0.date = .constant(now)
            $0.playback.seek = { _ in calls.withValue { $0.append("seek") } }
            $0.playback.play = { calls.withValue { $0.append("play") } }
            provider.scrobbleFinishHandler = { id, _, seconds in
                XCTAssertEqual(id, MusicID(1))
                XCTAssertEqual(seconds, 200)
                calls.withValue { $0.append("finish") }
            }
            $0.musicProvider = provider
        }
        await store.send(.itemEnded) { $0.progress = 0 }
        await store.receive(.seek(0)) {
            $0.isPlaying = true
            $0.pendingSeekTarget = 0
            $0.seekGuardUntil = now.addingTimeInterval(3)
        }
        await store.finish()
        XCTAssertEqual(calls.value.filter { $0 == "finish" }.count, 1)
        XCTAssertEqual(calls.value.filter { $0 == "seek" }.count, 1)
        XCTAssertEqual(calls.value.filter { $0 == "play" }.count, 2)
    }

    func testPlayingEventClearsBufferingAndPublishesMetadataWithAndWithoutCover() async {
        for cover in [nil, "https://example.com/cover.jpg"] as [String?] {
            let track = Track(
                id: 9, name: "Metadata", artists: [],
                album: AlbumRef(id: 1, name: "Album", picUrl: cover),
                durationMS: 200_000, alias: [], transNames: [], fee: 0, mvID: 0,
                trackNo: 0, disc: nil, noCopyright: false, isCloud: false, embeddedPrivilege: nil)
            var state = PlayerFeature.State()
            state.currentTrack = track
            state.isBuffering = true
            let metadata = LockIsolated<[String]>([])
            let starts = LockIsolated(0)
            let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
                configureResolve(&$0)
            var provider = $0.musicProvider as! MockMusicProvider
                provider.scrobbleStartHandler = { _, _ in starts.withValue { $0 += 1 } }
                $0.playback.updateMetadata = { title, artist, album, url in
                    XCTAssertEqual(title, track.name)
                    XCTAssertEqual(artist, track.artistNames)
                    XCTAssertEqual(album, track.album.name)
                    XCTAssertEqual(url, cover.flatMap(URL.init(string:)))
                    metadata.withValue { $0.append(title) }
                }
            $0.musicProvider = provider
        }
            await store.send(.isPlayingChanged(true)) {
                $0.isPlaying = true
                $0.isBuffering = false
                $0.startScrobbled = true
            }
            await store.finish()
            await store.send(.isPlayingChanged(true))
            await store.send(.isPlayingChanged(false)) { $0.isPlaying = false }
            await store.send(.isPlayingChanged(true)) { $0.isPlaying = true }
            await store.finish()
            XCTAssertEqual(metadata.value.count, 2)
            XCTAssertEqual(starts.value, 1)
        }
    }

    func testTrialURLLoadsAndNotifiesUser() async {
        let url = URL(string: "https://example.com/trial")!
        let loads = LockIsolated<[Bool]>([])
        let store = TestStore(initialState: PlayerFeature.State()) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            $0.playback.load = { actual, autostart, _ in
                XCTAssertEqual(actual, url)
                loads.withValue { $0.append(autostart) }
            }
        }
        await store.send(.urlResolved(generation: 0, autostart: false,
            .init(url: url, servedQuality: "standard", isTrial: true, unblockSource: nil))) {
            $0.servedQuality = "standard"
            $0.isTrial = true
            $0.engineHasItem = true
        }
        await store.receive(.toast(String(localized: "VIP 歌曲，当前为试听片段")))
        await store.finish()
        XCTAssertEqual(loads.value, [false])
    }

    func testFifthURLFailureStopsInsteadOfAdvancing() async {
        var state = PlayerFeature.State()
        state.isPlaying = true
        state.playbackIntent = true
        state.consecutiveFailures = 4
        let clears = LockIsolated(0)
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            $0.playback.clear = { clears.withValue { $0 += 1 } }
        }
        await store.send(.urlResolved(generation: 0, autostart: true,
            .init(url: nil, servedQuality: nil, isTrial: false, unblockSource: nil))) {
            $0.consecutiveFailures = 5
        }
        let name = ""
        let suffix = ""
        await store.receive(.toast(String(localized: "《\(name)》无法播放\(suffix)")))
        await store.receive(.stopPlayback) {
            $0.isPlaying = false
            $0.playbackIntent = false
        }
        await store.finish()
        XCTAssertEqual(clears.value, 1)
    }

    func testFMAdvanceWithEmptyProviderRetriesThenStopsFetching() async {
        var state = PlayerFeature.State()
        state.isFMMode = true
        let clock = TestClock()
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            $0.personalFM = nil
            $0.continuousClock = clock
        }
        await store.send(.advanceToNext(userInitiated: true)) { $0.playbackIntent = true }
        await store.receive(.fmAdvance)
        await store.receive(.fmFetch(autostart: true))
        await clock.advance(by: .seconds(1))
        await clock.advance(by: .seconds(1))
        await store.receive(.fmResponse(tracks: [], autostart: true))
        await store.finish()
    }

    func testFMTrashCallsAPIAndAdvancesEvenWhenTrashFails() async {
        var state = PlayerFeature.State()
        state.isFMMode = true
        state.currentTrack = Self.t1
        let trashed = LockIsolated<[Int]>([])
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            $0.continuousClock = ImmediateClock()
            var fm = MockPersonalFM()
            fm.fmTrashHandler = { id in
                trashed.withValue { $0.append(Int(id.sourceID)!) }
                throw URLError(.badServerResponse)
            }
            $0.personalFM = fm
        }
        await store.send(.fmTrash) { $0.playbackIntent = true }
        await store.receive(.fmAdvance)
        await store.receive(.fmFetch(autostart: true))
        await store.receive(.fmResponse(tracks: [], autostart: true))
        await store.finish()
        XCTAssertEqual(trashed.value, [1])
    }

    func testPlayContextForwardsResolutionAndIgnoresUnsupportedOrFailedContexts() async {
        let context = PlayContext.album(id: 9, name: "album")
        let store = TestStore(initialState: PlayerFeature.State()) { PlayerFeature() } withDependencies: {
            var provider = MockMusicProvider()
            provider.albumHandler = { _ in
                AlbumDetail(detail: try JSONDecoder().decode(AlbumDetail.self, from: Data(#"{"id":9}"#.utf8)),
                    songs: [])
            }
            provider.artistHandler = { _ in throw URLError(.badServerResponse) }
            $0.musicProvider = provider
        }
        await store.send(.playContext(context))
        await store.receive(.contextResolved(context, tracks: [], source: .album(9)))
        await store.receive(.play(tracks: [], source: .album(9), startAt: nil, context: context))
        await store.send(.playContext(.recents))
        await store.finish()
        await store.send(.playContext(.artist(id: 8, name: "artist")))
        await store.finish()
    }

    func testURLResolutionFallsBackToStandardAndUpgradesHTTP() async {
        let clock = TestClock()
        let qualities = LockIsolated<[String]>([])
        let urls = LockIsolated<[URL]>([])
        let store = TestStore(initialState: PlayerFeature.State()) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            var provider = $0.musicProvider as! MockMusicProvider
            provider.songURLHandler = { ids, level in
                XCTAssertEqual(ids, [MusicID(1)])
                qualities.withValue { $0.append(level.neteaseLevel) }
                if level != .standard {
                    try await clock.sleep(for: .seconds(1))
                    throw URLError(.badServerResponse)
                }
                return [SongURLData(id: 1, url: "http://example.com/fallback", br: 0, size: 0,
                    type: nil, level: level.neteaseLevel, fee: 0, freeTrialInfo: nil, time: 200)]
            }
            $0.playback.load = { url, autostart, _ in
                XCTAssertFalse(autostart)
                urls.withValue { $0.append(url) }
            }
            $0.musicProvider = provider
        }
        await store.send(.startPlaying(Self.t1)) {
            $0.currentTrack = Self.t1
            $0.duration = 200
            $0.isPlaying = true
            $0.resolveGeneration = 1
        }
        await store.receive(.lyricsResponse(generation: 1, LyricsParser.parse(Self.emptyLyrics()))) {
            $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
        }
        await clock.advance(by: .seconds(1))
        await store.receive(.urlResolved(generation: 1, autostart: false,
            .init(url: URL(string: "https://example.com/fallback"), servedQuality: "standard",
                  isTrial: false, unblockSource: nil))) {
            $0.servedQuality = "standard"
            $0.engineHasItem = true
            $0.startScrobbled = true
        }
        await store.finish()
        XCTAssertEqual(qualities.value, ["exhigh", "standard"])
        XCTAssertEqual(urls.value, [URL(string: "https://example.com/fallback")!])
    }

    func testURLResolutionUsesUnblockForMissingURLAndTrial() async throws {
        let trial = try JSONDecoder().decode(FreeTrialInfo.self, from: Data(#"{"start":0,"end":30}"#.utf8))
        for isTrial in [false, true] {
            let clock = TestClock()
            let resolvedURL = URL(string: "https://example.com/unblocked")!
            let unblocks = LockIsolated<[Int]>([])
            var state = PlayerFeature.State()
            state.audioQuality = .standard
            let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
                configureResolve(&$0)
            var provider = $0.musicProvider as! MockMusicProvider
                provider.songURLHandler = { _, quality in
                    XCTAssertEqual(quality, .standard)
                    try await clock.sleep(for: .seconds(1))
                    return [SongURLData(id: 1, url: isTrial ? "https://example.com/trial" : nil,
                        br: 0, size: 0, type: nil, level: "standard", fee: 0,
                        freeTrialInfo: isTrial ? trial : nil, time: 200)]
                }
                $0.unblock.resolve = { track in
                    unblocks.withValue { $0.append(track.id) }
                    return UnblockService.Resolved(url: resolvedURL, source: "test")
                }
            $0.musicProvider = provider
        }
            await store.send(.startPlaying(Self.t1)) {
                $0.currentTrack = Self.t1
                $0.duration = 200
                $0.isPlaying = true
                $0.resolveGeneration = 1
            }
            await store.receive(.lyricsResponse(generation: 1, LyricsParser.parse(Self.emptyLyrics()))) {
                $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
            }
            await clock.advance(by: .seconds(1))
            await store.receive(.unblockApplied("test"))
            await store.receive(.toast(String(localized: "已使用第三方音源：\("test")")))
            await store.receive(.urlResolved(generation: 1, autostart: false,
                .init(url: resolvedURL, servedQuality: nil, isTrial: false, unblockSource: "test"))) {
                $0.unblockSource = "test"
                $0.engineHasItem = true
                $0.startScrobbled = true
            }
            await store.finish()
            XCTAssertEqual(unblocks.value, [1])
        }
    }

    func testMissingURLToastIncludesPlayabilityReason() async {
        let track = Track(
            id: 9, name: "Unavailable", artists: [], album: AlbumRef(id: 0, name: "", picUrl: nil),
            durationMS: 200_000, alias: [], transNames: [], fee: 0, mvID: 0, trackNo: 0,
            disc: nil, noCopyright: true, isCloud: false, embeddedPrivilege: nil)
        var state = PlayerFeature.State()
        state.currentTrack = track
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
        }
        await store.send(.urlResolved(generation: 0, autostart: false,
            .init(url: nil, servedQuality: nil, isTrial: false, unblockSource: nil))) {
            $0.consecutiveFailures = 1
        }
        let reason = track.playability(privilege: nil, isLoggedIn: false, vipType: 0).reason
        XCTAssertNotNil(reason)
        let name = track.name
        let suffix = reason.map { "：\($0)" } ?? ""
        await store.receive(.toast(String(localized: "《\(name)》无法播放\(suffix)")))
        await store.receive(.stopPlayback)
        await store.finish()
    }

    func testPlayShuffledQueuePinsRequestedTrack() async {
        var state = PlayerFeature.State()
        state.shuffleEnabled = true
        let clock = TestClock()
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            var provider = $0.musicProvider as! MockMusicProvider
            let songURL = provider.songURLHandler
            provider.songURLHandler = { ids, quality in
                try await clock.sleep(for: .seconds(1))
                return try await songURL(ids, quality)
            }
            $0.musicProvider = provider
        }
        await store.send(.play(tracks: [Self.t1, Self.t2], source: .none, startAt: Self.t2, context: nil)) {
            $0.queue = [Self.t1, Self.t2]
            $0.shuffledQueue = [Self.t2, Self.t1]
            $0.currentIndex = 0
            $0.playbackIntent = true
        }
        await store.receive(.startPlaying(Self.t2)) {
            $0.currentTrack = Self.t2
            $0.duration = 200
            $0.isPlaying = true
            $0.resolveGeneration = 1
        }
        await store.receive(.lyricsResponse(generation: 1, LyricsParser.parse(Self.emptyLyrics()))) {
            $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
        }
        await clock.advance(by: .seconds(1))
        await store.receive(.urlResolved(generation: 1, autostart: true,
            .init(url: URL(string: "https://example.com/a"), servedQuality: "exhigh",
                  isTrial: false, unblockSource: nil))) {
            $0.servedQuality = "exhigh"
            $0.engineHasItem = true
            $0.startScrobbled = true
        }
        await store.finish()
    }

    func testPlayMissingRequestedTrackFallsBackToFirstIndex() async {
        let state = PlayerFeature.State()
        let clock = TestClock()
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            var provider = $0.musicProvider as! MockMusicProvider
            let songURL = provider.songURLHandler
            provider.songURLHandler = { ids, quality in
                try await clock.sleep(for: .seconds(1))
                return try await songURL(ids, quality)
            }
            $0.musicProvider = provider
        }
        await store.send(.play(tracks: [Self.t1], source: .none, startAt: Self.t2, context: nil)) {
            $0.queue = [Self.t1]
            $0.currentIndex = 0
            $0.playbackIntent = true
        }
        await store.receive(.startPlaying(Self.t2)) {
            $0.currentTrack = Self.t2
            $0.duration = 200
            $0.isPlaying = true
            $0.resolveGeneration = 1
        }
        await store.receive(.lyricsResponse(generation: 1, LyricsParser.parse(Self.emptyLyrics()))) {
            $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
        }
        await clock.advance(by: .seconds(1))
        await store.receive(.urlResolved(generation: 1, autostart: true,
            .init(url: URL(string: "https://example.com/a"), servedQuality: "exhigh",
                  isTrial: false, unblockSource: nil))) {
            $0.servedQuality = "exhigh"
            $0.engineHasItem = true
            $0.startScrobbled = true
        }
        await store.finish()
    }

    func testTogglePlayRestoredTrackResolvesEngineItem() async {
        var state = PlayerFeature.State()
        state.currentTrack = Self.t1
        let clock = TestClock()
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            var provider = $0.musicProvider as! MockMusicProvider
            let songURL = provider.songURLHandler
            provider.songURLHandler = { ids, quality in
                try await clock.sleep(for: .seconds(1))
                return try await songURL(ids, quality)
            }
            $0.musicProvider = provider
        }
        await store.send(.togglePlayPause) {
            $0.playbackIntent = true
        }
        await store.receive(.startPlaying(Self.t1)) {
            $0.currentTrack = Self.t1
            $0.duration = 200
            $0.isPlaying = true
            $0.resolveGeneration = 1
        }
        await store.receive(.lyricsResponse(generation: 1, LyricsParser.parse(Self.emptyLyrics()))) {
            $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
        }
        await clock.advance(by: .seconds(1))
        await store.receive(.urlResolved(generation: 1, autostart: true,
            .init(url: URL(string: "https://example.com/a"), servedQuality: "exhigh",
                  isTrial: false, unblockSource: nil))) {
            $0.servedQuality = "exhigh"
            $0.engineHasItem = true
            $0.startScrobbled = true
        }
        await store.finish()
    }

    func testPreviousRepeatAllWrapsToLastTrack() async {
        var state = PlayerFeature.State(queue: [Self.t1, Self.t2], currentIndex: 0)
        state.repeatMode = .all
        let clock = TestClock()
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            var provider = $0.musicProvider as! MockMusicProvider
            let songURL = provider.songURLHandler
            provider.songURLHandler = { ids, quality in
                try await clock.sleep(for: .seconds(1))
                return try await songURL(ids, quality)
            }
            $0.musicProvider = provider
        }
        await store.send(.previous) {
            $0.playbackIntent = true
            $0.currentIndex = 1
        }
        await store.receive(.startPlaying(Self.t2)) {
            $0.currentTrack = Self.t2
            $0.duration = 200
            $0.isPlaying = true
            $0.resolveGeneration = 1
        }
        await store.receive(.lyricsResponse(generation: 1, LyricsParser.parse(Self.emptyLyrics()))) {
            $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
        }
        await clock.advance(by: .seconds(1))
        await store.receive(.urlResolved(generation: 1, autostart: true,
            .init(url: URL(string: "https://example.com/a"), servedQuality: "exhigh",
                  isTrial: false, unblockSource: nil))) {
            $0.servedQuality = "exhigh"
            $0.engineHasItem = true
            $0.startScrobbled = true
        }
        await store.finish()
    }

    func testJumpToExistingQueueEntryStartsThatTrack() async {
        let state = PlayerFeature.State(queue: [Self.t1, Self.t2], currentIndex: 0)
        let clock = TestClock()
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            var provider = $0.musicProvider as! MockMusicProvider
            let songURL = provider.songURLHandler
            provider.songURLHandler = { ids, quality in
                try await clock.sleep(for: .seconds(1))
                return try await songURL(ids, quality)
            }
            $0.musicProvider = provider
        }
        await store.send(.jumpTo(Self.t2)) {
            $0.playbackIntent = true
            $0.currentIndex = 1
        }
        await store.receive(.startPlaying(Self.t2)) {
            $0.currentTrack = Self.t2
            $0.duration = 200
            $0.isPlaying = true
            $0.resolveGeneration = 1
        }
        await store.receive(.lyricsResponse(generation: 1, LyricsParser.parse(Self.emptyLyrics()))) {
            $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
        }
        await clock.advance(by: .seconds(1))
        await store.receive(.urlResolved(generation: 1, autostart: true,
            .init(url: URL(string: "https://example.com/a"), servedQuality: "exhigh",
                  isTrial: false, unblockSource: nil))) {
            $0.servedQuality = "exhigh"
            $0.engineHasItem = true
            $0.startScrobbled = true
        }
        await store.finish()
    }

    func testFMAdvanceWithBufferedTracksDoesNotRefetch() async {
        var state = PlayerFeature.State()
        state.isFMMode = true
        state.playbackIntent = true
        state.fmUpcoming = [Self.t1, Self.t2]
        let clock = TestClock()
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            var provider = $0.musicProvider as! MockMusicProvider
            let songURL = provider.songURLHandler
            provider.songURLHandler = { ids, quality in
                try await clock.sleep(for: .seconds(1))
                return try await songURL(ids, quality)
            }
            $0.musicProvider = provider
        }
        await store.send(.fmAdvance) {
            $0.fmUpcoming = [Self.t2]
        }
        await store.receive(.startPlaying(Self.t1)) {
            $0.currentTrack = Self.t1
            $0.duration = 200
            $0.isPlaying = true
            $0.resolveGeneration = 1
        }
        await store.receive(.lyricsResponse(generation: 1, LyricsParser.parse(Self.emptyLyrics()))) {
            $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
        }
        await clock.advance(by: .seconds(1))
        await store.receive(.urlResolved(generation: 1, autostart: true,
            .init(url: URL(string: "https://example.com/a"), servedQuality: "exhigh",
                  isTrial: false, unblockSource: nil))) {
            $0.servedQuality = "exhigh"
            $0.engineHasItem = true
            $0.startScrobbled = true
        }
        await store.finish()
    }

    func testStartFMClearsQueueModesAndRecordsContext() async {
        var state = PlayerFeature.State(queue: [Self.t1], currentIndex: 0)
        state.shuffledQueue = [Self.t1]
        state.playNextList = [Self.t2]
        state.fmUpcoming = [Self.t3]
        state.shuffleEnabled = true
        state.repeatMode = .all
        state.source = .album(9)
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            $0.personalFM = MockPersonalFM(tracks: [])
            $0.continuousClock = ImmediateClock()
        }
        await store.send(.playContext(.fm))
        await store.receive(.startFM) {
            $0.playbackIntent = true
            $0.recentContexts = [.fm]
            $0.isFMMode = true
            $0.shuffleEnabled = false
            $0.repeatMode = .off
            $0.queue = []
            $0.shuffledQueue = []
            $0.playNextList = []
            $0.currentIndex = -1
            $0.source = .none
            $0.fmUpcoming = []
        }
        await store.receive(.fmFetch(autostart: true))
        await store.receive(.fmResponse(tracks: [], autostart: true))
        await store.finish()
    }

    func testFMAdvanceLastBufferedTrackRefillsWithoutAutostart() async {
        var state = PlayerFeature.State()
        state.isFMMode = true
        state.playbackIntent = true
        state.fmUpcoming = [Self.t1]
        let clock = TestClock()
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            var provider = $0.musicProvider as! MockMusicProvider
            $0.personalFM = MockPersonalFM(tracks: [Self.t2])
            let songURL = provider.songURLHandler
            provider.songURLHandler = { ids, quality in
                try await clock.sleep(for: .seconds(2))
                return try await songURL(ids, quality)
            }
            provider.lyricHandler = { _ in
                try await clock.sleep(for: .seconds(1))
                return Self.emptyLyrics()
            }
            $0.musicProvider = provider
        }
        await store.send(.fmAdvance) { $0.fmUpcoming = [] }
        await store.receive(.startPlaying(Self.t1)) {
            $0.currentTrack = Self.t1
            $0.duration = 200
            $0.isPlaying = true
            $0.resolveGeneration = 1
        }
        await store.receive(.fmFetch(autostart: false))
        await store.receive(.fmResponse(tracks: [Self.t2], autostart: false)) {
            $0.fmUpcoming = [Self.t2]
        }
        await clock.advance(by: .seconds(1))
        await store.receive(.lyricsResponse(generation: 1, LyricsParser.parse(Self.emptyLyrics()))) {
            $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
        }
        await clock.advance(by: .seconds(1))
        await store.receive(.urlResolved(generation: 1, autostart: true,
            .init(url: URL(string: "https://example.com/a"), servedQuality: "exhigh",
                  isTrial: false, unblockSource: nil))) {
            $0.servedQuality = "exhigh"
            $0.engineHasItem = true
            $0.startScrobbled = true
        }
        await store.finish()
    }

    func testUnblockUnavailableStopsAfterStandardURLFails() async {
        let clock = TestClock()
        let attempts = LockIsolated(0)
        var state = PlayerFeature.State()
        state.audioQuality = .standard
        state.consecutiveFailures = 4
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            var provider = $0.musicProvider as! MockMusicProvider
            provider.songURLHandler = { _, _ in
                try await clock.sleep(for: .seconds(1))
                return []
            }
            $0.unblock.resolve = { _ in
                attempts.withValue { $0 += 1 }
                return nil
            }
            $0.musicProvider = provider
        }
        await store.send(.startPlaying(Self.t1)) {
            $0.currentTrack = Self.t1
            $0.duration = 200
            $0.isPlaying = true
            $0.resolveGeneration = 1
        }
        await store.receive(.lyricsResponse(generation: 1, LyricsParser.parse(Self.emptyLyrics()))) {
            $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
        }
        await clock.advance(by: .seconds(1))
        await store.receive(.urlResolved(generation: 1, autostart: false,
            .init(url: nil, servedQuality: nil, isTrial: false, unblockSource: nil))) {
            $0.consecutiveFailures = 5
        }
        let name = Self.t1.name
        let suffix = ""
        await store.receive(.toast(String(localized: "《\(name)》无法播放\(suffix)")))
        await store.receive(.stopPlayback) { $0.isPlaying = false }
        await store.finish()
        XCTAssertEqual(attempts.value, 1)
    }

    func testAddToPlayNextWhileTrackIsCurrentShowsConfirmation() async {
        var state = PlayerFeature.State(queue: [Self.t1], currentIndex: 0)
        state.currentTrack = Self.t1
        state.playNextList = [Self.t2]
        let store = TestStore(initialState: state) { PlayerFeature() }
        await store.send(.addToPlayNext(Self.t3, playNow: false)) {
            $0.playNextList = [Self.t2, Self.t3]
        }
        await store.receive(.toast(String(localized: "已添加到下一首播放")))
        await store.finish()
    }

    func testJumpToUnknownTrackKeepsBothQueuesAndCurrentTrack() async {
        var state = PlayerFeature.State(queue: [Self.t1], currentIndex: 0)
        state.currentTrack = Self.t1
        state.playNextList = [Self.t2]
        let store = TestStore(initialState: state) { PlayerFeature() }
        await store.send(.jumpTo(Self.t3)) { $0.playbackIntent = true }
        await store.finish()
    }

    func testUserAdvancePastLastTrackShowsToastWithoutStopping() async {
        var state = PlayerFeature.State(queue: [Self.t1, Self.t2], currentIndex: 1)
        state.currentTrack = Self.t2
        state.isPlaying = true
        state.repeatMode = .off
        let store = TestStore(initialState: state) { PlayerFeature() }
        await store.send(.advanceToNext(userInitiated: true)) { $0.playbackIntent = true }
        await store.receive(.toast(String(localized: "已经是最后一首了")))
        await store.finish()
    }

    func testPlayTrackOutsideExistingQueueForwardsPlayBeforeStarting() async {
        let state = PlayerFeature.State(queue: [Self.t1, Self.t2], currentIndex: 0)
        let clock = TestClock()
        let store = TestStore(initialState: state) { PlayerFeature() } withDependencies: {
            configureResolve(&$0)
            var provider = $0.musicProvider as! MockMusicProvider
            let songURL = provider.songURLHandler
            provider.songURLHandler = { ids, quality in
                try await clock.sleep(for: .seconds(1))
                return try await songURL(ids, quality)
            }
            $0.musicProvider = provider
        }
        await store.send(.playTrack(Self.t3)) { $0.playbackIntent = true }
        await store.receive(.play(tracks: [Self.t3], source: .none, startAt: nil, context: nil)) {
            $0.queue = [Self.t3]
        }
        await store.receive(.startPlaying(Self.t3)) {
            $0.currentTrack = Self.t3
            $0.duration = 200
            $0.isPlaying = true
            $0.resolveGeneration = 1
        }
        await store.receive(.lyricsResponse(generation: 1, LyricsParser.parse(Self.emptyLyrics()))) {
            $0.lyrics = LyricsParser.parse(Self.emptyLyrics())
        }
        await clock.advance(by: .seconds(1))
        await store.receive(.urlResolved(generation: 1, autostart: true,
            .init(url: URL(string: "https://example.com/a"), servedQuality: "exhigh",
                  isTrial: false, unblockSource: nil))) {
            $0.servedQuality = "exhigh"
            $0.engineHasItem = true
            $0.startScrobbled = true
        }
        await store.finish()
    }

}
