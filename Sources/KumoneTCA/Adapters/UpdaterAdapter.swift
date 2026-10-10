#if os(macOS)
import Combine
import Foundation
import Sparkle

public enum UpdaterAdapter {
    public static let client = {
        let bridge = SparkleUpdaterBridge()
        return UpdaterClient.live(bridge: bridge)
    }()

    static func values<P: Publisher>(from publisher: P) -> AsyncStream<Bool>
        where P.Output == Bool, P.Failure == Never {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                for await value in publisher.values {
                    guard !Task.isCancelled else { break }
                    continuation.yield(value)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// One `SPUStandardUpdaterController` held for the app's whole lifetime (by
/// `UpdaterAdapter.client`), so the dependency stays a plain value type.
fileprivate final class SparkleUpdaterBridge: UpdaterBridge, @unchecked Sendable {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func start() -> AsyncStream<Bool> {
        // KVO publishers do not replay the current value, so prepend it.
        let publisher = controller.updater
            .publisher(for: \.canCheckForUpdates)
            .prepend(controller.updater.canCheckForUpdates)
            .removeDuplicates()
        return UpdaterAdapter.values(from: publisher)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
#endif
