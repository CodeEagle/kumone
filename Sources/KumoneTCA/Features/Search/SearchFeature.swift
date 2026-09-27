import ComposableArchitecture
import Dependencies
import Foundation
import KumoneCore

/// The search results page: one query, one segmented tab, and per-tab results.
/// The "综合" tab fans out to all four endpoints at once; switching tabs loads
/// each tab once per query. Typing debounces before refetching.
@Reducer
public struct SearchFeature {
    @ObservableState
    public struct State: Equatable {
        public var query: String
        public var tab: Tab = .all
        public var songs: [Track] = []
        public var artists: [ArtistSummary] = []
        public var albums: [AlbumSummary] = []
        public var playlists: [PlaylistSummary] = []
        public var isLoading = false
        /// Which tabs already have results for the current query.
        public var loadedTabs: Set<Tab> = []
        /// Tabs whose last load for this query failed, so the view can offer a
        /// retry instead of showing an empty result as if it were a match.
        public var failedTabs: Set<Tab> = []

        public init(query: String = "") {
            self.query = query
        }

        public enum Tab: String, CaseIterable, Identifiable, Hashable {
            case all = "综合"
            case songs = "单曲"
            case artists = "歌手"
            case albums = "专辑"
            case playlists = "歌单"

            public var id: String { rawValue }
        }
    }

    public enum Action: Equatable {
        /// Typing. Resets the results and debounces a reload.
        case setQuery(String)
        case selectTab(State.Tab)
        /// Loads the current tab for the current query (no-op if already loaded
        /// or if the query is blank).
        case load
        case loaded(query: String, tab: State.Tab, results: Results)
        case loadFailed(query: String, tab: State.Tab)
        case delegate(Delegate)
    }

    public enum Delegate: Equatable {
        case play(tracks: [Track], source: PlaySource, startAt: Track?, context: PlayContext?)
    }

    /// One tab's worth of matches.
    public struct Results: Equatable {
        public var songs: [Track] = []
        public var artists: [ArtistSummary] = []
        public var albums: [AlbumSummary] = []
        public var playlists: [PlaylistSummary] = []
    }

    @Dependency(\.musicProvider) public var provider
    @Dependency(\.continuousClock) public var clock

    /// How long the query has to be quiet before a fetch fires.
    public static let debounceInterval: Duration = .milliseconds(400)

    private enum CancelID { case query }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .setQuery(query):
                guard query != state.query else { return .none }
                state.query = query
                state.loadedTabs = []
                state.failedTabs = []
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

            case let .loaded(query, tab, results):
                guard query == state.query.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    // A response from an earlier query arrived after the query
                    // changed; it must not overwrite the current results.
                    return .none
                }
                state.loadedTabs.insert(tab)
                state.failedTabs.remove(tab)
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

            case let .loadFailed(query, tab):
                guard query == state.query.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return .none
                }
                // A failure is not a result: keep the tab reloadable and let the
                // view offer a retry instead of caching an empty success.
                state.isLoading = false
                state.failedTabs.insert(tab)
                return .none

            case .delegate:
                return .none
            }
        }
    }

    private func loadEffect(state: State) -> Effect<Action>? {
        let query = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !state.loadedTabs.contains(state.tab) else { return nil }

        let tab = state.tab
        return .run { [provider] send in
            // Runs one endpoint, turning a failure into a `loadFailed` action
            // so the tab stays reloadable instead of caching an empty result.
            func attempt(
                _ category: SearchCategory,
                _ limit: Int,
                makeResults: @Sendable (SearchResult) -> Results
            ) async -> Action {
                do {
                    let result = try await provider.search(query, category: category, limit: limit, offset: 0)
                    return .loaded(query: query, tab: tab, results: makeResults(result))
                } catch {
                    return .loadFailed(query: query, tab: tab)
                }
            }

            switch tab {
            case .all:
                async let songs = attempt(.songs, 12) { Results(songs: $0.songs) }
                async let artists = attempt(.artists, 10) { Results(artists: $0.artists) }
                async let albums = attempt(.albums, 10) { Results(albums: $0.albums) }
                async let playlists = attempt(.playlists, 10) { Results(playlists: $0.playlists) }
                let attempts = await [songs, artists, albums, playlists]
                var merged = Results()
                var everythingFailed = true
                for pending in attempts {
                    if case let .loaded(_, _, results) = pending {
                        everythingFailed = false
                        merged.songs += results.songs
                        merged.artists += results.artists
                        merged.albums += results.albums
                        merged.playlists += results.playlists
                    }
                }
                await send(everythingFailed
                    ? .loadFailed(query: query, tab: tab)
                    : .loaded(query: query, tab: tab, results: merged))

            case .songs:
                await send(await attempt(.songs, 100) { Results(songs: $0.songs) })

            case .artists:
                await send(await attempt(.artists, 50) { Results(artists: $0.artists) })

            case .albums:
                await send(await attempt(.albums, 50) { Results(albums: $0.albums) })

            case .playlists:
                await send(await attempt(.playlists, 50) { Results(playlists: $0.playlists) })
            }
        }
    }
}
