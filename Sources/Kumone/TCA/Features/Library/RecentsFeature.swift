import ComposableArchitecture
import Dependencies
import Foundation

/// 最近播放: all-time or last-week play records, switchable in place.
@Reducer
struct RecentsFeature {
    @ObservableState
    struct State: Equatable {
        enum LoadState: Equatable {
            case idle, loading, loaded
            case error(String)
        }

        var records: [PlayRecordItem] = []
        var week = false
        var loadState: LoadState = .idle

        /// Pushed by AppFeature; records are per-account.
        var userID: Int?
    }

    enum Action: Equatable {
        case onAppear
        case reload
        case toggleWeek
        case recordsResponse([PlayRecordItem])
        case loadFailed(String)
        case playAll
        case playRecord(PlayRecordItem)
        case delegate(Delegate)
    }

    enum Delegate: Equatable {
        case play(tracks: [Track], startAt: Track?, context: PlayContext?)
    }

    @Dependency(\.netease) var netease

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                guard state.loadState == .idle else { return .none }
                return startLoad(state: &state)

            case .reload:
                return startLoad(state: &state)

            case .toggleWeek:
                state.week.toggle()
                return startLoad(state: &state)

            case let .recordsResponse(records):
                state.records = records
                state.loadState = .loaded
                return .none

            case let .loadFailed(message):
                state.loadState = .error(message)
                return .none

            case .playAll:
                let songs = state.records.map(\.song)
                return .send(.delegate(.play(tracks: songs, startAt: nil, context: .recents)))

            case let .playRecord(record):
                let songs = state.records.map(\.song)
                return .send(.delegate(.play(tracks: songs, startAt: record.song, context: .recents)))

            case .delegate:
                return .none
            }
        }
    }

    private func startLoad(state: inout State) -> Effect<Action> {
        guard let userID = state.userID else {
            state.loadState = .error(String(localized: "登录后才能查看播放记录"))
            return .none
        }
        // Keep the old list visible while the other range loads.
        if state.records.isEmpty { state.loadState = .loading }
        let week = state.week
        return .run { [netease] send in
            do {
                let records = try await netease.playRecords(uid: userID, week: week)
                await send(.recordsResponse(records))
            } catch {
                await send(.loadFailed(error.localizedDescription))
            }
        }
    }
}
