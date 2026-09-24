import ComposableArchitecture
import Dependencies
import Foundation

/// Ephemeral transile messages ("已添加到下一首播放", network errors, …).
///
/// One toast at a time, auto-dismissed after 3s; presenting again replaces the
/// current one and resets the timer.
@Reducer
public struct ToastsFeature {
    @ObservableState
    public struct State: Equatable {
        public var current: Toast?
    }

    public enum Action: Equatable {
        /// Shows `message`, replacing any toast already on screen.
        case presented(String)
        /// Dismiss immediately (swipe / onAppear of a new root, etc.).
        case dismiss
        case autoDismissTimerCompleted(UUID)
    }

    @Dependency(\.continuousClock) public var clock
    @Dependency(\.uuid) public var uuid

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .presented(message):
                state.current = Toast(id: uuid(), message: message)
                guard let id = state.current?.id else { return .none }
                return .run { send in
                    try? await clock.sleep(for: .seconds(3))
                    await send(.autoDismissTimerCompleted(id))
                }

            case .dismiss:
                state.current = nil
                return .none

            case let .autoDismissTimerCompleted(id):
                if state.current?.id == id {
                    state.current = nil
                }
                return .none
            }
        }
    }
}

// MARK: - Model

public struct Toast: Identifiable, Equatable {
    public let id: UUID
    public let message: String

    public init(id: UUID = UUID(), message: String) {
        self.id = id
        self.message = message
    }
}
