#if os(macOS)
import Combine
import Foundation
import Sparkle

public enum UpdaterAdapter {
    public static let client = {
        let bridge = SparkleUpdaterBridge()
        return UpdaterClient.live(bridge: bridge)
    }()
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
        AsyncStream { continuation in
            // KVO publishers do not replay the current value, so prepend it:
            // the menu item should be disabled until Sparkle says otherwise,
            // not until the first change.
            let publisher = controller.updater
                .publisher(for: \.canCheckForUpdates)
                .prepend(controller.updater.canCheckForUpdates)
                .removeDuplicates()
            Task {
                for await value in publisher.values {
                    continuation.yield(value)
                }
                continuation.finish()
            }
        }
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
#endif
