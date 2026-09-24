import ComposableArchitecture
import Dependencies

/// App updates (Sparkle), as a feature rather than a singleton.
///
/// Replaces `UpdaterManager`: the Settings view and the app menu send actions
/// here, and `canCheckForUpdates` is ordinary state, so the "检查更新…" item's
/// disabled state is derived instead of observed.
@Reducer
public struct UpdaterFeature {
    @ObservableState
    public struct State: Equatable {
        /// False until Sparkle has finished loading its update manifest.
        public var canCheckForUpdates = false
        /// Guards `start` so a re-appearing view does not re-subscribe.
        public var isStarted = false
    }

    public enum Action: Equatable {
        case onAppear
        case canCheckForUpdatesChanged(Bool)
        /// Mirrors `SettingsFeature.setAutoCheckUpdates` (#42).
        case setAutomaticChecks(Bool)
        case checkForUpdates
    }

    @Dependency(\.updater) public var updater

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                guard !state.isStarted else { return .none }
                state.isStarted = true
                return .run { send in
                    for await value in updater.start() {
                        await send(.canCheckForUpdatesChanged(value))
                    }
                }

            case let .canCheckForUpdatesChanged(value):
                state.canCheckForUpdates = value
                return .none

            case let .setAutomaticChecks(enabled):
                updater.setAutomaticChecks(enabled)
                return .none

            case .checkForUpdates:
                updater.checkForUpdates()
                return .none
            }
        }
    }
}
