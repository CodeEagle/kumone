import AVFoundation
import APlay
import ComposableArchitecture
import Foundation

/// The playback engine, as a dependency.
///
/// Backed by `APlay` (the sibling AudioUnit/AVAudioEngine player). Commands are
/// fire-and-forget; playback events (periodic time, item end, buffering, state)
/// arrive as actions so the reducer stays the single source of truth. Karaoke
/// word highlighting reads `currentTime` directly — it needs per-frame precision,
/// which does not belong in reducer state.
@DependencyClient
struct PlaybackEngineClient {
    // MARK: - Commands

    /// Replaces the current item and begins playing if `autostart`. When
    /// `autostart` is false the stream is buffered but the output unit is not
    /// started, so a later `play` of the same URL picks up immediately.
    var load: @Sendable (_ url: URL, _ autostart: Bool) -> Void = { _, _ in }
    var play: @Sendable () -> Void = {}
    var pause: @Sendable () -> Void = {}
    var seek: @Sendable (_ seconds: TimeInterval) -> Void = { _ in }
    var setVolume: @Sendable (_ volume: Float) -> Void = { _ in }
    /// Stops playback (used when playback stops for good).
    var clear: @Sendable () -> Void = {}
    /// Pushes the current track's title/artist/album onto the system's Now
    /// Playing surface (lock screen, Control Center, AirPlay 2).
    var updateMetadata: @Sendable (_ title: String, _ artist: String, _ album: String) -> Void = { _, _, _ in }

    // MARK: - Reads

    /// Live playback position straight from the player, for smooth per-frame
    /// karaoke highlighting. Do NOT put this in reducer state.
    var currentTime: @Sendable () -> TimeInterval = { 0 }

    // MARK: - Events

    /// Coarse position ticks (~1/s) for the scrubber and lyric line cursor.
    var timeTicks: @Sendable () -> AsyncStream<TimeInterval> = { .never }
    /// Fired when the current item plays to its end.
    var itemEnded: @Sendable () -> AsyncStream<Void> = { .never }
    /// Waiting-to-play → buffering state.
    var bufferingChanged: @Sendable () -> AsyncStream<Bool> = { .never }
    /// Playback state as the engine sees it — including the pauses it applies on
    /// its own (an iOS interruption, an unplugged route), which the reducer
    /// would otherwise never hear about.
    var isPlayingChanged: @Sendable () -> AsyncStream<Bool> = { .never }
}

// MARK: - Live

extension PlaybackEngineClient: DependencyKey {
    static let liveValue = {
        let engine = PlaybackEngine()
        return PlaybackEngineClient(
            load: { url, autostart in engine.load(url: url, autostart: autostart) },
            play: { engine.play() },
            pause: { engine.pause() },
            seek: { seconds in engine.seek(to: seconds) },
            setVolume: { volume in engine.setVolume(volume) },
            clear: { engine.clear() },
            updateMetadata: { title, artist, album in engine.updateMetadata(title: title, artist: artist, album: album) },
            currentTime: { engine.currentTime() },
            timeTicks: { engine.timeTicks },
            itemEnded: { engine.itemEnded },
            bufferingChanged: { engine.bufferingChanged },
            isPlayingChanged: { engine.isPlayingChanged }
        )
    }()

    // `@DependencyClient` (1.17) does not synthesize a `testValue`, and the
    // `@DependencyEndpoint` defaults trap with "Unimplemented" when called. The
    // engine's streams simply never deliver in tests; tests that assert on a
    // command override the endpoint (or the whole client) per-store.
    static let testValue = PlaybackEngineClient(
        load: { _, _ in },
        play: {},
        pause: {},
        seek: { _ in },
        setVolume: { _ in },
        clear: {},
        updateMetadata: { _, _, _ in },
        currentTime: { 0 },
        timeTicks: { .never },
        itemEnded: { .never },
        bufferingChanged: { .never },
        isPlayingChanged: { .never }
    )
}

extension DependencyValues {
    var playback: PlaybackEngineClient {
        get { self[PlaybackEngineClient.self] }
        set { self[PlaybackEngineClient.self] = newValue }
    }
}

/// One `APlay` instance held for the app's whole lifetime (by `liveValue`), so
/// the event streams are subscribed once and replayed never.
///
/// APlay's own playlist/loop/next/previous machinery is deliberately left
/// alone: queue ordering, shuffle, personal FM and the play-next list live in
/// the reducer, which always loads a single URL at a time. Remote-command
/// handling and ID3 auto-fill are turned off in the configuration for the same
/// reason — the framework's built-in handlers would drive its own playlist.
/// iOS interruption and route-change handling stay on, so the engine pauses and
/// resumes itself and reports the change through `isPlayingChanged`.
fileprivate final class PlaybackEngine: @unchecked Sendable {
    private let player: APlay

    fileprivate let timeTicks: AsyncStream<TimeInterval>
    private let timeTicksContinuation: AsyncStream<TimeInterval>.Continuation
    fileprivate let itemEnded: AsyncStream<Void>
    private let itemEndedContinuation: AsyncStream<Void>.Continuation
    fileprivate let bufferingChanged: AsyncStream<Bool>
    private let bufferingChangedContinuation: AsyncStream<Bool>.Continuation
    fileprivate let isPlayingChanged: AsyncStream<Bool>
    private let isPlayingChangedContinuation: AsyncStream<Bool>.Continuation

    init() {
        let configuration = APlay.Configuration(
            // Network streams carry no ID3 tags — the reducer pushes track
            // metadata via `metadataUpdate`.
            autoFillID3InfoToNowPlayingCenter: false,
            // The reducer decides what follows the current track.
            gaplessPlaybackEnabled: false,
            // The reducer owns the queue; APlay's built-in command handlers
            // would advance the framework's own playlist instead.
            enableRemoteCommandHandling: false
        )
        player = APlay(configuration: configuration)

        (timeTicks, timeTicksContinuation) = AsyncStream.makeStream(of: TimeInterval.self)
        (itemEnded, itemEndedContinuation) = AsyncStream.makeStream(of: Void.self)
        (bufferingChanged, bufferingChangedContinuation) = AsyncStream.makeStream(of: Bool.self)
        (isPlayingChanged, isPlayingChangedContinuation) = AsyncStream.makeStream(of: Bool.self)

        player.eventPipeline.delegate(to: Self.noop) { [weak self] _, event in
            guard let self else { return }
            switch event {
            case let .playback(time):
                self.timeTicksContinuation.yield(TimeInterval(time))
            case .playEnded:
                self.itemEndedContinuation.yield()
            case let .buffering(progress):
                // A buffering progress strictly between 0 and 1 means data is
                // still arriving; 1 is fully buffered and 0 is "not started".
                self.bufferingChangedContinuation.yield(progress > 0 && progress < 1)
            case let .state(state):
                self.isPlayingChangedContinuation.yield(state.isPlaying)
            default:
                break
            }
        }
    }

    /// A stable object for `Delegated`'s weak target — the callbacks it guards
    /// never actually run after `self` is gone.
    private static let noop = NSObject()

    // MARK: - Reads

    /// Safe to read from any thread — a plain value off the player.
    func currentTime() -> TimeInterval {
        player.currentTime()
    }

    // MARK: - Commands

    func load(url: URL, autostart: Bool) {
        if autostart {
            player.play(url)
        } else {
            player.prepare(url)
        }
    }

    func play() {
        player.resume()
    }

    func pause() {
        player.pause()
    }

    func seek(to seconds: TimeInterval) {
        player.seek(to: seconds)
    }

    func setVolume(_ volume: Float) {
        // APlay exposes no runtime volume on its public surface yet; the mixer
        // is configured by `Configuration.isEnabledVolumeMixer`. Until it does,
        // volume rides at unity. (TODO: surface volume on APlay.)
    }

    func clear() {
        player.pause()
    }

    func updateMetadata(title: String, artist: String, album: String) {
        player.metadataUpdate(title: title, album: album, artist: artist)
    }
}
