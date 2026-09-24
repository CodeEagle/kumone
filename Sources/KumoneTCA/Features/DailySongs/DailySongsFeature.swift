import ComposableArchitecture
import Dependencies
import Foundation
import KumoneCore

/// The 每日推荐 page: one list per day, login-gated, where a rejected
/// recommendation is swapped in place rather than removed.
@Reducer
public struct DailySongsFeature {
    @ObservableState
    public struct State: Equatable {
        public enum LoadState: Equatable {
            case idle, loading, loaded
            case error(String)
        }

        public var tracks: [Track] = []
        public var loadState: LoadState = .idle

        /// Pushed by AppFeature; the endpoint is account-scoped.
        public var isLoggedIn = false
    }

    public enum Action: Equatable {
        case onAppear
        case reload
        case songsResponse([Track])
        case loadFailed(String)
        case recommendationReduced(rejected: Track, replacement: Track)
        case playAll
        case delegate(Delegate)
    }

    public enum Delegate: Equatable {
        case play(tracks: [Track], source: PlaySource, context: PlayContext?)
    }

    @Dependency(\.musicProvider) public var provider

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                guard state.loadState == .idle else { return .none }
                return startLoad(state: &state)

            case .reload:
                return startLoad(state: &state)

            case let .songsResponse(tracks):
                state.tracks = tracks
                state.loadState = .loaded
                return .none

            case let .loadFailed(message):
                state.loadState = .error(message)
                return .none

            case let .recommendationReduced(rejected, replacement):
                _ = state.tracks.replaceRecommendation(rejected, with: replacement)
                return .none

            case .playAll:
                return .send(.delegate(.play(
                    tracks: state.tracks, source: .daily, context: .daily)))

            case .delegate:
                return .none
            }
        }
    }

    private func startLoad(state: inout State) -> Effect<Action> {
        guard state.isLoggedIn else {
            state.loadState = .error(String(localized: "登录后才能查看每日推荐"))
            return .none
        }
        state.loadState = .loading
        return .run { [provider] send in
            do {
                let tracks = try await provider.dailyRecommendSongs()
                await send(.songsResponse(tracks))
            } catch {
                await send(.loadFailed(error.localizedDescription))
            }
        }
    }
}
