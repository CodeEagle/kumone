import ComposableArchitecture
import Foundation

/// Sparkle's standard updater, behind a dependency.
///
/// Reducers never touch Sparkle directly: the app menu and the Settings view
/// send `checkForUpdates`, the persisted auto-check preference is pushed here,
/// and `canCheckForUpdates` arrives as an action so the UI's disabled state is
/// store-driven. On iOS there is no Sparkle, so the client is inert.
@DependencyClient
public struct UpdaterClient {
    /// Starts the updater and streams the current and every later
    /// `canCheckForUpdates` value. Idempotent: subscribing more than once just
    /// attaches another listener to the same publisher.
    public var start: @Sendable () -> AsyncStream<Bool> = { .never }
    /// Schedules or unschedules Sparkle's automatic update checks.
    public var setAutomaticChecks: @Sendable (Bool) -> Void = { _ in }
    /// Shows Sparkle's standard update window (a no-op before the updater has
    /// finished loading, which is what `canCheckForUpdates` reports).
    public var checkForUpdates: @Sendable () -> Void = { }
}

/// Platform-independent bridge supplied by the app's updater adapter.
public protocol UpdaterBridge: Sendable {
    func start() -> AsyncStream<Bool>
    func setAutomaticChecks(_ enabled: Bool)
    func checkForUpdates()
}

extension UpdaterClient {
    public static func live(bridge: any UpdaterBridge) -> UpdaterClient {
        UpdaterClient(
            start: { bridge.start() },
            setAutomaticChecks: { enabled in bridge.setAutomaticChecks(enabled) },
            checkForUpdates: { bridge.checkForUpdates() })
    }
}

extension UpdaterClient: DependencyKey {
    public static let liveValue = testValue
}

extension UpdaterClient: TestDependencyKey {
    /// Sparkle must never start under test: `SPUStandardUpdaterController`'s
    /// first `startUpdater` block blocks the main thread on a helper XPC that
    /// never answers in a headless test run, so a test that merely *reads*
    /// `@Dependency(\.updater)` would deadlock the suite.
    public static let testValue = UpdaterClient(
        start: { .never },
        setAutomaticChecks: { _ in },
        checkForUpdates: { })
}

extension DependencyValues {
    public var updater: UpdaterClient {
        get { self[UpdaterClient.self] }
        set { self[UpdaterClient.self] = newValue }
    }
}
