import ComposableArchitecture
import Dependencies
import Foundation

/// The search results page: one query, one segmented tab, and per-tab results.
/// The "综合" tab fans out to all four endpoints at once; switching tabs loads
/// each tab once per query. Typing debounces before refetching.
@Reducer
struct SearchFeature {
    @ObservableState
    struct State: Equatable {
        var query: String
        var tab: Tab = .all
        var songs: [Track] = []
        var artists: [ArtistSummary] = []
        var albums: [AlbumSummary] = []
        var playlists: [PlaylistSummary] = []
        var isLoading = false
        /// Which tabs already have results for the current query.
        var loadedTabs: Set<Tab> = []

        init(query: String = "") {
            self.query = query
        }

        enum Tab: String, CaseIterable, Identifiable, Hashable {
            case all = "综合"
            case songs = "单曲"
            case artists = "歌手"
            case albums = "专辑"
            case playlists = "歌单"

            var id: String { rawValue }
        }
    }

    enum Action: Equatable {
        /// Typing. Resets the results and debounces a reload.
        case setQuery(String)
        case selectTab(State.Tab)
        /// Loads the current tab for the current query (no-op if already loaded
        /// or if the query is blank).
        case load
        case loaded(tab: State.Tab, results: Results)
    }

    /// One tab's worth of matches.
    struct Results: Equatable {
        var songs: [Track] = []
        var artists: [ArtistSummary] = []
        var albums: [AlbumSummary] = []
        var playlists: [PlaylistSummary] = []
    }

    @Dependency(\.netease) var netease
    @Dependency(\.continuousClock) var clock

    /// How long the query has to be quiet before a fetch fires.
    static let debounceInterval: Duration = .milliseconds(400)

    private enum CancelID { case query }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .setQuery(query):
                guard query != state.query else { return .none }
                state.query = query
                state.loadedTabs = []
                state.songs = []
                state.artists = []
                state.albums = []
                state.playlists = []
                return .run { [clock] send in
                    try? await clock.sleep(for: Self.debounceInterval)
                    await send(.load)
                }
                .cancellable(id: CancelID.query, cancelInFlight: true)

            case let .selectTab(tab):
                state.tab = tab
                return .run { send in await send(.load) }

            case .load:
                guard let effect = loadEffect(state: state) else { return .none }
                state.isLoading = true
                return effect

            case let .loaded(tab, results):
                state.loadedTabs.insert(tab)
                switch tab {
                case .all:
                    state.songs = results.songs
                    state.artists = results.artists
                    state.albums = results.albums
                    state.playlists = results.playlists
                case .songs:
                    state.songs = results.songs
                case .artists:
                    state.artists = results.artists
                case .albums:
                    state.albums = results.albums
                case .playlists:
                    state.playlists = results.playlists
                }
                state.isLoading = false
                return .none
            }
        }
    }

    private func loadEffect(state: State) -> Effect<Action>? {
        let query = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !state.loadedTabs.contains(state.tab) else { return nil }

        let tab = state.tab
        return .run { [netease] send in
            switch tab {
            case .all:
                async let songs = try? await netease.search(keywords: query, type: .songs, limit: 12, offset: 0)
                async let artists = try? await netease.search(keywords: query, type: .artists, limit: 10, offset: 0)
                async let albums = try? await netease.search(keywords: query, type: .albums, limit: 10, offset: 0)
                async let playlists = try? await netease.search(keywords: query, type: .playlists, limit: 10, offset: 0)
                await send(.loaded(tab: tab, results: Results(
                    songs: await songs?.songs ?? [],
                    artists: await artists?.artists ?? [],
                    albums: await albums?.albums ?? [],
                    playlists: await playlists?.playlists ?? [])))

            case .songs:
                let result = try? await netease.search(keywords: query, type: .songs, limit: 100, offset: 0)
                await send(.loaded(tab: tab, results: Results(songs: result?.songs ?? [])))

            case .artists:
                let result = try? await netease.search(keywords: query, type: .artists, limit: 50, offset: 0)
                await send(.loaded(tab: tab, results: Results(artists: result?.artists ?? [])))

            case .albums:
                let result = try? await netease.search(keywords: query, type: .albums, limit: 50, offset: 0)
                await send(.loaded(tab: tab, results: Results(albums: result?.albums ?? [])))

            case .playlists:
                let result = try? await netease.search(keywords: query, type: .playlists, limit: 50, offset: 0)
                await send(.loaded(tab: tab, results: Results(playlists: result?.playlists ?? [])))
            }
        }
    }
}
