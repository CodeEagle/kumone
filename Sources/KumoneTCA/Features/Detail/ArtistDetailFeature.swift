import ComposableArchitecture
import Dependencies
import Foundation
import KumoneCore

/// An artist page: their hot songs, their albums split into full releases and
/// EPs/singles, and — only for logged-in users — similar artists.
@Reducer
public struct ArtistDetailFeature {
    @ObservableState
    public struct State: Equatable {
        public enum LoadState: Equatable {
            case idle, loading, loaded
            case error(String)
        }

        public let artistID: Int
        public var artist: ArtistSummary?
        public var hotSongs: [Track] = []
        public var albums: [AlbumSummary] = []
        public var epsAndSingles: [AlbumSummary] = []
        public var similar: [ArtistSummary] = []
        public var isFollowed = false
        public var loadState: LoadState = .idle

        /// Pushed by AppFeature; similar artists are a logged-in-only section.
        public var isLoggedIn = false

        public init(artistID: Int) {
            self.artistID = artistID
        }
    }

    public enum Action: Equatable {
        case onAppear
        case reload
        case artistResponse(artist: ArtistSummary, hotSongs: [Track])
        case albumsResponse([AlbumSummary])
        case similarResponse([ArtistSummary])
        case loadFailed(String)
        case playAll
        case toggleFollow
        case followReverted(to: Bool)
        case delegate(Delegate)
    }

    public enum Delegate: Equatable {
        case play(tracks: [Track], source: PlaySource, startAt: Track?, context: PlayContext?)
        case toast(String)
        case subscriptionChanged
    }

    @Dependency(\.musicProvider) public var provider

    /// `size` counts the tracks on a release; anything with one track is an
    /// EP or a single.
    public static let fullAlbumMinSize = 2

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                guard state.loadState == .idle else { return .none }
                return startLoad(state: &state)

            case .reload:
                return startLoad(state: &state)

            case let .artistResponse(artist, hotSongs):
                state.artist = artist
                state.hotSongs = hotSongs
                state.isFollowed = artist.followed
                state.loadState = .loaded
                return .none

            case let .albumsResponse(albums):
                state.albums = albums.filter { $0.size >= Self.fullAlbumMinSize }
                state.epsAndSingles = albums.filter { $0.size < Self.fullAlbumMinSize }
                return .none

            case let .similarResponse(similar):
                state.similar = similar
                return .none

            case let .loadFailed(message):
                state.loadState = .error(message)
                return .none

            case .playAll:
                guard let artist = state.artist else { return .none }
                return .send(.delegate(.play(
                    tracks: state.hotSongs, source: .artist(state.artistID),
                    startAt: nil, context: .artist(id: state.artistID, name: artist.name))))

            case .toggleFollow:
                let followed = !state.isFollowed
                state.isFollowed = followed
                let artistID = state.artistID
                return .run { [provider] send in
                    do {
                        try await provider.subscribeArtist(MusicID(artistID), subscribe: followed)
                        await send(.delegate(.subscriptionChanged))
                        await send(.delegate(.toast(
                            followed
                            ? String(localized: "已关注歌手")
                            : String(localized: "已取消关注"))))
                    } catch {
                        await send(.followReverted(to: !followed))
                        await send(.delegate(.toast(error.localizedDescription)))
                    }
                }

            case let .followReverted(followed):
                state.isFollowed = followed
                return .none

            case .delegate:
                return .none
            }
        }
    }

    private func startLoad(state: inout State) -> Effect<Action> {
        state.loadState = .loading
        let artistID = state.artistID
        let loggedIn = state.isLoggedIn
        return .run { [provider] send in
            do {
                let response = try await provider.artist(id: MusicID(artistID))
                await send(.artistResponse(artist: response.artist, hotSongs: response.hotSongs))

                if let result = try? await provider.artistAlbums(id: MusicID(artistID), limit: 60, offset: 0) {
                    await send(.albumsResponse(result.albums))
                }
                if loggedIn {
                    let similar = (try? await provider.similarArtists(id: MusicID(artistID))) ?? []
                    await send(.similarResponse(similar))
                }
            } catch {
                await send(.loadFailed(error.localizedDescription))
            }
        }
    }
}
