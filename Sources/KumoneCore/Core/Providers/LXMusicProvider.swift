import Foundation

/// Resolution-only LX provider; intentionally omits all four optional capabilities.
public struct LXMusicProvider: MusicProvider {

    private let api: LXMusicAPI

    public init(api: LXMusicAPI = LXMusicAPI()) {
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
        throw LXAPIError.business(code: -1)
    }

    public func qrCheck(_ unikey: String) async throws -> LoginCheck {
        throw LXAPIError.business(code: -1)
    }

    public func sendSMSCode(phone: String, countryCode: String) async throws {
        throw LXAPIError.business(code: -1)
    }

    public func loginCellphone(phone: String, captcha: String, countryCode: String) async throws {
        throw LXAPIError.business(code: -1)
    }

    // MARK: - MusicLibrary

    public func userAccount() async throws -> UserProfile {
        throw LXAPIError.business(code: -1)
    }

    public func userPlaylists(uid: MusicID, limit: Int, offset: Int) async throws -> [PlaylistSummary] {
        throw LXAPIError.business(code: -1)
    }

    public func likedTrackIDs(uid: MusicID) async throws -> [MusicID] {
        throw LXAPIError.business(code: -1)
    }

    public func likeTrack(_ id: MusicID, like: Bool) async throws {
        throw LXAPIError.business(code: -1)
    }

    public func likedAlbums(limit: Int, offset: Int) async throws -> [AlbumSummary] {
        throw LXAPIError.business(code: -1)
    }

    public func likedArtists(limit: Int, offset: Int) async throws -> [ArtistSummary] {
        throw LXAPIError.business(code: -1)
    }

    // MARK: - MusicPlaylist

    public func playlistDetail(id: MusicID) async throws -> PlaylistDetail {
        throw LXAPIError.business(code: -1)
    }

    public func playlistBrief(id: MusicID) async throws -> PlaylistBriefInfo {
        throw LXAPIError.business(code: -1)
    }

    public func createPlaylist(name: String, isPrivate: Bool) async throws -> MusicID? {
        throw LXAPIError.business(code: -1)
    }

    public func deletePlaylist(_ id: MusicID) async throws {
        throw LXAPIError.business(code: -1)
    }

    public func subscribePlaylist(_ id: MusicID, subscribe: Bool) async throws {
        throw LXAPIError.business(code: -1)
    }

    public func playlistTracks(_ op: PlaylistOp, playlistID: MusicID, trackIDs: [MusicID]) async throws {
        throw LXAPIError.business(code: -1)
    }

    // MARK: - MusicPlayback

    public func songURL(ids: [MusicID], quality: SongQuality) async throws -> [SongURLData] {
        let sources = try ids.map { try api.source(for: $0) }
        let tier = try LXMusicAPI.qualityParameter(quality)
        var result: [SongURLData] = []
        for (id, source) in zip(ids, sources) {
            let url = try await api.songURL(source: source, songID: id.sourceID, quality: quality)
            // The service reports no codec/actual quality; do not claim the requested tier was delivered.
            result.append(SongURLData(id: Int(id.sourceID) ?? 0, url: url.absoluteString,
                br: tier == "128k" ? 128_000 : tier == "320k" ? 320_000 : 999_000,
                size: 0, type: nil, level: nil, fee: 0, freeTrialInfo: nil, time: 0))
        }
        return result
    }

    public func songDetails(ids: [MusicID]) async throws -> [Track] {
        throw LXAPIError.business(code: -1)
    }

    public func lyric(id: MusicID) async throws -> LyricResponse {
        try await api.lyric(source: api.source(for: id), songID: id.sourceID)
    }

    public func scrobbleStart(trackID: MusicID, sourceID: MusicID) async {
        // Anonymous endpoint unavailable.
    }

    public func scrobbleFinish(trackID: MusicID, sourceID: MusicID, seconds: Int) async {
        // Anonymous endpoint unavailable.
    }

    public func similarSongs(id: MusicID, limit: Int) async throws -> [Track] {
        throw LXAPIError.business(code: -1)
    }

    // MARK: - MusicSearch

    public func search(_ keywords: String, category: SearchCategory, limit: Int, offset: Int) async throws -> SearchResult {
        throw LXAPIError.business(code: -1)
    }

    public func searchSuggest(_ keywords: String) async throws -> SearchSuggestion {
        throw LXAPIError.business(code: -1)
    }

    public func searchDefaultKeyword() async throws -> String? {
        throw LXAPIError.business(code: -1)
    }

    // MARK: - MusicDiscovery

    public func toplists() async throws -> [Chart] {
        throw LXAPIError.business(code: -1)
    }

    public func topArtists(limit: Int) async throws -> [ArtistSummary] {
        throw LXAPIError.business(code: -1)
    }

    public func newAlbums(area: String, limit: Int, offset: Int) async throws -> [AlbumSummary] {
        throw LXAPIError.business(code: -1)
    }

    public func personalizedNewSongs(limit: Int) async throws -> [Track] {
        throw LXAPIError.business(code: -1)
    }

    public func dislikeRecommendedSong(_ id: MusicID) async throws -> Track {
        throw LXAPIError.business(code: -1)
    }

    public func personalizedPlaylists(limit: Int) async throws -> [PlaylistSummary] {
        throw LXAPIError.business(code: -1)
    }

    public func recommendResource() async throws -> [PlaylistSummary] {
        throw LXAPIError.business(code: -1)
    }

    public func dailyRecommendSongs() async throws -> [Track] {
        throw LXAPIError.business(code: -1)
    }

    public func topPlaylists(category: String, order: String, limit: Int, offset: Int) async throws -> ChartList {
        throw LXAPIError.business(code: -1)
    }

    public func highQualityPlaylists(category: String, limit: Int, before: Int?) async throws -> HighQualityList {
        throw LXAPIError.business(code: -1)
    }

    // MARK: - MusicAlbum

    public func album(id: MusicID) async throws -> AlbumDetail {
        throw LXAPIError.business(code: -1)
    }

    public func albumDynamic(id: MusicID) async throws -> AlbumDynamic {
        throw LXAPIError.business(code: -1)
    }

    public func subscribeAlbum(_ id: MusicID, subscribe: Bool) async throws {
        throw LXAPIError.business(code: -1)
    }

    // MARK: - MusicArtist

    public func artist(id: MusicID) async throws -> ArtistDetail {
        throw LXAPIError.business(code: -1)
    }

    public func artistAlbums(id: MusicID, limit: Int, offset: Int) async throws -> ArtistAlbums {
        throw LXAPIError.business(code: -1)
    }

    public func subscribeArtist(_ id: MusicID, subscribe: Bool) async throws {
        throw LXAPIError.business(code: -1)
    }

    public func similarArtists(id: MusicID) async throws -> [ArtistSummary] {
        throw LXAPIError.business(code: -1)
    }
}

