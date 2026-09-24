import ComposableArchitecture
import Foundation
import KumoneCore
import MediaPlayer

/// System Now Playing integration (media keys, Control Center, lock screen,
/// CarPlay) as a dependency.
///
/// APlay's own remote-command controller is disabled in the engine
/// configuration — it would drive APlay's internal playlist instead of the
/// reducer's queue — so this client owns command dispatch: system events
/// arrive as ``NowPlayingCommand``s for the reducer to turn into actions, and
/// the reducer pushes the like / shuffle / repeat state back so the system
/// surfaces show the right glyphs. Track metadata is written by the engine
/// itself (`PlaybackEngineClient.updateMetadata`); artwork is still deferred.
@DependencyClient
public struct NowPlayingClient {
    /// Starts delivering remote commands for the lifetime of the subscription.
    public var attach: @Sendable () -> AsyncStream<NowPlayingCommand> = { .never }

    // MARK: - State the system surfaces render

    /// Reflects the current track's hearted state on the like command.
    public var setLiked: @Sendable (Bool) -> Void = { _ in }
    public var setShuffle: @Sendable (Bool) -> Void = { _ in }
    public var setRepeat: @Sendable (RepeatMode) -> Void = { _ in }
}

/// A system media event, mapped onto store actions by `AppFeature`.
public enum NowPlayingCommand: Equatable {
    case play
    case pause
    case togglePlayPause
    case next
    case previous
    case seek(TimeInterval)
    /// Control Center long-press / CarPlay heart button. The current track is
    /// read from store state, not from the client.
    case like
    case shuffle(Bool)
    case repeatMode(RepeatMode)
}

extension NowPlayingClient: DependencyKey {
    public static let liveValue = {
        let bridge = NowPlayingBridge()
        return NowPlayingClient(
            attach: { bridge.commands },
            setLiked: { bridge.setLiked($0) },
            setShuffle: { bridge.setShuffle($0) },
            setRepeat: { bridge.setRepeat($0) }
        )
    }()

    // `@DependencyClient` (1.17) does not synthesize a `testValue`, and the
    // `@DependencyEndpoint` defaults trap with "Unimplemented" when called —
    // which `AppFeature.mirrorNowPlaying` does on every player/account action.
    // Tests that care about a push still override the endpoint per-store.
    public static let testValue = NowPlayingClient(
        attach: { .never },
        setLiked: { _ in },
        setShuffle: { _ in },
        setRepeat: { _ in }
    )
}

extension DependencyValues {
    public var nowPlaying: NowPlayingClient {
        get { self[NowPlayingClient.self] }
        set { self[NowPlayingClient.self] = newValue }
    }
}

/// Owns one set of `MPRemoteCommandCenter` targets for the app's lifetime (held
/// by `liveValue`). Commands are delivered through a single stream; state
/// pushes are de-duplicated so a reducer mirroring on every action does not
/// hammer the system.
private final class NowPlayingBridge: @unchecked Sendable {
    let commands: AsyncStream<NowPlayingCommand>
    private let continuation: AsyncStream<NowPlayingCommand>.Continuation

    private var lastShuffle: Bool?
    private var lastRepeat: RepeatMode?
    private var lastLiked: Bool?

    init() {
        (commands, continuation) = AsyncStream.makeStream(of: NowPlayingCommand.self)
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.send(.play)
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.send(.pause)
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.send(.togglePlayPause)
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.send(.next)
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.send(.previous)
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.send(.seek(event.positionTime))
            return .success
        }

        // Like feedback (Control Center long-press / CarPlay).
        center.likeCommand.isEnabled = true
        center.likeCommand.localizedTitle = String(localized: "喜欢")
        center.likeCommand.localizedShortTitle = String(localized: "喜欢")
        center.likeCommand.addTarget { [weak self] _ in
            self?.send(.like)
            return .success
        }

        // NB: skipForward/skipBackward (±15s) are deliberately NOT registered —
        // enabling them makes iOS show a podcast-style "back 15s / forward 15s"
        // layout on the lock screen and Dynamic Island, hiding the track-skip
        // buttons (#83, #87).

        // Shuffle / repeat back the CarPlay Now Playing buttons.
        center.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            self?.send(.shuffle(event.shuffleType != .off))
            return .success
        }
        center.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            switch event.repeatType {
            case .off: self?.send(.repeatMode(.off))
            case .one: self?.send(.repeatMode(.one))
            case .all: self?.send(.repeatMode(.all))
            default: break
            }
            return .success
        }
    }

    private func send(_ command: NowPlayingCommand) {
        continuation.yield(command)
    }

    func setLiked(_ liked: Bool) {
        guard lastLiked != liked else { return }
        lastLiked = liked
        MPRemoteCommandCenter.shared().likeCommand.isActive = liked
    }

    func setShuffle(_ enabled: Bool) {
        guard lastShuffle != enabled else { return }
        lastShuffle = enabled
        MPRemoteCommandCenter.shared().changeShuffleModeCommand.currentShuffleType = enabled ? .items : .off
    }

    func setRepeat(_ mode: RepeatMode) {
        guard lastRepeat != mode else { return }
        lastRepeat = mode
        MPRemoteCommandCenter.shared().changeRepeatModeCommand.currentRepeatType = switch mode {
        case .off: .off
        case .one: .one
        case .all: .all
        }
    }
}
