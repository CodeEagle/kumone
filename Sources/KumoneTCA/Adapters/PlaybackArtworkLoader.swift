import Foundation
import KumoneCore
import APlay

/// Owns exactly one metadata artwork request. Playback commands arrive from
/// reducer effects on different executors; the lock serializes replacement and
/// publication. No lock is held across an await. The task captures us weakly.
final class PlaybackArtworkLoader: @unchecked Sendable {
    /// The engine receives text synchronously; all artwork goes through our
    /// bounded loader instead of APlay's independent original-image downloader.
    static func textOnlyMetadata(_ metadata: APlay.NowPlayingMetadata?) -> APlay.NowPlayingMetadata? {
        guard var metadata else { return nil }
        metadata.artworkURL = nil
        metadata.artwork = nil
        return metadata
    }
    typealias Loader = (URL) async -> PlatformImage?
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private let loader: Loader

    init(loader: @escaping Loader = { await ImageCache.shared.image(for: $0, rendition: .systemArtwork) }) {
        self.loader = loader
    }

    deinit { task?.cancel() }

    func cancel() {
        let old = lock.withLock {
            generation &+= 1
            let old = task
            task = nil
            return old
        }
        old?.cancel()
    }

    func load(_ url: URL?, publish: @escaping (PlatformImage?) -> Void) {
        let old = lock.withLock { () -> Task<Void, Never>? in
            generation &+= 1
            let token = generation
            let old = task
            task = nil
            guard let url else {
                publish(nil)
                return old
            }
            let loader = loader
            task = Task { [weak self] in
                guard !Task.isCancelled else { return }
                let image = await loader(url)
                guard !Task.isCancelled else { return }
                self?.finish(token, image: image, publish: publish)
            }
            return old
        }
        old?.cancel()
    }

    private func finish(_ token: UInt64, image: PlatformImage?, publish: (PlatformImage?) -> Void) {
        lock.withLock {
            guard generation == token else { return }
            task = nil
            publish(image)
        }
    }

    func waitForCurrentRequest() async {
        let current = lock.withLock { task }
        await current?.value
    }
}
