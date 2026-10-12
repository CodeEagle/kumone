import APlay
import ComposableArchitecture
import Dependencies
import Foundation
import KumoneCore

/// The lyrics / queue side panel on macOS.
public enum RightPanel {
    case lyrics, queue
}

/// The playback queue, transport and per-track plumbing. Replaces the
/// `PlayerService` singleton: the reducer is now the single source of truth for
/// *what* is queued and *where* the cursor is, while `PlaybackEngineClient`
/// (APlay) owns the audio unit.
///
/// URL resolution, lyrics, scrobbling and queue persistence live here as
/// effects; the engine only ever receives a single URL at a time, so APlay's own
/// playlist/loop machinery is left unused on purpose.
@Reducer
public struct PlayerFeature {
    /// Transport-level events worth a system log line: the seek / end-of-item
    /// races are timing-sensitive and only show up in the field, so the
    /// decisions made here are recorded where `log show` can find them.

    @ObservableState
    public struct State: Equatable {
        public var queue: [Track] = []
        public var shuffledQueue: [Track] = []
        public var playNextList: [Track] = []
        public var currentIndex = -1
        public var currentTrack: Track?
        public var source: PlaySource = .none
        public var isPlaying = false
        /// Whether the *user* wants playback in progress — set by transport
        /// actions (play / pause / skip / stop), never by the engine's state
        /// mirror. End-of-item, where APlay reports `isPlaying=false` before
        /// `itemEnded` is processed, must not read as "the user paused": the
        /// auto-advance and the next track's autostart both hang on this.
        public var playbackIntent = false
        public var isBuffering = false
        /// A jump whose playback never got going. When the engine reports
        /// end-of-item while this is still set, the end was the jump — the
        /// target overhung the real stream length (netease lyric timestamps
        /// routinely do), or the ranged re-download a seek forces stalled long
        /// enough for the engine's frozen-time end detection to trip. The queue
        /// parks on that signal instead of advancing; a later `timeTick` past the
        /// target clears it, so a genuine finish still advances.
        public var pendingSeekTarget: TimeInterval?
        /// A grace window after a jump, during which any end-of-item is the jump
        /// regardless of the playhead. The pending marker above is cleared as
        /// soon as the playhead passes the target, and the position check below
        /// needs a known duration — a track whose length was never reported has
        /// neither, so the window is what carries that case.
        public var seekGuardUntil: Date?
        /// How much of the stream APlay has buffered (0...1), for the progress
        /// bar's preload fill. A network stream reports this for the whole
        /// track, so it is only a *loading* indicator before playback starts.
        public var bufferProgress: Double = 0
        public var progress: TimeInterval = 0
        public var duration: TimeInterval = 0
        public var servedQuality: String?
        public var unblockSource: String?
        public var isTrial = false
        public var repeatMode: RepeatMode = .off
        public var shuffleEnabled = false
        public var volume: Float = 0.8
        public var isFMMode = false
        public var fmUpcoming: [Track] = []
        public var recentContexts: [PlayContext] = []
        public var lyrics: ParsedLyrics?
        public var lyricsCursorIndex: Int?
        /// The lyrics / queue side panel (macOS). `nil` while hidden.
        public var activePanel: RightPanel?

        public var sleepTimer = SleepTimerState()

        // Mirrored from SettingsFeature / AccountFeature by AppFeature — the
        // sibling features own the storage, the player only needs the values.
        public var audioQuality: AudioQuality = .exhigh
        public var enableUnblock = true
        /// Mirrored from SettingsFeature so the URL resolver can gate the
        /// mirror fallback without reaching across features.
        public var enableAudioSourceFallback = true
        public var isLoggedIn = false
        public var vipType = 0

        // Engine bookkeeping. `engineHasItem` tracks whether APlay has a loaded
        // item, which the reducer cannot see any other way — it decides whether
        // a play/pause tap resumes the current item or re-resolves a restored
        // queue. `resolveGeneration` invalidates in-flight URL/lyrics work when
        // the track changes. `pendingResolve` marks the window between choosing
        // a track and hearing its resolution back, during which the engine's
        // isPlayingChanged(false) from pausing the outgoing song must not flip
        // the transport state (see `isPlayingChanged`).
        public var engineHasItem = false
        public var resolveGeneration = 0
        public var pendingResolve = false
        public var consecutiveFailures = 0
        public var scrobbled = false
        public var startScrobbled = false
        public var isLoaded = false

        /// The list the player walks through (shuffled or ordered).
        public var activeQueue: [Track] { shuffleEnabled ? shuffledQueue : queue }

        public var upcomingTracks: [Track] {
            guard !activeQueue.isEmpty, currentIndex >= 0 else { return playNextList }
            let rest = activeQueue.suffix(from: min(currentIndex + 1, activeQueue.count))
            return playNextList + Array(rest.prefix(200))
        }

        public var hasCurrentTrack: Bool { currentTrack != nil }
    }

    public enum Action: Equatable {
        /// Subscribes to the engine's event streams and rehydrates the queue.
        /// Send once, at app launch.
        case onAppear

        // Engine events
        case timeTick(TimeInterval)
        case itemEnded
        case bufferingChanged(Double)
        case isPlayingChanged(Bool)

        // Transport
        /// Replace the queue with `tracks` and start at `startAt` (or the first).
        /// `context` lists the origin under Recently Played in the Dock menu.
        case play(tracks: [Track], source: PlaySource, startAt: Track?, context: PlayContext?)
        /// Play one track: jump to it if it is already queued, else queue it alone.
        case playTrack(Track)
        /// Loads `track` — resolves its URL, fetches lyrics, and hands the URL to
        /// the engine once known.
        case startPlaying(Track)
        /// Insert right after the current track; `playNow` bumps it to the front.
        case addToPlayNext(Track, playNow: Bool)
        case togglePlayPause
        case pause
        case next
        case previous
        case seek(TimeInterval)
        case jumpTo(Track)
        case removeFromUpcoming(Track)
        case toggleShuffle
        case cycleRepeatMode
        /// Single-button cycle for the iOS minimal transport row:
        /// sequential → loop all → loop one → shuffle → sequential.
        case cyclePlaybackMode
        /// Sets the repeat mode directly (the Dock menu's submenu).
        case setRepeatMode(RepeatMode)
        case setVolume(Float)
        /// Toggles the lyrics / queue side panel (macOS Commands menu).
        case togglePanel(RightPanel)

        // Resolution
        case urlResolved(generation: Int, autostart: Bool, ResolvedSource)
        /// A third-party source was used; surfaced as a toast by AppFeature.
        case unblockApplied(String)
        case lyricsResponse(generation: Int, ParsedLyrics?)
        /// Internal advance — the user asked for the next track or the current
        /// one ended. `userInitiated` decides between a toast and a silent stop
        /// at the end of the list.
        case advanceToNext(userInitiated: Bool)
        /// Stops playback without touching the queue (an unplayable track, a
        /// failed streak).
        case stopPlayback

        // Personal FM
        case startFM
        case fmNext
        case fmTrash
        case fmAdvance
        case fmFetch(autostart: Bool)
        case fmResponse(tracks: [Track], autostart: Bool)
        case fmAdvanceValidated(snapshotIDs: [Int], currentID: Int?, tracks: [Track])

        // Recents
        case playContext(PlayContext)
        case contextResolved(PlayContext, tracks: [Track], source: PlaySource)

        // Sleep timer
        indirect case sleepTimer(SleepTimerAction)

        /// Surfaced for AppFeature to forward to ToastsFeature.
        case toast(String)

        public enum SleepTimerAction: Equatable {
            case schedule(minutes: Int)
            case endOfCurrentTrack
            case cancel
            case fired
        }
    }

    /// What URL resolution found for a track.
    public struct ResolvedSource: Equatable {
        /// `nil` when no playable source existed at all.
        public var url: URL?
        public var servedQuality: String?
        public var isTrial: Bool
        public var unblockSource: String?
    }

    @Dependency(\.playback) public var playback
    @Dependency(\.musicProvider) public var provider
    @Dependency(\.personalFM) public var fm
    @Dependency(\.recentPlayback) public var recentPlayback
    @Dependency(\.unblock) public var unblock
    @Dependency(\.audioSourceFallback) public var audioSourceFallback
    @Dependency(\.persistence) public var persistence
    @Dependency(\.continuousClock) public var clock
    @Dependency(\.date) public var date

    private enum CancelID: Hashable, Sendable {
        case sleepTimer
    }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            // MARK: - Lifecycle

            case .onAppear:
                guard !state.isLoaded else { return .none }
                state.isLoaded = true
                state.restore(using: persistence)
                // A restored queue is paused: the engine has nothing loaded and
                // playback only starts when the user hits play (togglePlayPause
                // re-resolves the source then).
                return .merge(
                    .run { [playback] send in
                        for await seconds in playback.timeTicks() {
                            await send(.timeTick(seconds))
                        }
                    },
                    .run { [playback] send in
                        for await _ in playback.itemEnded() { await send(.itemEnded) }
                    },
                    .run { [playback] send in
                        for await buffering in playback.bufferingChanged() {
                            await send(.bufferingChanged(buffering))
                        }
                    },
                    .run { [playback] send in
                        for await isPlaying in playback.isPlayingChanged() {
                            await send(.isPlayingChanged(isPlaying))
                        }
                    },
                    .send(.setVolume(state.volume)),
                    state.currentTrack.map { track in
                        .run { [playback] _ in
                            playback.updateMetadata(
                                title: track.name, artist: track.artistNames,
                                album: track.album.name, coverURL: nil)
                        }
                    } ?? .none
                )

            // MARK: - Engine events

            case let .timeTick(seconds):
                // Until the new URL resolves, the engine still holds the old
                // item. Its ticks must not overwrite the new track's reset.
                guard state.engineHasItem else { return .none }
                // The scrubber does not need per-tick precision — half a second is
                // smoother than the eye needs. The lyric line cursor, computed in
                // the same pass, only publishes when the line actually changes.
                if abs(seconds - state.progress) > 0.45 {
                    state.progress = seconds
                }
                // Playback has genuinely moved on from the last jump, so any
                // end-of-item that follows is the song finishing.
                if let target = state.pendingSeekTarget, seconds > target + 0.5 {
                    state.pendingSeekTarget = nil
                }
                let cursor = state.lyrics?.activeIndex(at: seconds + 0.2)
                if cursor != state.lyricsCursorIndex {
                    state.lyricsCursorIndex = cursor
                }
                return .none

            case .itemEnded:
                let scrobbleFinish = scrobbleFinishEffect(&state, completed: true)

                if state.sleepTimer.consumeEndOfCurrentTrack() {
                    state.progress = state.duration
                    state.lyricsCursorIndex = state.lyrics?.activeIndex(at: state.duration)
                    state.isPlaying = false
                    state.playbackIntent = false
                    return .merge(scrobbleFinish, .send(.pause))
                }

                // An end that fires while a jump is still outstanding, while the
                // jump's grace window is still open, or while the playhead is
                // nowhere near the real end, is the jump, not the song finishing.
                // Two things produce one: a lyric timestamp or a scrub landing
                // past what the stream has buffered, so the engine clamps it to
                // the tail and reports the end a second later; and the ranged
                // re-download a jump forces stalling long enough for the
                // engine's frozen-time end detection to fire. That second one
                // can arrive late — after the playhead reached the jump target
                // and the pending marker above was cleared — so the playhead
                // position is checked as well. A genuine finish sits at the
                // tail; anything two seconds short is the jump. A track whose
                // duration was never reported has no tail to measure against,
                // so the grace window is what covers it.
                if let until = state.seekGuardUntil, date.now >= until {
                    state.seekGuardUntil = nil
                }
                let bogusEnd = state.pendingSeekTarget != nil
                    || state.seekGuardUntil != nil
                    || (state.duration > 0 && state.progress < state.duration - 2)
                if bogusEnd {
                    let progress = state.progress
                    let duration = state.duration
                    let pending = state.pendingSeekTarget.map { String($0) } ?? "none"
                    KumoneLogger.player.info(
                        "itemEnded ignored: jump or stall, progress=\(progress, format: .fixed(precision: 1)) duration=\(duration, format: .fixed(precision: 1)) pending=\(pending, privacy: .public)"
                    )
                    state.pendingSeekTarget = nil
                    // The engine paused on its way to reporting this; pick it
                    // back up where the jump landed rather than leaving the
                    // track stopped.
                    state.isPlaying = true
                    state.playbackIntent = true
                    return .merge(
                        scrobbleStartEffect(&state),
                        .run { [playback] _ in playback.play() }
                    )
                }

                // The user's transport intent decides whether the queue keeps
                // going — the engine's `isPlaying=false` at end-of-item is not
                // a pause, and arrives in either order relative to this action.
                guard state.playbackIntent else {
                    return scrobbleFinish
                }

                if state.repeatMode == .one, !state.isFMMode {
                    state.scrobbled = false
                    state.progress = 0
                    return .merge(
                        scrobbleFinish,
                        // The engine has already paused at the end of the item;
                        // rewind, then pick it back up.
                        .concatenate(
                            .send(.seek(0)),
                            .run { [playback] _ in playback.play() }
                        ),
                        scrobbleStartEffect(&state)
                    )
                }
                let advProgress = state.progress
                let advDuration = state.duration
                let advIntent = state.playbackIntent
                KumoneLogger.player.info(
                    "itemEnded advancing: progress=\(advProgress, format: .fixed(precision: 1)) duration=\(advDuration, format: .fixed(precision: 1)) intent=\(advIntent)"
                )
                return .merge(scrobbleFinish, .send(.advanceToNext(userInitiated: false)))

            case let .bufferingChanged(progress):
                // The stream reports progress continuously; only forward
                // meaningful changes so the transport does not redraw twice
                // per second for a number that barely moved.
                guard abs(state.bufferProgress - progress) > 0.005 else { return .none }
                state.bufferProgress = progress
                // Buffering only reads as "loading" while the user is waiting on
                // a track they asked to hear; a paused queue is not loading.
                // (Deriving from `isPlaying` alone flips back and forth with the
                // engine's end-of-item state events.)
                let buffering = progress > 0 && progress < 1 && state.playbackIntent && !state.isPlaying
                guard state.isBuffering != buffering else { return .none }
                state.isBuffering = buffering
                return .none

            case let .isPlayingChanged(isPlaying):
                // The engine's own pauses (an iOS interruption, a pulled route)
                // arrive here; the reducer's own play/pause commands produce the
                // same event, so the guard keeps state from churning.
                guard state.isPlaying != isPlaying else { return .none }
                // A track switch stops the outgoing song in the engine
                // (`startPlaying` pauses it while the new URL resolves). Its
                // isPlayingChanged(false) — and the one the previous track's
                // end-of-item fires between the switch and the resolution —
                // must not unpick the switch: the new track has not loaded yet
                // (`pendingResolve`), and clearing `isPlaying` here would flip
                // the transport to paused for the whole load and, worse, let
                // urlResolved read a stale intent.
                if !isPlaying, state.pendingResolve, state.currentTrack != nil {
                    return .none
                }
                state.isPlaying = isPlaying
                // Playback has begun: the preload fill is no longer a loading
                // state, even before the next buffering event arrives.
                if isPlaying, state.isBuffering { state.isBuffering = false }
                // A start scrobble belongs to playback actually starting — the
                // engine's `isPlaying=false` at end-of-item would otherwise
                // record one for a track on its way out. `urlResolved` already
                // records it when a track loads, so this only covers a start
                // the load never saw.
                return .merge(
                    isPlaying ? scrobbleStartEffect(&state) : .none,
                    isPlaying ? nowPlayingMetadataEffect(&state) : .none
                )

            // MARK: - Queue entry points

            case let .play(tracks, source, startAt, context):
                guard !tracks.isEmpty else { return .none }
                if let context { state.recordRecent(context) }
                state.isFMMode = false
                state.playbackIntent = true
                state.queue = tracks
                state.source = source
                state.playNextList = []
                let startTrack = startAt ?? tracks[0]
                if state.shuffleEnabled {
                    state.reshuffle(keeping: startTrack)
                    state.currentIndex = 0
                } else {
                    state.currentIndex = tracks.firstIndex { $0.id == startTrack.id } ?? 0
                }
                return .send(.startPlaying(startTrack))

            case let .playTrack(track):
                state.playbackIntent = true
                if let index = state.activeQueue.firstIndex(where: { $0.id == track.id }) {
                    state.currentIndex = index
                    return .send(.startPlaying(track))
                }
                return .send(.play(tracks: [track], source: .none, startAt: nil, context: nil))

            case let .addToPlayNext(track, playNow):
                state.playNextList.append(track)
                if playNow || state.currentTrack == nil {
                    return .send(.advanceToNext(userInitiated: true))
                }
                return .send(.toast(String(localized: "已添加到下一首播放")))

            case .togglePlayPause:
                guard let track = state.currentTrack else { return .none }
                if state.isPlaying {
                    return .send(.pause)
                }
                guard state.engineHasItem else {
                    // A restored queue: the engine has nothing loaded, so the
                    // source has to be resolved again.
                    state.playbackIntent = true
                    return .send(.startPlaying(track))
                }
                state.isPlaying = true
                state.playbackIntent = true
                return .merge(
                    .run { [playback] _ in playback.play() },
                    scrobbleStartEffect(&state)
                )

            case .pause:
                state.isPlaying = false
                state.playbackIntent = false
                state.pendingSeekTarget = nil
                state.seekGuardUntil = nil
                return .run { [playback] _ in playback.pause() }

            case .next:
                return .send(.advanceToNext(userInitiated: true))

            case .previous:
                if state.isFMMode { return .none }
                if state.progress > 4 || state.activeQueue.isEmpty {
                    return .send(.seek(0))
                }
                state.playbackIntent = true
                var index = state.currentIndex - 1
                if index < 0 {
                    guard state.repeatMode == .all else { return .send(.seek(0)) }
                    index = state.activeQueue.count - 1
                }
                state.currentIndex = index
                return .send(.startPlaying(state.activeQueue[index]))

            case let .seek(seconds):
                // A jump is an explicit transport gesture: the user wants this
                // position playing. The intent belongs to the jump, not to
                // whatever end-of-item event the engine emits next, and the
                // target is pulled back from the very end because the lyric
                // timestamps that produce one overhang the real stream length
                // (APlay clamps such a jump to `duration - 1`, which ends the
                // track a second later).
                let duration = state.duration
                let target = duration > 1
                    ? min(max(seconds, 0), duration - 1.5)
                    : max(seconds, 0)
                state.progress = target
                state.lyricsCursorIndex = state.lyrics?.activeIndex(at: target + 0.2)
                state.playbackIntent = true
                // Mirror the jump's play intent and explicitly resume below.
                // A buffering seek can leave the engine paused without ever
                // emitting itemEnded, so that recovery path is insufficient.
                state.isPlaying = true
                state.pendingSeekTarget = target
                state.seekGuardUntil = date.now.addingTimeInterval(3)
                let loggedDuration = state.duration
                KumoneLogger.player.info(
                    "seek target=\(target, format: .fixed(precision: 1)) duration=\(loggedDuration, format: .fixed(precision: 1))"
                )
                return .run { [playback] _ in
                    playback.seek(target)
                    playback.play()
                }

            case let .jumpTo(track):
                state.playbackIntent = true
                if let index = state.playNextList.firstIndex(where: { $0.id == track.id }) {
                    state.playNextList.removeSubrange(0...index)
                    return .send(.startPlaying(track))
                }
                if let index = state.activeQueue.firstIndex(where: { $0.id == track.id }) {
                    state.currentIndex = index
                    return .send(.startPlaying(track))
                }
                return .none

            case let .removeFromUpcoming(track):
                if let index = state.playNextList.firstIndex(where: { $0.id == track.id }) {
                    state.playNextList.remove(at: index)
                } else {
                    if let index = state.queue.firstIndex(where: { $0.id == track.id }),
                       index != state.currentIndex || state.shuffleEnabled
                    {
                        state.queue.remove(at: index)
                    }
                    if let index = state.shuffledQueue.firstIndex(where: { $0.id == track.id }) {
                        state.shuffledQueue.remove(at: index)
                    }
                }
                return .none

            case .toggleShuffle:
                guard !state.isFMMode else { return .none }
                state.shuffleEnabled.toggle()
                guard let current = state.currentTrack else { return .none }
                if state.shuffleEnabled {
                    state.reshuffle(keeping: current)
                    state.currentIndex = 0
                } else {
                    state.currentIndex = state.queue.firstIndex { $0.id == current.id } ?? 0
                }
                return .none

            case .cycleRepeatMode:
                guard !state.isFMMode else { return .none }
                state.repeatMode = state.repeatMode.next
                return .none

            case let .setRepeatMode(mode):
                guard !state.isFMMode else { return .none }
                state.repeatMode = mode
                return .none

            case .cyclePlaybackMode:
                guard !state.isFMMode else { return .none }
                if state.shuffleEnabled {
                    state.shuffleEnabled = false
                    if let current = state.currentTrack {
                        state.currentIndex = state.queue.firstIndex { $0.id == current.id } ?? 0
                    }
                    state.repeatMode = .off
                } else {
                    switch state.repeatMode {
                    case .off: state.repeatMode = .all
                    case .all: state.repeatMode = .one
                    case .one:
                        state.repeatMode = .off
                        return .send(.toggleShuffle)
                    }
                }
                return .none

            case let .setVolume(volume):
                state.volume = volume
                return .run { [playback] _ in playback.setVolume(volume) }

            case let .togglePanel(panel):
                state.activePanel = state.activePanel == panel ? nil : panel
                return .none

            // MARK: - Playing a track

            case let .startPlaying(track):
                // Scrobble the outgoing track before the state below replaces it.
                let scrobbleFinish = scrobbleFinishEffect(&state, completed: false)

                state.currentTrack = track
                state.progress = 0
                state.duration = track.duration
                // Keep the previous quality badge until the new URL resolves.
                // Clearing it here would empty the fixed 56pt slot in the bar's
                // right section for a moment, which shifts the centered
                // transport and makes the whole bar lurch on every skip.
                // urlResolved overwrites both once the new track resolves.
                state.isTrial = false
                state.lyrics = nil
                state.lyricsCursorIndex = nil
                state.scrobbled = false
                state.startScrobbled = false
                state.isPlaying = true
                state.engineHasItem = false
                state.bufferProgress = 0
                state.pendingSeekTarget = nil
                state.seekGuardUntil = nil
                state.resolveGeneration += 1
                state.pendingResolve = true
                let generation = state.resolveGeneration
                state.persist(using: persistence)

                return .merge(
                    scrobbleFinish,
                    .run { [playback] _ in
                        // Stop the outgoing track's audio the moment the new
                        // one is chosen, not when its URL resolves: the
                        // resolution network call can take a second or fail,
                        // and until it lands the engine keeps playing the
                        // previous song while the title already says the new
                        // one.
                        playback.pause()
                        playback.updateMetadata(
                            title: track.name, artist: track.artistNames, album: track.album.name, coverURL: nil)
                    },
                    resolveURLEffect(track: track, generation: generation, autostart: state.playbackIntent, state: state),
                    .run { [provider] send in
                        let response = try? await provider.lyric(id: MusicID(track.id))
                        await send(.lyricsResponse(
                            generation: generation, response.map(LyricsParser.parse)))
                    }
                )

            case let .urlResolved(generation, autostart, resolved):
                guard generation == state.resolveGeneration else { return .none }
                state.pendingResolve = false
                state.servedQuality = resolved.servedQuality
                state.unblockSource = resolved.unblockSource
                state.isTrial = resolved.isTrial

                guard let url = resolved.url else {
                    state.consecutiveFailures += 1
                    let reason = state.currentTrack?.playability(
                        privilege: nil, isLoggedIn: state.isLoggedIn, vipType: state.vipType).reason
                    let name = state.currentTrack?.name ?? ""
                    return .merge(
                        scrobbleFinishEffect(&state, completed: true),
                        .send(.toast(String(localized: "《\(name)》无法播放\(reason.map { "：\($0)" } ?? "")"))),
                        resolvedURLFailureEffect(state)
                    )
                }

                state.consecutiveFailures = 0
                state.engineHasItem = true
                // `autostart` was decided when the track was chosen — reading
                // `state.isPlaying` here would race the end-of-item
                // `isPlayingChanged(false)` of the previous track, which can
                // land between `startPlaying` and this action and silently turn
                // the load into a prepare-only one.
                return .merge(
                    .run { [playback, currentTrack = state.currentTrack] _ in
                        // Publish the new track with the load itself so the system
                        // card never describes the previous track in the gap
                        // before updateMetadata lands (APlay PR #20).
                        let metadata = currentTrack.map { track in
                            APlay.NowPlayingMetadata(
                                title: track.name,
                                artist: track.artistNames,
                                album: track.album.name,
                                artworkURL: track.album.picUrl
                            )
                        }
                        playback.load(url, autostart, metadata)
                    },
                    scrobbleStartEffect(&state),
                    resolved.isTrial
                        ? .send(.toast(String(localized: "VIP 歌曲，当前为试听片段")))
                        : .none
                )

            case let .unblockApplied(source):
                return .send(.toast(String(localized: "已使用第三方音源：\(source)")))

            case let .lyricsResponse(generation, lyrics):
                guard generation == state.resolveGeneration else { return .none }
                state.lyrics = lyrics
                state.lyricsCursorIndex = lyrics?.activeIndex(at: state.progress + 0.2)
                return .none

            case let .advanceToNext(userInitiated):
                if userInitiated { state.playbackIntent = true }
                if state.isFMMode {
                    return .send(.fmAdvance)
                }
                if !state.playNextList.isEmpty {
                    let track = state.playNextList.removeFirst()
                    return .send(.startPlaying(track))
                }
                guard !state.activeQueue.isEmpty else { return .none }
                var index = state.currentIndex + 1
                if index >= state.activeQueue.count {
                    guard state.repeatMode == .all else {
                        if userInitiated {
                            return .send(.toast(String(localized: "已经是最后一首了")))
                        }
                        return .send(.stopPlayback)
                    }
                    index = 0
                }
                state.currentIndex = index
                return .send(.startPlaying(state.activeQueue[index]))

            case .stopPlayback:
                state.isPlaying = false
                state.playbackIntent = false
                return .run { [playback] _ in playback.clear() }

            // MARK: - Personal FM

            case .startFM:
                guard !(state.isFMMode && state.isPlaying) else { return .none }
                state.playbackIntent = true
                state.recordRecent(.fm)
                state.isFMMode = true
                state.shuffleEnabled = false
                state.repeatMode = .off
                state.queue = []
                state.shuffledQueue = []
                state.playNextList = []
                state.currentIndex = -1
                state.source = .none
                state.fmUpcoming = []
                return .send(.fmFetch(autostart: true))

            case .fmNext:
                guard state.isFMMode else { return .none }
                state.playbackIntent = true
                return .send(.fmAdvance)

            case let .fmFetch(autostart):
                let currentID = state.currentTrack?.id
                return .run { [fm, clock, recentPlayback] send in
                    var tracks: [Track] = []
                    for attempt in 0..<3 {
                        if let fetched = try? await fm?.personalFM() {
                            let filtered = await recentPlayback.filter(fetched)
                                .filter { $0.id != currentID }
                            if !filtered.isEmpty {
                                tracks = filtered
                                break
                            }
                        }
                        if attempt == 2 { break }
                        try? await clock.sleep(for: .seconds(1))
                    }
                    await send(.fmResponse(tracks: tracks, autostart: autostart))
                }

            case let .fmResponse(tracks, autostart):
                guard state.isFMMode else { return .none }
                var seen = Set(state.fmUpcoming.map(\.id))
                if let currentID = state.currentTrack?.id { seen.insert(currentID) }
                state.fmUpcoming.append(contentsOf: tracks.filter { seen.insert($0.id).inserted })
                guard autostart, !state.fmUpcoming.isEmpty else { return .none }
                return .send(.fmAdvance)

            case .fmAdvance:
                guard state.isFMMode else { return .none }
                guard !state.fmUpcoming.isEmpty else { return .send(.fmFetch(autostart: true)) }
                let upcoming = state.fmUpcoming
                let currentID = state.currentTrack?.id
                return .run { [recentPlayback] send in
                    let filtered = await recentPlayback.filter(upcoming)
                    await send(.fmAdvanceValidated(
                        snapshotIDs: upcoming.map(\.id), currentID: currentID,
                        tracks: filtered))
                }

            case let .fmAdvanceValidated(snapshotIDs, currentID, tracks):
                // Do not let a suspended filter overwrite a newer queue or
                // advance twice after another rapid-next request completed.
                guard state.isFMMode,
                      state.currentTrack?.id == currentID,
                      state.fmUpcoming.map(\.id) == snapshotIDs else { return .none }
                var seen = Set<Int>()
                if let currentID { seen.insert(currentID) }
                state.fmUpcoming = tracks.filter { seen.insert($0.id).inserted }
                guard !state.fmUpcoming.isEmpty else { return .send(.fmFetch(autostart: true)) }
                let track = state.fmUpcoming.removeFirst()
                // Keep one batch ahead so the next track needs no reopen.
                return .merge(
                    .send(.startPlaying(track)),
                    state.fmUpcoming.isEmpty ? .send(.fmFetch(autostart: false)) : .none
                )

            case .fmTrash:
                guard state.isFMMode, let track = state.currentTrack else { return .none }
                state.playbackIntent = true
                return .merge(
                    .send(.fmAdvance),
                    .run { [fm] _ in try? await fm?.fmTrash(MusicID(track.id)) }
                )

            // MARK: - Recents

            case let .playContext(context):
                guard context.kind != .fm else { return .send(.startFM) }
                return .run { [provider] send in
                    guard let resolved = try? await Self.resolve(context, using: provider)
                    else { return }
                    await send(.contextResolved(
                        context, tracks: resolved.tracks, source: resolved.source))
                }

            case let .contextResolved(context, tracks, source):
                return .send(.play(tracks: tracks, source: source, startAt: nil, context: context))

            // MARK: - Sleep timer

            case .sleepTimer(.schedule(let minutes)):
                precondition(minutes > 0, "Sleep timer duration must be positive")
                state.sleepTimer.schedule(minutes: minutes, now: date.now)
                return .run { [clock] send in
                    try? await clock.sleep(for: .seconds(TimeInterval(minutes * 60)))
                    await send(.sleepTimer(.fired))
                }
                .cancellable(id: CancelID.sleepTimer, cancelInFlight: true)

            case .sleepTimer(.endOfCurrentTrack):
                state.sleepTimer.scheduleAtEndOfCurrentTrack()
                return .cancel(id: CancelID.sleepTimer)

            case .sleepTimer(.cancel):
                state.sleepTimer.cancel()
                return .cancel(id: CancelID.sleepTimer)

            case .sleepTimer(.fired):
                state.sleepTimer.cancel()
                state.isPlaying = false
                return .send(.pause)

            case .toast:
                // AppFeature forwards this to ToastsFeature.
                return .none
            }
        }
    }

    // MARK: - Effects

    /// Resolves a playable URL for `track`, falling back to third-party sources
    /// when NetEase refuses or only offers a trial clip.
    private func resolveURLEffect(track: Track, generation: Int, autostart: Bool, state: State) -> Effect<Action> {
        .run { [provider, unblock, audioSourceFallback] send in
            let quality = state.audioQuality
            var data = try? await provider.songURL(ids: [MusicID(track.id)], quality: SongQuality(neteaseLevel: quality.rawValue)!).first
            if data?.url == nil, quality != .standard {
                data = try? await provider.songURL(
                    ids: [MusicID(track.id)], quality: .standard).first
            }
            var url = data?.url.map {
                URL(string: $0.replacingOccurrences(of: "http://", with: "https://"))
            } ?? nil
            var unblockSource: String?
            if (url == nil || data?.freeTrialInfo != nil), state.enableUnblock {
                if let resolved = await unblock.resolve(track) {
                    url = resolved.url
                    unblockSource = resolved.source
                    data = nil
                    await send(.unblockApplied(resolved.source))
                }
            }
            // Audio source fallback (upstream 07225a5): the main provider and
            // the unblock both refused the track, so retry on the Kuwo mirror.
            // Comes last because the mirror's catalog is a keyword match, not
            // a catalogue id, so it is strictly less precise than either.
            if (url == nil || data?.freeTrialInfo != nil), state.enableAudioSourceFallback {
                if let resolved = await audioSourceFallback.resolve(track) {
                    url = resolved.url
                    unblockSource = resolved.source
                    data = nil
                    await send(.unblockApplied(resolved.source))
                }
            }
            await send(.urlResolved(
                generation: generation,
                autostart: autostart,
                ResolvedSource(
                    url: url,
                    servedQuality: data?.level,
                    isTrial: data?.freeTrialInfo != nil,
                    unblockSource: unblockSource)))
        }
    }

    /// Records the start of playback once per track. Marks `startScrobbled`
    /// before returning so retries cannot double-send.
    private func scrobbleStartEffect(_ state: inout State) -> Effect<Action> {
        guard let track = state.currentTrack, !state.startScrobbled else { return .none }
        state.startScrobbled = true
        let trackID = track.id
        let sourceID = state.source.sourceID
        return .run { [provider, recentPlayback] _ in
            await recentPlayback.record(trackID)
            await provider.scrobbleStart(trackID: MusicID(trackID), sourceID: MusicID(sourceID))
        }
    }

    /// Re-pushes Now Playing metadata once playback has actually begun.
    ///
    /// The engine clears the Now Playing slot when it starts a track — `_play`
    /// runs `resetFlag` → `remove` — and the metadata pushed at track selection
    /// happens *before* the URL is resolved, so it is wiped before anything
    /// sees it. By the time `isPlayingChanged(true)` arrives the slot is stable,
    /// so the title/artist/album land for real, this time with the cover: the
    /// engine fetches the artwork from `coverURL` itself.
    private func nowPlayingMetadataEffect(_ state: inout State) -> Effect<Action> {
        guard let track = state.currentTrack else { return .none }
        let title = track.name
        let artist = track.artistNames
        let album = track.album.name
        let coverURL = track.album.picUrl.flatMap(URL.init(string:))
        return .run { [playback] _ in
            playback.updateMetadata(title: title, artist: artist, album: album, coverURL: coverURL)
        }
    }

    /// Records the end of playback, as a completion or at the point the user
    /// left it. Marks `scrobbled` so a track only ever reports once.
    private func scrobbleFinishEffect(_ state: inout State, completed: Bool) -> Effect<Action> {
        guard let track = state.currentTrack, !state.scrobbled, state.progress > 1
        else { return .none }
        state.scrobbled = true
        let trackID = track.id
        let sourceID = state.source.sourceID
        let seconds = completed ? Int(state.duration) : Int(state.progress)
        return .run { [provider] _ in
            await provider.scrobbleFinish(trackID: MusicID(trackID), sourceID: MusicID(sourceID), seconds: seconds)
        }
    }

    /// What to do when a track turned out to be unplayable: stop, or silently
    /// move on (up to five times in a row, so a dead playlist doesn't run away).
    private func resolvedURLFailureEffect(_ state: State) -> Effect<Action> {
        guard state.isPlaying else { return .send(.stopPlayback) }
        guard state.consecutiveFailures < 5 else { return .send(.stopPlayback) }
        return .send(.advanceToNext(userInitiated: false))
    }

    // MARK: - Context resolution

    /// Reloads a place from the recents list so it can be played again.
    public static func resolve(
        _ context: PlayContext, using provider: any MusicProvider
    ) async throws -> (tracks: [Track], source: PlaySource)? {
        switch context.kind {
        case .fm:
            return nil
        case .album:
            return (try await provider.album(id: MusicID(context.id)).songs, .album(context.id))
        case .artist:
            return (try await provider.artist(id: MusicID(context.id)).hotSongs, .artist(context.id))
        case .daily:
            return (try await provider.dailyRecommendSongs(), .daily)
        case .cloud:
            @Dependency(\.cloudStorage) var cloud
            let songs = try await cloud?.cloudSongs(limit: 100, offset: 0)
                .items.compactMap(\.simpleSong) ?? []
            return (songs, .cloud)
        case .recents, .heartbeat:
            // Regenerated per-account at the call site (recents needs a uid and
            // heartbeat needs the liked-songs seed), not from here.
            return nil
        case .playlist:
            let response = try await provider.playlistDetail(id: MusicID(context.id))
            var tracks = response.tracks
            // /v6/playlist/detail only carries the first page of tracks.
            let remaining = response.trackIds.map(\.id).dropFirst(tracks.count)
            for chunk in stride(from: 0, to: remaining.count, by: 500)
                .map({ Array(remaining.dropFirst($0).prefix(500)) })
            {
                guard let more = try? await provider.songDetails(ids: chunk.map { MusicID($0) }) else { break }
                tracks += more
            }
            return (tracks, .playlist(context.id))
        }
    }
}

// MARK: - Constants

extension PlayerFeature {
    public static let persistedStateKey = "player.state"
}

// MARK: - Sleep timer state

extension PlayerFeature {
    public struct SleepTimerState: Equatable {
        public enum Mode: Equatable {
            case inactive
            case countdown(deadline: Date)
            case endOfCurrentTrack
        }

        public var mode: Mode = .inactive
        public var isActive: Bool { mode != .inactive }

        public mutating func schedule(minutes: Int, now: Date) {
            mode = .countdown(deadline: now.addingTimeInterval(TimeInterval(minutes * 60)))
        }

        public mutating func scheduleAtEndOfCurrentTrack() {
            mode = .endOfCurrentTrack
        }

        public mutating func cancel() {
            mode = .inactive
        }

        /// Returns `true` when the timer was set to stop here, consuming it.
        public mutating func consumeEndOfCurrentTrack() -> Bool {
            guard mode == .endOfCurrentTrack else { return false }
            mode = .inactive
            return true
        }
    }
}

// MARK: - State helpers

extension PlayerFeature.State {
    /// Shuffles the queue with `first` pinned to the front.
    public mutating func reshuffle(keeping first: Track) {
        var rest = queue.filter { $0.id != first.id }
        rest.shuffle()
        shuffledQueue = [first] + rest
    }

    /// Prepends `context` to the recents list, capped at six.
    public mutating func recordRecent(_ context: PlayContext) {
        recentContexts.removeAll { $0 == context }
        recentContexts.insert(context, at: 0)
        if recentContexts.count > Self.recentContextsLimit {
            recentContexts.removeLast(recentContexts.count - Self.recentContextsLimit)
        }
    }

    public mutating func persist(using persistence: PersistenceClient) {
        let persisted = PersistedState(
            queue: Array(queue.prefix(1000)),
            currentID: currentTrack?.id,
            repeatMode: repeatMode.rawValue,
            shuffle: shuffleEnabled,
            volume: volume,
            recentContexts: recentContexts
        )
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        persistence.setData(data, PlayerFeature.persistedStateKey)
    }

    public mutating func restore(using persistence: PersistenceClient) {
        guard let data = persistence.dataForKey(PlayerFeature.persistedStateKey),
              let persisted = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return }
        // Recents outlive the queue: restore them before bailing on an empty
        // queue, or the next played track persists an empty list over them and
        // the Dock menu loses its history for good.
        recentContexts = Array((persisted.recentContexts ?? []).prefix(Self.recentContextsLimit))
        repeatMode = RepeatMode(rawValue: persisted.repeatMode) ?? .off
        shuffleEnabled = persisted.shuffle
        volume = persisted.volume
        guard !persisted.queue.isEmpty else { return }
        queue = persisted.queue
        if shuffleEnabled {
            shuffledQueue = queue.shuffled()
        }
        if let id = persisted.currentID,
           let index = activeQueue.firstIndex(where: { $0.id == id })
        {
            currentIndex = index
            currentTrack = activeQueue[index]
            duration = activeQueue[index].duration
        }
    }

    public static let recentContextsLimit = 6

    fileprivate struct PersistedState: Codable {
        var queue: [Track]
        var currentID: Int?
        var repeatMode: String
        var shuffle: Bool
        var volume: Float = 0.8
        /// Optional so state files written before these fields existed still decode.
        var recentContexts: [PlayContext]?
    }
}
