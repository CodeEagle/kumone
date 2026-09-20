import ComposableArchitecture
import Foundation

/// Sparkle's standard updater, behind a dependency.
///
/// Reducers never touch Sparkle directly: the app menu and the Settings view
/// send `checkForUpdates`, the persisted auto-check preference is pushed here,
/// and `canCheckForUpdates` arrives as an action so the UI's disabled state is
/// store-driven. On iOS there is no Sparkle, so the client is inert.
@DependencyClient
struct UpdaterClient {
    /// Starts the updater and streams the current and every later
    /// `canCheckForUpdates` value. Idempotent: subscribing more than once just
    /// attaches another listener to the same publisher.
    var start: @Sendable () -> AsyncStream<Bool> = { .never }
    /// Schedules or unschedules Sparkle's automatic update checks.
    var setAutomaticChecks: @Sendable (Bool) -> Void = { _ in }
    /// Shows Sparkle's standard update window (a no-op before the updater has
    /// finished loading, which is what `canCheckForUpdates` reports).
    var checkForUpdates: @Sendable () -> Void = { }
}

extension UpdaterClient: DependencyKey {
    static let liveValue = {
        #if os(macOS)
        let bridge = UpdaterBridge()
        #endif
        return UpdaterClient(
            start: {
                #if os(macOS)
                bridge.start()
                #else
                .never
                #endif
            },
            setAutomaticChecks: { enabled in
                #if os(macOS)
                bridge.setAutomaticChecks(enabled)
                #endif
            },
            checkForUpdates: {
                #if os(macOS)
                bridge.checkForUpdates()
                #endif
            })
    }()
}

extension DependencyValues {
    var updater: UpdaterClient {
        get { self[UpdaterClient.self] }
        set { self[UpdaterClient.self] = newValue }
    }
}

#if os(macOS)
import Combine
import Sparkle

/// One `SPUStandardUpdaterController` held for the app's whole lifetime (by
/// `liveValue`), so the dependency stays a plain value type.
fileprivate final class UpdaterBridge: @unchecked Sendable {
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
