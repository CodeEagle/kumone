import ComposableArchitecture
import Dependencies
import Foundation
import KumoneCore

/// The standalone 排行榜 page: every toplist, in one request.
@Reducer
public struct ToplistsFeature {
    @ObservableState
    public struct State: Equatable {
        public enum LoadState: Equatable {
            case idle, loading, loaded
            case error(String)
        }

        public var toplists: [ToplistItem] = []
        public var loadState: LoadState = .idle
    }

    public enum Action: Equatable {
        case onAppear
        case reload
        case response([ToplistItem])
        case loadFailed(String)
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

    // Bridge into the existing state model, which only exposes a decoder initializer.
    // Chart has no track previews; ToplistItem decodes the omitted tracks as [].
    private struct ChartPayload: Encodable {
        let id: Int
        let name: String
        let coverImgUrl: String?
        let updateFrequency: String?
        let playCount: Int
    }

    private func loadEffect() -> Effect<Action> {
        .run { [provider] send in
            do {
                let charts = try await provider.toplists()
                let items = try charts.map { chart in
                    guard let id = Int(chart.id.sourceID) else {
                        throw DecodingError.dataCorrupted(.init(
                            codingPath: [], debugDescription: "Chart ID is not an integer: \(chart.id.sourceID)"))
                    }
                    let payload = ChartPayload(
                        id: id, name: chart.name, coverImgUrl: chart.coverURL?.absoluteString,
                        updateFrequency: chart.updateFrequency, playCount: chart.playCount)
                    return try JSONDecoder().decode(
                        ToplistItem.self, from: JSONEncoder().encode(payload))
                }
                await send(.response(items))
            } catch {
                await send(.loadFailed(error.localizedDescription))
            }
        }
    }
}
