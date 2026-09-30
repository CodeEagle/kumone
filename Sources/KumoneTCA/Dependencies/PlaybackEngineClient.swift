import APlay
import ComposableArchitecture
import Foundation

/// The playback engine, as a dependency.
///
/// The app injects its platform playback adapter. Commands are
/// fire-and-forget; playback events (periodic time, item end, buffering, state)
/// arrive as actions so the reducer stays the single source of truth. Karaoke
/// word highlighting reads `currentTime` directly — it needs per-frame precision,
/// which does not belong in reducer state.
@DependencyClient
public struct PlaybackEngineClient {
    // MARK: - Commands

    /// Replaces the current item and begins playing if `autostart`. When
    /// `autostart` is false the stream is buffered but the output unit is not
    /// started, so a later `play` of the same URL picks up immediately.
    ///
    /// `metadata` rides the load so the system Now Playing card describes the
    /// new track the moment the engine clears the old one, instead of flashing
    /// the previous track (or staying blank) until the host pushes its own
    /// copy (APlay PR #20).
    public var load: @Sendable (_ url: URL, _ autostart: Bool, _ metadata: APlay.NowPlayingMetadata?) -> Void = { _, _, _ in }
    public var play: @Sendable () -> Void = {}
    public var pause: @Sendable () -> Void = {}
    public var seek: @Sendable (_ seconds: TimeInterval) -> Void = { _ in }
    public var setVolume: @Sendable (_ volume: Float) -> Void = { _ in }
    /// Stops playback (used when playback stops for good).
    public var clear: @Sendable () -> Void = {}
    /// Pushes the current track's title/artist/album/cover onto the system's
    /// Now Playing surface (lock screen, Control Center, AirPlay 2). The cover
    /// is fetched from `coverURL` by the live implementation.
    public var updateMetadata: @Sendable (_ title: String, _ artist: String, _ album: String, _ coverURL: URL?) -> Void = { _, _, _, _ in }

    // MARK: - Reads

    /// Live playback position straight from the player, for smooth per-frame
    /// karaoke highlighting. Do NOT put this in reducer state.
    public var currentTime: @Sendable () -> TimeInterval = { 0 }

    // MARK: - Events

    /// Coarse position ticks (~1/s) for the scrubber and lyric line cursor.
    public var timeTicks: @Sendable () -> AsyncStream<TimeInterval> = { .never }
    /// Fired when the current item plays to its end.
    public var itemEnded: @Sendable () -> AsyncStream<Void> = { .never }
    /// Waiting-to-play → buffering progress (0...1), reported continuously for
    /// network streams. The transport's loading state is derived from it.
    public var bufferingChanged: @Sendable () -> AsyncStream<Double> = { .never }
    /// Playback state as the engine sees it — including the pauses it applies on
    /// its own (an iOS interruption, an unplugged route), which the reducer
    /// would otherwise never hear about.
    public var isPlayingChanged: @Sendable () -> AsyncStream<Bool> = { .never }
}

// MARK: - Dependency defaults

extension PlaybackEngineClient: DependencyKey {
    /// App composition roots inject the live platform adapter.
    /// The default stays inert so importing TCA never starts an audio engine.
    public static let liveValue = testValue

    // `@DependencyClient` (1.17) does not synthesize a `testValue`, and the
    // `@DependencyEndpoint` defaults trap with "Unimplemented" when called. The
    // engine's streams simply never deliver in tests; tests that assert on a
    // command override the endpoint (or the whole client) per-store.
    public static let testValue = PlaybackEngineClient(
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
        isPlayingChanged: { .never }
    )
}

extension DependencyValues {
    public var playback: PlaybackEngineClient {
        get { self[PlaybackEngineClient.self] }
        set { self[PlaybackEngineClient.self] = newValue }
    }
}
