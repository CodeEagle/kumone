import AVFoundation
import APlay
import Foundation
import KumoneCore

/// The process-wide live engine shared by app stores and frame-by-frame lyrics.
/// Keep platform playback implementation outside the reducer dependency module.
public enum PlaybackEngineAdapter {
    public static let client = {
        let engine = PlaybackEngine()
        return PlaybackEngineClient(
            load: { url, autostart, metadata in engine.load(url: url, autostart: autostart, metadata: metadata) },
            play: { engine.play() },
            pause: { engine.pause() },
            seek: { seconds in engine.seek(to: seconds) },
            setVolume: { volume in engine.setVolume(volume) },
            clear: { engine.clear() },
            updateMetadata: { title, artist, album, coverURL in engine.updateMetadata(title: title, artist: artist, album: album, coverURL: coverURL) },
            currentTime: { engine.currentTime() },
            timeTicks: { engine.timeTicks },
            itemEnded: { engine.itemEnded },
            bufferingChanged: { engine.bufferingChanged },
            isPlayingChanged: { engine.isPlayingChanged }
        )
    }()
}

/// One `APlay` instance held for the app's whole lifetime (by `PlaybackEngineAdapter.client`), so
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
    /// The engine's last reported playing state, so buffering events arriving
    /// mid-playback can be ignored (a network stream buffers forever).
    private var isPlaying = false

    fileprivate let timeTicks: AsyncStream<TimeInterval>
    private let timeTicksContinuation: AsyncStream<TimeInterval>.Continuation
    fileprivate let itemEnded: AsyncStream<Void>
    private let itemEndedContinuation: AsyncStream<Void>.Continuation
    fileprivate let bufferingChanged: AsyncStream<Double>
    private let bufferingChangedContinuation: AsyncStream<Double>.Continuation
    fileprivate let isPlayingChanged: AsyncStream<Bool>
    private let isPlayingChangedContinuation: AsyncStream<Bool>.Continuation

    init() {
        let configuration = APlay.Configuration(
            maxDiskCacheSize: UInt32(AudioCacheMaintenance.limitBytes),
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
        AudioCacheMaintenance.trimIfNeeded()
        // The reducer owns the queue: it loads one URL at a time and decides what
        // follows. APlay's own list advance must stay out of it — with the
        // default `.order` pattern a single-item list wraps back to the same
        // URL, so an end-of-item the engine detects on its own (which a seek
        // can spuriously produce while its ranged re-download stalls) reloads
        // the current track from zero and reads as an unwanted skip.
        // Stopping at the list end leaves every advance to the reducer.
        player.loopPattern = .stopWhenAllPlayed(.order)

        // The engine's PCM is the only audio source the spectrum ever sees, so
        // the tap lives for the engine's lifetime and points straight at the
        // shared spectrum store. It fires on the render thread; the store is
        // lock-free and preallocated, exactly what that thread requires.
        player.pcmTap = { (bufferList, frameCount, format) in
            AudioSpectrum.shared.ingest(bufferList, frameCount: frameCount, format: format)
        }

        (timeTicks, timeTicksContinuation) = AsyncStream.makeStream(of: TimeInterval.self)
        (itemEnded, itemEndedContinuation) = AsyncStream.makeStream(of: Void.self)
        (bufferingChanged, bufferingChangedContinuation) = AsyncStream.makeStream(of: Double.self)
        (isPlayingChanged, isPlayingChangedContinuation) = AsyncStream.makeStream(of: Bool.self)

        player.eventPipeline.delegate(to: Self.noop) { [weak self] _, event in
            guard let self else { return }
            switch event {
            case let .playback(time):
                self.timeTicksContinuation.yield(TimeInterval(time))
            case .playEnded:
                self.itemEndedContinuation.yield()
            case let .buffering(progress):
                // A network stream buffers continuously: APlay reports a
                // progress strictly between 0 and 1 for the whole track. The
                // raw progress is forwarded; the reducer decides whether that
                // counts as "loading" (it does only before playback starts).
                self.bufferingChangedContinuation.yield(Double(progress))
            case .streamerEndEncountered:
                // The streamer read to EOF: every byte of this track is
                // loaded. The last `hasBytesAvailable` before it often
                // reported 0.9-something, and without this fix the preload
                // bar sits short of full on a track that is, in fact,
                // completely buffered.
                KumoneLogger.player.info("BUFFER end-of-stream -> 1.0")
                self.bufferingChangedContinuation.yield(1.0)
            case let .state(state):
                self.isPlaying = state.isPlaying
                self.isPlayingChangedContinuation.yield(state.isPlaying)
                // Playing is the reliable "this track is tapped" signal: by now
                // the source is resolved and the render graph is pulling samples
                // through the tap.
                if state.isPlaying {
                    AudioSpectrum.shared.markTapped()
                }
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

    func load(url: URL, autostart: Bool, metadata: APlay.NowPlayingMetadata? = nil) {
        AudioCacheMaintenance.trimIfNeeded()
        // A track change starts in "preparing": the URL is still being resolved
        // and no samples have arrived, so the shaders hold still rather than
        // flashing the last track's frozen levels.
        AudioSpectrum.shared.beginPreparing()
        if autostart {
            player.play(url, metadata: metadata)
        } else {
            player.prepare(url, metadata: metadata)
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
        AudioSpectrum.shared.markIdle()
    }

    func updateMetadata(title: String, artist: String, album: String, coverURL: URL?) {
        guard let coverURL else {
            player.metadataUpdate(title: title, album: album, artist: artist, cover: nil)
            return
        }
        // The cover is fetched here rather than in the reducer: Now Playing
        // metadata is not time-critical, and the reducer only knows the URL.
        Task {
            let data = try? await URLSession.shared.data(from: coverURL).0
            player.metadataUpdate(
                title: title, album: album, artist: artist, cover: data.flatMap(PlatformImage.init(data:)))
        }
    }
}
