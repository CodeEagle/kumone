import ComposableArchitecture
import Foundation

/// 我的收藏: liked albums and followed artists. The collections themselves
/// live in `AccountFeature` (they are refreshed with the rest of the library);
/// this feature only owns the page's load trigger.
@Reducer
struct CollectionsFeature {
    @ObservableState
    struct State: Equatable {
        /// Pushed by AppFeature from the account scope.
        var likedAlbums: [AlbumSummary] = []
        var likedArtists: [ArtistSummary] = []
    }

    enum Action: Equatable {
        case onAppear
        case delegate(Delegate)
    }

    enum Delegate: Equatable {
        /// The page refreshes the sub-lists (liked albums / followed artists)
        /// when it appears.
        case refreshSublists
    }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                return .send(.delegate(.refreshSublists))

            case .delegate:
                return .none
            }
        }
    }
}
