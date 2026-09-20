import ComposableArchitecture
import Dependencies
import Foundation

/// Ephemeral transile messages ("已添加到下一首播放", network errors, …).
///
/// One toast at a time, auto-dismissed after 3s; presenting again replaces the
/// current one and resets the timer.
@Reducer
struct ToastsFeature {
    @ObservableState
    struct State: Equatable {
        var current: Toast?
    }

    enum Action: Equatable {
        /// Shows `message`, replacing any toast already on screen.
        case presented(String)
        /// Dismiss immediately (swipe / onAppear of a new root, etc.).
        case dismiss
        case autoDismissTimerCompleted(UUID)
    }

    @Dependency(\.continuousClock) var clock
    @Dependency(\.uuid) var uuid

    var body: some ReducerOf<Self> {
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

struct Toast: Identifiable, Equatable {
    let id: UUID
    let message: String

    init(id: UUID = UUID(), message: String) {
        self.id = id
        self.message = message
    }
}
