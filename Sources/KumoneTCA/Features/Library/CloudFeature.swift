import ComposableArchitecture
import Dependencies
import Foundation
import KumoneCore

/// 音乐云盘: the uploaded tracks, plus how much of the quota is used.
@Reducer
public struct CloudFeature {
    @ObservableState
    public struct State: Equatable {
        public enum LoadState: Equatable {
            case idle, loading, loaded
            case error(String)
        }

        public var items: [CloudSongItem] = []
        public var sizeInfo: String?
        public var loadState: LoadState = .idle

        /// What 播放全部 actually hands to the player.
        public var tracks: [Track] { items.compactMap(\.simpleSong) }
    }

    public enum Action: Equatable {
        case onAppear
        case reload
        case itemsResponse(items: [CloudSongItem], sizeInfo: String?)
        case loadFailed(String)
        case playAll
        case delegate(Delegate)
    }

    public enum Delegate: Equatable {
        case play(tracks: [Track], source: PlaySource, context: PlayContext?)
    }

    @Dependency(\.cloudStorage) public var cloud

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                guard state.loadState == .idle else { return .none }
                return startLoad(state: &state)

            case .reload:
                return startLoad(state: &state)

            case let .itemsResponse(items, sizeInfo):
                state.items = items
                state.sizeInfo = sizeInfo
                state.loadState = .loaded
                return .none

            case let .loadFailed(message):
                state.loadState = .error(message)
                return .none

            case .playAll:
                return .send(.delegate(.play(
                    tracks: state.tracks, source: .cloud, context: .cloud)))

            case .delegate:
                return .none
            }
        }
    }

    private func startLoad(state: inout State) -> Effect<Action> {
        if state.items.isEmpty { state.loadState = .loading }
        return .run { [cloud] send in
            do {
                let response = try await cloud?.cloudSongs(limit: 100, offset: 0)
                await send(.itemsResponse(
                    items: response?.items ?? [],
                    sizeInfo: Self.sizeInfo(used: response?.usedBytes, total: response?.maxBytes)))
            } catch {
                await send(.loadFailed(error.localizedDescription))
            }
        }
    }

    /// "已使用 1.2 GB / 5 GB", only when the quota is known.
    public static func sizeInfo(used: Int64?, total: Int64?) -> String? {
        guard let used, let total, total > 0 else { return nil }
        let usedGB = String(format: "%.1f", Double(used) / 1_073_741_824)
        let totalGB = String(format: "%.0f", Double(total) / 1_073_741_824)
        return String(localized: "已使用 \(usedGB) GB / \(totalGB) GB")
    }
}
