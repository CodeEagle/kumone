import ComposableArchitecture
import Dependencies
import Foundation

/// The lyrics / queue side panel on macOS.
enum RightPanel {
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
struct PlayerFeature {
    @ObservableState
    struct State: Equatable {
        var queue: [Track] = []
        var shuffledQueue: [Track] = []
        var playNextList: [Track] = []
        var currentIndex = -1
        var currentTrack: Track?
        var source: PlaySource = .none
        var isPlaying = false
        var isBuffering = false
        var progress: TimeInterval = 0
        var duration: TimeInterval = 0
        var servedQuality: String?
        var unblockSource: String?
        var isTrial = false
        var repeatMode: RepeatMode = .off
        var shuffleEnabled = false
        var volume: Float = 0.8
        var isFMMode = false
        var fmUpcoming: [Track] = []
        var recentContexts: [PlayContext] = []
        var lyrics: ParsedLyrics?
        var lyricsCursorIndex: Int?
        /// The lyrics / queue side panel (macOS). `nil` while hidden.
        var activePanel: RightPanel?

        var sleepTimer = SleepTimerState()

        // Mirrored from SettingsFeature / AccountFeature by AppFeature — the
        // sibling features own the storage, the player only needs the values.
        var audioQuality: AudioQuality = .exhigh
        var enableUnblock = true
        var isLoggedIn = false
        var vipType = 0

        // Engine bookkeeping. `engineHasItem` tracks whether APlay has a loaded
        // item, which the reducer cannot see any other way — it decides whether
        // a play/pause tap resumes the current item or re-resolves a restored
        // queue. `resolveGeneration` invalidates in-flight URL/lyrics work when
        // the track changes.
        var engineHasItem = false
        var resolveGeneration = 0
        var consecutiveFailures = 0
        var scrobbled = false
        var startScrobbled = false
        var isLoaded = false

        /// The list the player walks through (shuffled or ordered).
        var activeQueue: [Track] { shuffleEnabled ? shuffledQueue : queue }

        var upcomingTracks: [Track] {
            guard !activeQueue.isEmpty, currentIndex >= 0 else { return playNextList }
            let rest = activeQueue.suffix(from: min(currentIndex + 1, activeQueue.count))
            return playNextList + Array(rest.prefix(200))
        }

        var hasCurrentTrack: Bool { currentTrack != nil }
    }

    enum Action: Equatable {
        /// Subscribes to the engine's event streams and rehydrates the queue.
        /// Send once, at app launch.
        case onAppear

        // Engine events
        case timeTick(TimeInterval)
        case itemEnded
        case bufferingChanged(Bool)
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
        case urlResolved(generation: Int, ResolvedSource)
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

        // Recents
        case playContext(PlayContext)
        case contextResolved(PlayContext, tracks: [Track], source: PlaySource)

        // Sleep timer
        indirect case sleepTimer(SleepTimerAction)

        /// Surfaced for AppFeature to forward to ToastsFeature.
        case toast(String)

        enum SleepTimerAction: Equatable {
            case schedule(minutes: Int)
            case endOfCurrentTrack
            case cancel
            case fired
        }
    }

    /// What URL resolution found for a track.
    struct ResolvedSource: Equatable {
        /// `nil` when no playable source existed at all.
        var url: URL?
        var servedQuality: String?
        var isTrial: Bool
        var unblockSource: String?
    }

    @Dependency(\.playback) var playback
    @Dependency(\.netease) var netease
    @Dependency(\.unblock) var unblock
    @Dependency(\.persistence) var persistence
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date) var date

    private enum CancelID: Hashable, Sendable {
        case sleepTimer
    }

    var body: some ReducerOf<Self> {
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
                        for await seconds in await playback.timeTicks() {
                            await send(.timeTick(seconds))
                        }
                    },
                    .run { [playback] send in
                        for await _ in await playback.itemEnded() { await send(.itemEnded) }
                    },
                    .run { [playback] send in
                        for await buffering in await playback.bufferingChanged() {
                            await send(.bufferingChanged(buffering))
                        }
                    },
                    .run { [playback] send in
                        for await isPlaying in await playback.isPlayingChanged() {
                            await send(.isPlayingChanged(isPlaying))
                        }
                    },
                    .send(.setVolume(state.volume)),
                    state.currentTrack.map { track in
                        .run { [playback] _ in
                            playback.updateMetadata(
                                title: track.name, artist: track.artistNames,
                                album: track.album.name)
                        }
                    } ?? .none
                )

            // MARK: - Engine events

            case let .timeTick(seconds):
                // The scrubber does not need per-tick precision — half a second is
                // smoother than the eye needs. The lyric line cursor, computed in
                // the same pass, only publishes when the line actually changes.
                if abs(seconds - state.progress) > 0.45 {
                    state.progress = seconds
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
                    return .merge(scrobbleFinish, .send(.pause))
                }

                guard state.isPlaying else { return scrobbleFinish }

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
                return .merge(scrobbleFinish, .send(.advanceToNext(userInitiated: false)))

            case let .bufferingChanged(buffering):
                guard state.isBuffering != buffering else { return .none }
                state.isBuffering = buffering
                return .none

            case let .isPlayingChanged(isPlaying):
                // The engine's own pauses (an iOS interruption, a pulled route)
                // arrive here; the reducer's own play/pause commands produce the
                // same event, so the guard keeps state from churning.
                guard state.isPlaying != isPlaying else { return .none }
                state.isPlaying = isPlaying
                return scrobbleStartEffect(&state)

            // MARK: - Queue entry points

            case let .play(tracks, source, startAt, context):
                guard !tracks.isEmpty else { return .none }
                if let context { state.recordRecent(context) }
                state.isFMMode = false
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
                    return .send(.startPlaying(track))
                }
                state.isPlaying = true
                return .merge(
                    .run { [playback] _ in playback.play() },
                    scrobbleStartEffect(&state)
                )

            case .pause:
                state.isPlaying = false
                return .run { [playback] _ in playback.pause() }

            case .next:
                return .send(.advanceToNext(userInitiated: true))

            case .previous:
                if state.isFMMode { return .none }
                if state.progress > 4 || state.activeQueue.isEmpty {
                    return .send(.seek(0))
                }
                var index = state.currentIndex - 1
                if index < 0 {
                    guard state.repeatMode == .all else { return .send(.seek(0)) }
                    index = state.activeQueue.count - 1
                }
                state.currentIndex = index
                return .send(.startPlaying(state.activeQueue[index]))

            case let .seek(seconds):
                state.progress = seconds
                state.lyricsCursorIndex = state.lyrics?.activeIndex(at: seconds + 0.2)
                return .run { [playback] _ in playback.seek(seconds) }

            case let .jumpTo(track):
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
                state.servedQuality = nil
                state.unblockSource = nil
                state.isTrial = false
                state.lyrics = nil
                state.lyricsCursorIndex = nil
                state.scrobbled = false
                state.startScrobbled = false
                state.isPlaying = true
                state.engineHasItem = false
                state.resolveGeneration += 1
                let generation = state.resolveGeneration
                state.persist(using: persistence)

                return .merge(
                    scrobbleFinish,
                    .run { [playback] _ in
                        playback.updateMetadata(
                            title: track.name, artist: track.artistNames, album: track.album.name)
                    },
                    resolveURLEffect(track: track, generation: generation, state: state),
                    .run { [netease] send in
                        let response = try? await netease.lyric(id: track.id)
                        await send(.lyricsResponse(
                            generation: generation, response.map(LyricsParser.parse)))
                    }
                )

            case let .urlResolved(generation, resolved):
                guard generation == state.resolveGeneration else { return .none }
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
                let autostart = state.isPlaying
                return .merge(
                    .run { [playback] _ in playback.load(url, autostart) },
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
                return .run { [playback] _ in playback.clear() }

            // MARK: - Personal FM

            case .startFM:
                guard !(state.isFMMode && state.isPlaying) else { return .none }
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
                return .send(.fmAdvance)

            case let .fmFetch(autostart):
                return .run { [netease, clock] send in
                    var tracks: [Track] = []
                    for attempt in 0..<3 {
                        if let fetched = try? await netease.personalFM(), !fetched.isEmpty {
                            tracks = fetched
                            break
                        }
                        if attempt == 2 { break }
                        try? await clock.sleep(for: .seconds(1))
                    }
                    await send(.fmResponse(tracks: tracks, autostart: autostart))
                }

            case let .fmResponse(tracks, autostart):
                state.fmUpcoming.append(contentsOf: tracks)
                guard autostart, !state.fmUpcoming.isEmpty else { return .none }
                return .send(.fmAdvance)

            case .fmAdvance:
                guard state.isFMMode else { return .none }
                guard !state.fmUpcoming.isEmpty else { return .send(.fmFetch(autostart: true)) }
                let track = state.fmUpcoming.removeFirst()
                // Keep one batch ahead so the next track needs no reopen.
                return .merge(
                    .send(.startPlaying(track)),
                    state.fmUpcoming.isEmpty ? .send(.fmFetch(autostart: false)) : .none
                )

            case .fmTrash:
                guard state.isFMMode, let track = state.currentTrack else { return .none }
                return .merge(
                    .send(.fmAdvance),
                    .run { [netease] _ in try? await netease.fmTrash(id: track.id) }
                )

            // MARK: - Recents

            case let .playContext(context):
                guard context.kind != .fm else { return .send(.startFM) }
                return .run { [netease] send in
                    guard let resolved = try? await Self.resolve(context, using: netease)
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
    private func resolveURLEffect(track: Track, generation: Int, state: State) -> Effect<Action> {
        .run { [netease, unblock] send in
            let quality = state.audioQuality
            var data = try? await netease.songURL(ids: [track.id], level: quality.rawValue).first
            if data?.url == nil, quality != .standard {
                data = try? await netease.songURL(
                    ids: [track.id], level: AudioQuality.standard.rawValue).first
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
            await send(.urlResolved(
                generation: generation,
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
        return .run { [netease] _ in
            await netease.scrobbleStart(trackID: trackID, sourceID: sourceID)
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
        return .run { [netease] _ in
            await netease.scrobbleFinish(trackID: trackID, sourceID: sourceID, seconds: seconds)
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
    static func resolve(
        _ context: PlayContext, using netease: NeteaseMusicClient
    ) async throws -> (tracks: [Track], source: PlaySource)? {
        switch context.kind {
        case .fm:
            return nil
        case .album:
            return (try await netease.album(id: context.id).songs, .album(context.id))
        case .artist:
            return (try await netease.artist(id: context.id).hotSongs, .artist(context.id))
        case .daily:
            return (try await netease.dailyRecommendSongs(), .daily)
        case .cloud:
            let songs = try await netease.cloudSongs(limit: 100, offset: 0)
                .data?.compactMap(\.simpleSong) ?? []
            return (songs, .cloud)
        case .recents, .heartbeat:
            // Regenerated per-account at the call site (recents needs a uid and
            // heartbeat needs the liked-songs seed), not from here.
            return nil
        case .playlist:
            let response = try await netease.playlistDetail(id: context.id)
            var tracks = response.playlist.tracks
            // /v6/playlist/detail only carries the first page of tracks.
            let remaining = response.playlist.trackIds.map(\.id).dropFirst(tracks.count)
            for chunk in stride(from: 0, to: remaining.count, by: 500)
                .map({ Array(remaining.dropFirst($0).prefix(500)) })
            {
                guard let more = try? await netease.songDetails(ids: chunk) else { break }
                tracks += more.songs
            }
            return (tracks, .playlist(context.id))
        }
    }
}

// MARK: - Constants

extension PlayerFeature {
    static let persistedStateKey = "player.state"
}

// MARK: - Sleep timer state

extension PlayerFeature {
    struct SleepTimerState: Equatable {
        enum Mode: Equatable {
            case inactive
            case countdown(deadline: Date)
            case endOfCurrentTrack
        }

        var mode: Mode = .inactive
        var isActive: Bool { mode != .inactive }

        mutating func schedule(minutes: Int, now: Date) {
            mode = .countdown(deadline: now.addingTimeInterval(TimeInterval(minutes * 60)))
        }

        mutating func scheduleAtEndOfCurrentTrack() {
            mode = .endOfCurrentTrack
        }

        mutating func cancel() {
            mode = .inactive
        }

        /// Returns `true` when the timer was set to stop here, consuming it.
        mutating func consumeEndOfCurrentTrack() -> Bool {
            guard mode == .endOfCurrentTrack else { return false }
            mode = .inactive
            return true
        }
    }
}

// MARK: - State helpers

extension PlayerFeature.State {
    /// Shuffles the queue with `first` pinned to the front.
    mutating func reshuffle(keeping first: Track) {
        var rest = queue.filter { $0.id != first.id }
        rest.shuffle()
        shuffledQueue = [first] + rest
    }

    /// Prepends `context` to the recents list, capped at six.
    mutating func recordRecent(_ context: PlayContext) {
        recentContexts.removeAll { $0 == context }
        recentContexts.insert(context, at: 0)
        if recentContexts.count > Self.recentContextsLimit {
            recentContexts.removeLast(recentContexts.count - Self.recentContextsLimit)
        }
    }

    mutating func persist(using persistence: PersistenceClient) {
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

    mutating func restore(using persistence: PersistenceClient) {
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

    static let recentContextsLimit = 6

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
