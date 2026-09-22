import ComposableArchitecture
import Dependencies
@testable import KumoneCore
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
        deps.netease.songURL = { _, _ in
            [SongURLData(id: 1, url: "https://example.com/a", br: 0, size: 0, type: nil,
                         level: "exhigh", fee: 0, freeTrialInfo: nil, time: 200)]
        }
        deps.netease.lyric = { _ in Self.emptyLyrics() }
        deps.netease.scrobbleStart = { _, _ in }
        deps.netease.scrobbleFinish = { _, _, _ in }
        deps.persistence.setData = { _, _ in }
        // Fire-and-forget no-ops — the tests assert state, not engine calls.
        // (@DependencyClient's default init traps on any call, so every closure
        // is spelled out.)
        deps.playback = PlaybackEngineClient(
            load: { _, _ in },
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
            $0.playback.load = { url, autostart in loads.append((url, autostart)) }
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
            $0.netease.scrobbleStart = { started.append(($0, $1)) }
            $0.netease.scrobbleFinish = { finished.append(($0, $1, $2)) }
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
            $0.netease.personalFM = { [Self.t1] }
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
}
