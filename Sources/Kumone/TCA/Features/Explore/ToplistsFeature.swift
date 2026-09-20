import ComposableArchitecture
import Dependencies
import Foundation

/// The standalone 排行榜 page: every toplist, in one request.
@Reducer
struct ToplistsFeature {
    @ObservableState
    struct State: Equatable {
        enum LoadState: Equatable {
            case idle, loading, loaded
            case error(String)
        }

        var toplists: [ToplistItem] = []
        var loadState: LoadState = .idle
    }

    enum Action: Equatable {
        case onAppear
        case reload
        case response([ToplistItem])
        case loadFailed(String)
        case delegate(Delegate)
    }

    enum Delegate: Equatable {
        case play(tracks: [Track], source: PlaySource, context: PlayContext?)
    }

    @Dependency(\.netease) var netease

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                guard state.loadState == .idle else { return .none }
                state.loadState = .loading
                return loadEffect()

            case .reload:
                state.loadState = .loading
                return loadEffect()

            case let .response(toplists):
                state.toplists = toplists
                state.loadState = .loaded
                return .none

            case let .loadFailed(message):
                state.loadState = .error(message)
                return .none

            case .delegate:
                return .none
            }
        }
    }

    private func loadEffect() -> Effect<Action> {
        .run { [netease] send in
            do {
                await send(.response(try await netease.toplists()))
            } catch {
                await send(.loadFailed(error.localizedDescription))
            }
        }
    }
}
