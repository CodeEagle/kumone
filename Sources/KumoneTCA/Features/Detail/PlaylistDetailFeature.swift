import ComposableArchitecture
import Dependencies
import Foundation
import KumoneCore

/// A playlist's tracks: the detail response carries the first batch inline, and
/// the rest arrive in 500-track chunks. The page also owns its subscription
/// state, the in-list search filter, and the recommendation reductions that
/// survive a reload.
@Reducer
public struct PlaylistDetailFeature {
    @ObservableState
    public struct State: Equatable {
        public enum LoadState: Equatable {
            case idle, loading, loaded
            case error(String)
        }

        public let playlistID: Int
        public var detail: PlaylistDetail?
        public var tracks: [Track] = []
        public var privileges: [Int: TrackPrivilege] = [:]
        public var loadState: LoadState = .idle
        public var isLoadingMore = false
        public var filter = ""
        /// Recommendations the user rejected, kept out of subsequent loads.
        public var reducedRecommendationIDs: Set<Int> = []

        // Pushed by AppFeature; decide which tracks are playable here.
        public var enableUnblock = false
        public var isLoggedIn = false
        public var vipType = 0

        public init(playlistID: Int) {
            self.playlistID = playlistID
        }

        /// The in-list search.
        public var filteredTracks: [Track] {
            let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
            guard !query.isEmpty else { return tracks }
            return tracks.filter {
                $0.name.lowercased().contains(query)
                    || $0.artistNames.lowercased().contains(query)
                    || $0.album.name.lowercased().contains(query)
            }
        }

        /// What 播放全部 actually hands to the player.
        public var playableTracks: [Track] {
            enableUnblock
                ? tracks
                : tracks.filter {
                    $0.playability(
                        privilege: privileges[$0.id],
                        isLoggedIn: isLoggedIn,
                        vipType: vipType
                    ) == .playable
                }
        }
    }

    public enum Action: Equatable {
        /// Loads once; a reload keeps the old content visible while refetching.
        case onAppear
        /// The error view's retry, or pull to refresh.
        case reload
        case setFilter(String)
        case detailResponse(playlist: PlaylistDetail, privileges: [TrackPrivilege]?)
        case loadFailed(String)
        case chunkLoaded(songs: [Track], privileges: [TrackPrivilege])
        case isLoadingMoreChanged(Bool)
        case chunksFinished
        case trackRemoved(Track)
        case recommendationReduced(rejected: Track, replacement: Track)
        case toggleSubscribe
        case subscribeReverted(to: Bool)
        case startHeartbeat
        case delegate(Delegate)
    }

    /// Effects the parent owns: handing the queue to the player, showing a
    /// toast, and refreshing the library after a subscription change.
    public enum Delegate: Equatable {
        case play(tracks: [Track], source: PlaySource, startAt: Track?, context: PlayContext?)
        case toast(String)
        case subscriptionChanged
    }

    @Dependency(\.intelligence) public var intelligence
    @Dependency(\.musicProvider) public var provider

    /// songDetails takes 500 IDs at a time.
    public static let chunkSize = 500

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                guard state.loadState == .idle else { return .none }
                return startLoad(state: &state)

            case .reload:
                return startLoad(state: &state)

            case let .setFilter(filter):
                state.filter = filter
                return .none

            case let .detailResponse(playlist, privileges):
                state.detail = playlist
                state.tracks = playlist.tracks.filter {
                    !state.reducedRecommendationIDs.contains($0.id)
                }
                state.merge(privileges: privileges)
                state.loadState = .loaded
                return loadRemainingEffect(state: state)

            case let .loadFailed(message):
                if state.tracks.isEmpty {
                    state.loadState = .error(message)
                }
                return .none

            case let .chunkLoaded(songs, privileges):
                state.tracks.append(
                    contentsOf: songs.filter { !state.reducedRecommendationIDs.contains($0.id) })
                state.merge(privileges: privileges)
                return .none

            case let .isLoadingMoreChanged(isLoadingMore):
                state.isLoadingMore = isLoadingMore
                return .none

            case .chunksFinished:
                state.isLoadingMore = false
                return .none

            case let .trackRemoved(track):
                state.tracks.removeAll { $0.id == track.id }
                return .none

            case let .recommendationReduced(rejected, replacement):
                if state.tracks.replaceRecommendation(rejected, with: replacement) {
                    state.reducedRecommendationIDs.insert(rejected.id)
                }
                return .none

            case .toggleSubscribe:
                guard let detail = state.detail else { return .none }
                let subscribed = !detail.subscribed
                state.detail?.subscribed = subscribed
                let id = detail.id
                return .run { [provider] send in
                    do {
                        try await provider.subscribePlaylist(MusicID(id), subscribe: subscribed)
                        await send(.delegate(.subscriptionChanged))
                    } catch {
                        // Roll back the optimistic toggle.
                        await send(.subscribeReverted(to: !subscribed))
                        await send(.delegate(.toast(error.localizedDescription)))
                    }
                }

            case let .subscribeReverted(subscribed):
                state.detail?.subscribed = subscribed
                return .none

            case .startHeartbeat:
                guard let seed = state.playableTracks.randomElement() else { return .none }
                let playlistID = state.playlistID
                return .run { [intelligence] send in
                    do {
                        let tracks = try await intelligence?.intelligenceList(
                            songID: MusicID(seed.id), playlistID: MusicID(playlistID)) ?? []
                        if tracks.isEmpty {
                            await send(.delegate(.toast(String(localized: "心动模式暂时不可用"))))
                            return
                        }
                        await send(.delegate(.play(
                            tracks: tracks, source: .playlist(playlistID),
                            startAt: nil, context: .heartbeat)))
                        await send(.delegate(.toast(String(localized: "已开启心动模式"))))
                    } catch {
                        await send(.delegate(.toast(error.localizedDescription)))
                    }
                }

            case .delegate:
                return .none
            }
        }
    }

    private func startLoad(state: inout State) -> Effect<Action> {
        // Keep the existing content visible while refetching.
        if state.detail == nil { state.loadState = .loading }
        let playlistID = state.playlistID
        return .run { [provider] send in
            do {
                let response = try await provider.playlistDetail(id: MusicID(playlistID))
                await send(.detailResponse(
                    playlist: response, privileges: response.privileges))
            } catch {
                await send(.loadFailed(error.localizedDescription))
            }
        }
    }

    /// The detail response only carries the first tracks; the rest are paged
    /// in chunks so a 1000-song list does not arrive in one request.
    private func loadRemainingEffect(state: State) -> Effect<Action> {
        guard let detail = state.detail,
              state.tracks.count < detail.trackIds.count
        else { return .none }

        let remaining = detail.trackIds.map(\.id).dropFirst(state.tracks.count)
        let chunks = stride(from: 0, to: remaining.count, by: Self.chunkSize)
            .map { Array(remaining.dropFirst($0).prefix(Self.chunkSize)) }

        return .run { [provider] send in
            await send(.isLoadingMoreChanged(true))
            for chunk in chunks {
                guard let songs = try? await provider.songDetails(ids: chunk.map(MusicID.init)) else { break }
                await send(.chunkLoaded(songs: songs, privileges: songs.compactMap(\.embeddedPrivilege)))
            }
            await send(.chunksFinished)
        }
    }
}

private extension PlaylistDetailFeature.State {
    mutating func merge(privileges list: [TrackPrivilege]?) {
        for privilege in list ?? [] {
            self.privileges[privilege.id] = privilege
        }
    }
}
