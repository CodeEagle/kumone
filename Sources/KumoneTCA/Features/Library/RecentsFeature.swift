import ComposableArchitecture
import Dependencies
import Foundation
import KumoneCore

/// 最近播放: all-time or last-week play records, switchable in place.
@Reducer
public struct RecentsFeature {
    @ObservableState
    public struct State: Equatable {
        public enum LoadState: Equatable {
            case idle, loading, loaded
            case error(String)
        }

        public var records: [PlayRecordItem] = []
        public var week = false
        public var loadState: LoadState = .idle

        /// Pushed by AppFeature; records are per-account.
        public var userID: Int?
    }

    public enum Action: Equatable {
        case onAppear
        case reload
        case toggleWeek
        case recordsResponse([PlayRecordItem])
        case loadFailed(String)
        case playAll
        case playRecord(PlayRecordItem)
        case delegate(Delegate)
    }

    public enum Delegate: Equatable {
        case play(tracks: [Track], startAt: Track?, context: PlayContext?)
    }

    @Dependency(\.playHistory) public var history

    public var body: some ReducerOf<Self> {
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

    // Track's normal encoder omits playback flags; retain them in the legacy bridge.
    private struct RecordPayload: Encodable {
        let record: PlayRecord

        private enum Keys: String, CodingKey {
            case playCount, score, song, noCopyrightRcmd, pc, privilege
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(record.playCount, forKey: .playCount)
            try container.encode(record.score, forKey: .score)
            let songEncoder = container.superEncoder(forKey: .song)
            try record.song.encode(to: songEncoder)
            var song = songEncoder.container(keyedBy: Keys.self)
            if record.song.noCopyright { try song.encode(true, forKey: .noCopyrightRcmd) }
            if record.song.isCloud { try song.encode(true, forKey: .pc) }
            try song.encodeIfPresent(record.song.embeddedPrivilege, forKey: .privilege)
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
        return .run { [history] send in
            do {
                let records = try await history?.playRecords(uid: MusicID(userID), week: week) ?? []
                // Preserve the existing state model, which only exposes a decoder initializer.
                let items = try JSONDecoder().decode(
                    [PlayRecordItem].self, from: JSONEncoder().encode(records.map { RecordPayload(record: $0) }))
                await send(.recordsResponse(items))
            } catch {
                await send(.loadFailed(error.localizedDescription))
            }
        }
    }
}
