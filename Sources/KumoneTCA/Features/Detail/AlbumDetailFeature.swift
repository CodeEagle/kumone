import ComposableArchitecture
import Dependencies
import Foundation
import KumoneCore

/// An album page: the album with its songs, whether the account has collected
/// it, and the same artist's other releases.
@Reducer
public struct AlbumDetailFeature {
    @ObservableState
    public struct State: Equatable {
        public enum LoadState: Equatable {
            case idle, loading, loaded
            case error(String)
        }

        public let albumID: Int
        public var album: AlbumDetail?
        public var tracks: [Track] = []
        public var otherAlbums: [AlbumSummary] = []
        public var isSubscribed = false
        public var loadState: LoadState = .idle

        public init(albumID: Int) {
            self.albumID = albumID
        }
    }

    public enum Action: Equatable {
        case onAppear
        case reload
        case albumResponse(album: AlbumDetail, songs: [Track])
        case dynamicResponse(isSubscribed: Bool)
        case otherAlbumsResponse([AlbumSummary])
        case loadFailed(String)
        case playAll
        case toggleSubscribe
        case subscribeReverted(to: Bool)
        case delegate(Delegate)
    }

    public enum Delegate: Equatable {
        case play(tracks: [Track], source: PlaySource, startAt: Track?, context: PlayContext?)
        case toast(String)
        case subscriptionChanged
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

            case let .albumResponse(album, songs):
                state.album = album
                state.tracks = songs
                state.loadState = .loaded
                return .none

            case let .dynamicResponse(isSubscribed):
                state.isSubscribed = isSubscribed
                return .none

            case let .otherAlbumsResponse(albums):
                state.otherAlbums = albums.filter { $0.id != state.albumID }
                return .none

            case let .loadFailed(message):
                state.loadState = .error(message)
                return .none

            case .playAll:
                guard let album = state.album else { return .none }
                return .send(.delegate(.play(
                    tracks: state.tracks, source: .album(state.albumID),
                    startAt: nil, context: .album(id: state.albumID, name: album.name))))

            case .toggleSubscribe:
                let subscribed = !state.isSubscribed
                state.isSubscribed = subscribed
                let albumID = state.albumID
                return .run { [provider] send in
                    do {
                        try await provider.subscribeAlbum(MusicID(albumID), subscribe: subscribed)
                        await send(.delegate(.subscriptionChanged))
                        await send(.delegate(.toast(
                            subscribed
                            ? String(localized: "已收藏专辑")
                            : String(localized: "已取消收藏"))))
                    } catch {
                        await send(.subscribeReverted(to: !subscribed))
                        await send(.delegate(.toast(error.localizedDescription)))
                    }
                }

            case let .subscribeReverted(subscribed):
                state.isSubscribed = subscribed
                return .none

            case .delegate:
                return .none
            }
        }
    }

    private func startLoad(state: inout State) -> Effect<Action> {
        state.loadState = .loading
        let albumID = state.albumID
        return .run { [provider] send in
            do {
                let response = try await provider.album(id: MusicID(albumID))
                await send(.albumResponse(album: response, songs: response.songs))

                if let dynamic = try? await provider.albumDynamic(id: MusicID(albumID)) {
                    await send(.dynamicResponse(isSubscribed: dynamic.isSubscribed))
                }
                if let artistID = response.artist?.id,
                   let albums = try? await provider.artistAlbums(id: MusicID(artistID), limit: 12, offset: 0)
                {
                    await send(.otherAlbumsResponse(albums.albums))
                }
            } catch {
                await send(.loadFailed(error.localizedDescription))
            }
        }
    }
}
