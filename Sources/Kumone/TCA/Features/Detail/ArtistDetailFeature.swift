import ComposableArchitecture
import Dependencies
import Foundation

/// An artist page: their hot songs, their albums split into full releases and
/// EPs/singles, and — only for logged-in users — similar artists.
@Reducer
struct ArtistDetailFeature {
    @ObservableState
    struct State: Equatable {
        enum LoadState: Equatable {
            case idle, loading, loaded
            case error(String)
        }

        let artistID: Int
        var artist: ArtistSummary?
        var hotSongs: [Track] = []
        var albums: [AlbumSummary] = []
        var epsAndSingles: [AlbumSummary] = []
        var similar: [ArtistSummary] = []
        var isFollowed = false
        var loadState: LoadState = .idle

        /// Pushed by AppFeature; similar artists are a logged-in-only section.
        var isLoggedIn = false

        init(artistID: Int) {
            self.artistID = artistID
        }
    }

    enum Action: Equatable {
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

    enum Delegate: Equatable {
        case play(tracks: [Track], source: PlaySource, startAt: Track?, context: PlayContext?)
        case toast(String)
        case subscriptionChanged
    }

    @Dependency(\.netease) var netease

    /// `size` counts the tracks on a release; anything with one track is an
    /// EP or a single.
    static let fullAlbumMinSize = 2

    var body: some ReducerOf<Self> {
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
                return .run { [netease] send in
                    do {
                        try await netease.subscribeArtist(id: artistID, subscribe: followed)
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
        return .run { [netease] send in
            do {
                let response = try await netease.artist(id: artistID)
                await send(.artistResponse(artist: response.artist, hotSongs: response.hotSongs))

                if let result = try? await netease.artistAlbums(id: artistID, limit: 60, offset: 0) {
                    await send(.albumsResponse(result.hotAlbums))
                }
                if loggedIn {
                    let similar = (try? await netease.similarArtists(id: artistID)) ?? []
                    await send(.similarResponse(similar))
                }
            } catch {
                await send(.loadFailed(error.localizedDescription))
            }
        }
    }
}
