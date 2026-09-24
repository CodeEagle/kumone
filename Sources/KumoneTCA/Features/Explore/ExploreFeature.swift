import ComposableArchitecture
import Dependencies
import Foundation
import KumoneCore

/// The "精选" page: a category chip row over several playlist endpoints.
/// Categories either replace the grid wholesale (排行榜), deliver a single
/// page (推荐歌单), or page through an API with a cursor (everything else).
@Reducer
public struct ExploreFeature {
    @ObservableState
    public struct State: Equatable {
        public enum LoadState: Equatable {
            case idle, loading, loaded
            case error(String)
        }

        public var loadState: LoadState = .idle
        public var selectedCategory: String = "全部"
        public var playlists: [PlaylistSummary] = []
        public var toplists: [ToplistItem] = []

        /// False once the current category's last page has been consumed.
        public var hasMore = true

        // Pagination cursors. Not UI state, but they have to live here so a
        // re-entrant loadMore sees the position the previous page left behind.
        public var offset = 0
        public var highQualityBefore = 0
    }

    public enum Action: Equatable {
        /// Loads the first page once; re-entrant calls while loaded are ignored.
        case onAppear
        /// Switches category. The same category is a no-op once data is loaded.
        case selectCategory(String)
        /// Loads the next page (the grid's "load more" trigger).
        case loadMore
        case pageLoaded(Page)
        /// Fetches a category playlist's tracks and hands them to the player.
        case playPlaylist(Int)
        case delegate(Delegate)
    }

    public enum Delegate: Equatable {
        case play(tracks: [Track], source: PlaySource, context: PlayContext?)
    }

    /// One category's worth of content. 排行榜 replaces the grid; every other
    /// category appends to it and reports where the next page starts.
    public enum Page: Equatable {
        case toplists([ToplistItem])
        case playlists(appended: [PlaylistSummary], hasMore: Bool, cursor: Cursor)
    }

    /// Where the next page of the current category begins.
    public struct Cursor: Equatable {
        public var offset = 0
        public var highQualityBefore = 0
    }

    @Dependency(\.netease) public var netease
    @Dependency(\.musicProvider) public var provider

    /// The chip row. "官方" is a real API category, not a synonym for "全部".
    public static let categories: [String] = [
        "全部", "推荐歌单", "精品歌单", "排行榜", "官方",
        "华语", "流行", "摇滚", "民谣", "电子", "轻音乐", "说唱", "爵士", "古典",
        "影视原声", "ACG", "古风", "怀旧", "治愈", "放松", "伤感", "快乐",
        "学习", "工作", "运动", "驾车", "夜晚",
    ]

    /// The default category pages through /playlist/list 50 at a time, and the
    /// API stops being useful past this offset.
    public static let maxOffset = 500
    public static let pageSize = 50

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                guard state.loadState == .idle else { return .none }
                state.loadState = .loading
                return loadEffect(state: state)

            case let .selectCategory(category):
                guard category != state.selectedCategory || state.playlists.isEmpty else {
                    return .none
                }
                state.selectedCategory = category
                state.playlists = []
                state.toplists = []
                state.hasMore = true
                state.offset = 0
                state.highQualityBefore = 0
                state.loadState = .loading
                return loadEffect(state: state)

            case .loadMore:
                guard state.loadState != .loading, state.hasMore else { return .none }
                state.loadState = .loading
                return loadEffect(state: state)

            case let .pageLoaded(page):
                switch page {
                case let .toplists(lists):
                    state.toplists = lists
                    state.hasMore = false
                case let .playlists(appended, hasMore, cursor):
                    state.playlists.append(contentsOf: appended)
                    state.hasMore = hasMore
                    state.offset = cursor.offset
                    state.highQualityBefore = cursor.highQualityBefore
                }
                state.loadState = .loaded
                return .none

            case .delegate:
                return .none

            case let .playPlaylist(id):
                return .run { [netease] send in
                    guard let detail = try? await netease.playlistDetail(id: id) else { return }
                    var tracks = detail.playlist.tracks
                    if tracks.isEmpty {
                        let ids = detail.playlist.trackIds.map(\.id)
                        tracks = (try? await netease.songDetails(ids: Array(ids.prefix(500))))?.songs ?? []
                    }
                    await send(.delegate(.play(
                        tracks: tracks,
                        source: .playlist(id),
                        context: .playlist(id: id, name: detail.playlist.name))))
                }
            }
        }
    }

    private func loadEffect(state: State) -> Effect<Action> {
        .run { [netease, provider] send in
            let category = state.selectedCategory
            let offset = state.offset
            let before = state.highQualityBefore
            let cursor = Cursor(offset: offset, highQualityBefore: before)
            let seen = Set(state.playlists.map(\.id))

            switch category {
            case "排行榜":
                let lists = (try? await netease.toplists()) ?? []
                await send(.pageLoaded(.toplists(lists)))

            case "推荐歌单":
                let lists = (try? await provider.personalizedPlaylists(limit: 100)) ?? []
                await send(.pageLoaded(.playlists(
                    appended: lists.deduped(against: seen), hasMore: false, cursor: cursor)))

            case "精品歌单":
                let result = try? await netease.highQualityPlaylists(
                    category: "全部", limit: Self.pageSize, before: before)
                if let result {
                    await send(.pageLoaded(.playlists(
                        appended: result.playlists.deduped(against: seen),
                        hasMore: result.more ?? false,
                        cursor: Cursor(offset: offset, highQualityBefore: result.lasttime ?? 0))))
                } else {
                    await send(.pageLoaded(.playlists(
                        appended: [], hasMore: false, cursor: cursor)))
                }

            default:
                let result = try? await netease.topPlaylists(
                    category: category, order: "hot", limit: Self.pageSize, offset: offset)
                if let result {
                    let nextOffset = offset + Self.pageSize
                    await send(.pageLoaded(.playlists(
                        appended: result.playlists.deduped(against: seen),
                        hasMore: (result.more ?? false) && nextOffset < Self.maxOffset,
                        cursor: Cursor(offset: nextOffset, highQualityBefore: before))))
                } else {
                    await send(.pageLoaded(.playlists(
                        appended: [], hasMore: false, cursor: cursor)))
                }
            }
        }
    }
}

private extension Array where Element == PlaylistSummary {
    /// The API repeats the tail of the previous page at the start of the next.
    func deduped(against seen: Set<Int>) -> [PlaylistSummary] {
        var seen = seen
        return filter { seen.insert($0.id).inserted }
    }
}
