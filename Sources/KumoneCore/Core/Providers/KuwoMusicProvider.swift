import Foundation

/// Anonymous Kuwo provider; intentionally omits all four optional capabilities.
public struct KuwoMusicProvider: MusicProvider {

    private let api: KuwoMusicAPI

    public init(api: KuwoMusicAPI = KuwoMusicAPI()) {
        self.api = api
    }

    public var isLoggedIn: Bool { false }
    public var supportedMethods: [LoginMethod] { [] }

    // MARK: - MusicAuth

    public func logout() async {
        // Anonymous provider has no session to clear.
    }

    public func refreshLogin() async {
        // Anonymous provider has no login to refresh.
    }

    // MARK: - MusicLogin

    public func qrLoginURL(_ unikey: String) -> URL {
        URL(string: "about:blank")!
    }

    public func qrKey() async throws -> String {
        throw KuwoAPIError.unavailable
    }

    public func qrCheck(_ unikey: String) async throws -> LoginCheck {
        throw KuwoAPIError.unavailable
    }

    public func sendSMSCode(phone: String, countryCode: String) async throws {
        throw KuwoAPIError.unavailable
    }

    public func loginCellphone(phone: String, captcha: String, countryCode: String) async throws {
        throw KuwoAPIError.unavailable
    }

    // MARK: - MusicLibrary

    public func userAccount() async throws -> UserProfile {
        throw KuwoAPIError.unavailable
    }

    public func userPlaylists(uid: MusicID, limit: Int, offset: Int) async throws -> [PlaylistSummary] {
        throw KuwoAPIError.unavailable
    }

    public func likedTrackIDs(uid: MusicID) async throws -> [MusicID] {
        throw KuwoAPIError.unavailable
    }

    public func likeTrack(_ id: MusicID, like: Bool) async throws {
        throw KuwoAPIError.unavailable
    }

    public func likedAlbums(limit: Int, offset: Int) async throws -> [AlbumSummary] {
        throw KuwoAPIError.unavailable
    }

    public func likedArtists(limit: Int, offset: Int) async throws -> [ArtistSummary] {
        throw KuwoAPIError.unavailable
    }

    // MARK: - MusicPlaylist

    public func playlistDetail(id: MusicID) async throws -> PlaylistDetail {
        throw KuwoAPIError.playlistUnavailable
    }

    public func playlistBrief(id: MusicID) async throws -> PlaylistBriefInfo {
        throw KuwoAPIError.unavailable
    }

    public func createPlaylist(name: String, isPrivate: Bool) async throws -> MusicID? {
        throw KuwoAPIError.unavailable
    }

    public func deletePlaylist(_ id: MusicID) async throws {
        throw KuwoAPIError.unavailable
    }

    public func subscribePlaylist(_ id: MusicID, subscribe: Bool) async throws {
        throw KuwoAPIError.unavailable
    }

    public func playlistTracks(_ op: PlaylistOp, playlistID: MusicID, trackIDs: [MusicID]) async throws {
        throw KuwoAPIError.unavailable
    }

    // MARK: - MusicPlayback

    public func songURL(ids: [MusicID], quality: SongQuality) async throws -> [SongURLData] {
        // Validate the entire batch before issuing any requests.
        for id in ids {
            guard case .source(_, .kuwo) = id, KuwoMusicAPI.validRID(id.sourceID) else {
                throw KuwoAPIError.invalidIdentifier
            }
        }
        var result: [SongURLData] = []
        for id in ids {
            let url = try await api.playURL(rid: id.sourceID)
            // Anonymous conversion only exposes MP3; never label it lossless.
            result.append(SongURLData(id: Int(id.sourceID)!, url: url.absoluteString,
                br: 128_000, size: 0, type: "mp3", level: "standard", fee: 0,
                freeTrialInfo: nil, time: 0))
        }
        return result
    }

    public func songDetails(ids: [MusicID]) async throws -> [Track] {
        throw KuwoAPIError.unavailable
    }

    public func lyric(id: MusicID) async throws -> LyricResponse {
        throw KuwoAPIError.lyricUnavailable
    }

    public func scrobbleStart(trackID: MusicID, sourceID: MusicID) async {
        // Anonymous endpoint unavailable.
    }

    public func scrobbleFinish(trackID: MusicID, sourceID: MusicID, seconds: Int) async {
        // Anonymous endpoint unavailable.
    }

    public func similarSongs(id: MusicID, limit: Int) async throws -> [Track] {
        throw KuwoAPIError.unavailable
    }

    // MARK: - MusicSearch

    public func search(_ keywords: String, category: SearchCategory, limit: Int, offset: Int) async throws -> SearchResult {
        guard category == .songs else { throw KuwoAPIError.searchCategoryUnavailable }
        let page = try await api.search(keyword: keywords, limit: limit, offset: offset)
        return SearchResult(songs: page.abslist.map(\.track), albums: [], artists: [], playlists: [],
            counts: SearchCounts(songs: Int(page.TOTAL ?? "") ?? page.abslist.count,
                albums: 0, artists: 0, playlists: 0))
    }

    public func searchSuggest(_ keywords: String) async throws -> SearchSuggestion {
        let page = try await api.search(keyword: keywords, limit: 5, offset: 0)
        return SearchSuggestion(songs: page.abslist.map(\.track), artists: [], albums: [], playlists: [])
    }

    public func searchDefaultKeyword() async throws -> String? {
        throw KuwoAPIError.unavailable
    }

    // MARK: - MusicDiscovery

    public func toplists() async throws -> [Chart] {
        try await api.bangList()
    }

    public func topArtists(limit: Int) async throws -> [ArtistSummary] {
        throw KuwoAPIError.unavailable
    }

    public func newAlbums(area: String, limit: Int, offset: Int) async throws -> [AlbumSummary] {
        throw KuwoAPIError.unavailable
    }

    public func personalizedNewSongs(limit: Int) async throws -> [Track] {
        throw KuwoAPIError.unavailable
    }

    public func dislikeRecommendedSong(_ id: MusicID) async throws -> Track {
        throw KuwoAPIError.unavailable
    }

    public func personalizedPlaylists(limit: Int) async throws -> [PlaylistSummary] {
        throw KuwoAPIError.playlistUnavailable
    }

    public func recommendResource() async throws -> [PlaylistSummary] {
        throw KuwoAPIError.unavailable
    }

    public func dailyRecommendSongs() async throws -> [Track] {
        throw KuwoAPIError.unavailable
    }

    public func topPlaylists(category: String, order: String, limit: Int, offset: Int) async throws -> ChartList {
        throw KuwoAPIError.unavailable
    }

    public func highQualityPlaylists(category: String, limit: Int, before: Int?) async throws -> HighQualityList {
        throw KuwoAPIError.unavailable
    }

    // MARK: - MusicAlbum

    public func album(id: MusicID) async throws -> AlbumDetail {
        throw KuwoAPIError.unavailable
    }

    public func albumDynamic(id: MusicID) async throws -> AlbumDynamic {
        throw KuwoAPIError.unavailable
    }

    public func subscribeAlbum(_ id: MusicID, subscribe: Bool) async throws {
        throw KuwoAPIError.unavailable
    }

    // MARK: - MusicArtist

    public func artist(id: MusicID) async throws -> ArtistDetail {
        throw KuwoAPIError.unavailable
    }

    public func artistAlbums(id: MusicID, limit: Int, offset: Int) async throws -> ArtistAlbums {
        throw KuwoAPIError.unavailable
    }

    public func subscribeArtist(_ id: MusicID, subscribe: Bool) async throws {
        throw KuwoAPIError.unavailable
    }

    public func similarArtists(id: MusicID) async throws -> [ArtistSummary] {
        throw KuwoAPIError.unavailable
    }
}

