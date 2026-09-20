import ComposableArchitecture
import Dependencies
import Foundation

/// The "推荐" page: personalized playlists, the per-account radar family,
/// a fixed set of toplists, new albums, a shuffled artist row, and the daily
/// recommendation cover. Everything is loaded in parallel; a logged-out user
/// gets the public subsets only.
@Reducer
struct HomeFeature {
    @ObservableState
    struct State: Equatable {
        enum LoadState: Equatable {
            case idle, loading, loaded
            case error(String)
        }

        var loadState: LoadState = .idle
        var recommendPlaylists: [PlaylistSummary] = []
        var radarPlaylists: [RadarPlaylist] = []
        var toplists: [ToplistItem] = []
        var newAlbums: [AlbumSummary] = []
        var topArtists: [ArtistSummary] = []
        var dailyFirstCover: String?

        /// Pushed by AppFeature; decides whether the radar and daily rows load.
        var isLoggedIn = false

        /// One of the personalized radar families — a global playlist ID whose
        /// title and artwork are generated per account.
        struct RadarPlaylist: Equatable, Identifiable {
            let id: Int
            let title: String
            let subtitle: String?
            let coverURL: String?
        }
    }

    enum Action: Equatable {
        /// Loads once; re-entrant calls while already loaded are ignored.
        case onAppear
        /// Forces a reload (pull to refresh, or a login state change).
        case reload
        case loaded(Sections)
        /// Fetches a playlist's tracks and hands them to the player.
        case playPlaylist(Int)
        /// Fetches an album's tracks and hands them to the player.
        case playAlbum(AlbumSummary)
        case startHeartbeat
        case delegate(Delegate)
    }

    enum Delegate: Equatable {
        case play(tracks: [Track], source: PlaySource, context: PlayContext?)
        /// 心动模式: needs the account's liked list and a seed track, so the
        /// parent (which sees both features) runs it.
        case startHeartbeat
    }

    /// Everything a load gathered, delivered in one piece so the "both empty
    /// means the network failed" check sees every section.
    struct Sections: Equatable {
        var recommendPlaylists: [PlaylistSummary]
        var radarPlaylists: [State.RadarPlaylist]
        var toplists: [ToplistItem]
        var newAlbums: [AlbumSummary]
        var topArtists: [ArtistSummary]
        var dailyFirstCover: String?
    }

    @Dependency(\.netease) var netease

    /// The toplists worth showing on the home grid (the API returns hundreds).
    static let featuredToplistIDs: Set<Int> = [
        19_723_756, 3_779_629, 2_884_035, 3_778_678, 60198,
    ]

    /// The personalized radar family, same list YesPlayMusic special-cases.
    static let radarPlaylistIDs: [Int] = [
        3_136_952_023, // 私人雷达
        2_829_883_282, // 华语私人雷达
        2_829_816_518, // 欧美私人雷达
        2_829_896_389, // 日系私人雷达
    ]

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                guard state.loadState != .loaded else { return .none }
                state.loadState = .loading
                return loadEffect(state: state)

            case .reload:
                state.loadState = .loading
                return loadEffect(state: state)

            case let .loaded(sections):
                state.recommendPlaylists = sections.recommendPlaylists
                state.radarPlaylists = sections.radarPlaylists
                state.toplists = sections.toplists
                state.newAlbums = sections.newAlbums
                state.topArtists = sections.topArtists
                state.dailyFirstCover = sections.dailyFirstCover
                state.loadState =
                    sections.recommendPlaylists.isEmpty && sections.newAlbums.isEmpty
                    ? .error(String(localized: "网络连接失败"))
                    : .loaded
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

            case let .playAlbum(album):
                return .run { [netease] send in
                    guard let detail = try? await netease.album(id: album.id) else { return }
                    await send(.delegate(.play(
                        tracks: detail.songs,
                        source: .album(album.id),
                        context: .album(id: album.id, name: album.name))))
                }

            case .startHeartbeat:
                return .send(.delegate(.startHeartbeat))
            }
        }
    }

    private func loadEffect(state: State) -> Effect<Action> {
        .run { [netease] send in
            let loggedIn = state.isLoggedIn

            async let playlists = Self.fetchRecommendPlaylists(
                loggedIn: loggedIn, netease: netease)
            async let toplists = try? await netease.toplists()
            async let albums = try? await netease.newAlbums(area: "ALL", limit: 20, offset: 0)
            async let artists = try? await netease.topArtists(limit: 100)

            var sections = Sections(
                recommendPlaylists: await playlists,
                radarPlaylists: [],
                toplists: (await toplists ?? [])
                    .filter { Self.featuredToplistIDs.contains($0.id) },
                newAlbums: await albums ?? [],
                topArtists: Array((await artists ?? []).shuffled().prefix(6)),
                dailyFirstCover: nil)

            if loggedIn {
                if let daily = try? await netease.dailyRecommendSongs() {
                    sections.dailyFirstCover = daily.first?.album.picUrl
                }
                sections.radarPlaylists = await Self.fetchRadarPlaylists(netease: netease)
            }

            await send(.loaded(sections))
        }
    }

    /// Logged-in users get their day-of recommend resource ahead of the
    /// generic personalized list; logged-out users only see the latter.
    private static func fetchRecommendPlaylists(
        loggedIn: Bool, netease: NeteaseMusicClient
    ) async -> [PlaylistSummary] {
        if loggedIn {
            async let recommend = try? await netease.recommendResource()
            async let personalized = try? await netease.personalizedPlaylists(limit: 30)
            let head = await recommend ?? []
            let tail = await personalized ?? []
            var seen = Set<Int>()
            return (head + tail).filter { seen.insert($0.id).inserted }
        }
        return (try? await netease.personalizedPlaylists(limit: 30)) ?? []
    }

    /// The radar names arrive as "今天从《…》听起|私人雷达" — the tail is the
    /// family name, the head is the per-account reason.
    private static func fetchRadarPlaylists(
        netease: NeteaseMusicClient
    ) async -> [State.RadarPlaylist] {
        await withTaskGroup(of: (Int, NeteaseAPI.PlaylistBrief.Body?).self) { group in
            for id in radarPlaylistIDs {
                group.addTask { (id, try? await netease.playlistBrief(id: id)) }
            }
            var byID: [Int: NeteaseAPI.PlaylistBrief.Body] = [:]
            for await (id, brief) in group {
                if let brief { byID[id] = brief }
            }
            return radarPlaylistIDs.compactMap { id in
                guard let brief = byID[id] else { return nil }
                let parts = (brief.name ?? "").components(separatedBy: "|")
                let title = parts.count > 1
                    ? parts.last!
                    : (brief.name ?? String(localized: "雷达歌单"))
                let subtitle = parts.count > 1
                    ? parts.dropLast().joined(separator: "|")
                    : nil
                return State.RadarPlaylist(
                    id: id, title: title, subtitle: subtitle,
                    coverURL: brief.coverImgUrl)
            }
        }
    }
}
