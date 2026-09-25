import Foundation

// QQ 音乐接入骨架：真实 QQ API 客户端接入前，所有可抛错能力均抛未实现错误，
// 不伪造数据。协议规定的无错误返回操作为空操作，不支持任何登录方式。
// 刻意只实现主协议，四个可选能力由 registry 解析为 nil。
public struct QQMusicProvider: MusicProvider {
    private let fallback = UnimplementedProvider()

    public init() {}

    public var isLoggedIn: Bool { fallback.isLoggedIn }
    public var supportedMethods: [LoginMethod] { fallback.supportedMethods }

    // MARK: - MusicAuth

    public func logout() async {
        await fallback.logout()
    }

    public func refreshLogin() async {
        await fallback.refreshLogin()
    }

    // MARK: - MusicLogin

    public func qrLoginURL(_ unikey: String) -> URL {
        fallback.qrLoginURL(unikey)
    }

    public func qrKey() async throws -> String {
        try await fallback.qrKey()
    }

    public func qrCheck(_ unikey: String) async throws -> LoginCheck {
        try await fallback.qrCheck(unikey)
    }

    public func sendSMSCode(phone: String, countryCode: String) async throws {
        try await fallback.sendSMSCode(phone: phone, countryCode: countryCode)
    }

    public func loginCellphone(phone: String, captcha: String, countryCode: String) async throws {
        try await fallback.loginCellphone(phone: phone, captcha: captcha, countryCode: countryCode)
    }

    // MARK: - MusicLibrary

    public func userAccount() async throws -> UserProfile {
        try await fallback.userAccount()
    }

    public func userPlaylists(uid: MusicID, limit: Int, offset: Int) async throws -> [PlaylistSummary] {
        try await fallback.userPlaylists(uid: uid, limit: limit, offset: offset)
    }

    public func likedTrackIDs(uid: MusicID) async throws -> [MusicID] {
        try await fallback.likedTrackIDs(uid: uid)
    }

    public func likeTrack(_ id: MusicID, like: Bool) async throws {
        try await fallback.likeTrack(id, like: like)
    }

    public func likedAlbums(limit: Int, offset: Int) async throws -> [AlbumSummary] {
        try await fallback.likedAlbums(limit: limit, offset: offset)
    }

    public func likedArtists(limit: Int, offset: Int) async throws -> [ArtistSummary] {
        try await fallback.likedArtists(limit: limit, offset: offset)
    }

    // MARK: - MusicPlaylist

    public func playlistDetail(id: MusicID) async throws -> PlaylistDetail {
        try await fallback.playlistDetail(id: id)
    }

    public func playlistBrief(id: MusicID) async throws -> PlaylistBriefInfo {
        try await fallback.playlistBrief(id: id)
    }

    public func createPlaylist(name: String, isPrivate: Bool) async throws -> MusicID? {
        try await fallback.createPlaylist(name: name, isPrivate: isPrivate)
    }

    public func deletePlaylist(_ id: MusicID) async throws {
        try await fallback.deletePlaylist(id)
    }

    public func subscribePlaylist(_ id: MusicID, subscribe: Bool) async throws {
        try await fallback.subscribePlaylist(id, subscribe: subscribe)
    }

    public func playlistTracks(_ op: PlaylistOp, playlistID: MusicID, trackIDs: [MusicID]) async throws {
        try await fallback.playlistTracks(op, playlistID: playlistID, trackIDs: trackIDs)
    }

    // MARK: - MusicPlayback

    public func songURL(ids: [MusicID], quality: SongQuality) async throws -> [SongURLData] {
        try await fallback.songURL(ids: ids, quality: quality)
    }

    public func songDetails(ids: [MusicID]) async throws -> [Track] {
        try await fallback.songDetails(ids: ids)
    }

    public func lyric(id: MusicID) async throws -> LyricResponse {
        try await fallback.lyric(id: id)
    }

    public func scrobbleStart(trackID: MusicID, sourceID: MusicID) async {
        await fallback.scrobbleStart(trackID: trackID, sourceID: sourceID)
    }

    public func scrobbleFinish(trackID: MusicID, sourceID: MusicID, seconds: Int) async {
        await fallback.scrobbleFinish(trackID: trackID, sourceID: sourceID, seconds: seconds)
    }

    public func similarSongs(id: MusicID, limit: Int) async throws -> [Track] {
        try await fallback.similarSongs(id: id, limit: limit)
    }

    // MARK: - MusicSearch

    public func search(_ keywords: String, category: SearchCategory, limit: Int, offset: Int) async throws -> SearchResult {
        try await fallback.search(keywords, category: category, limit: limit, offset: offset)
    }

    public func searchSuggest(_ keywords: String) async throws -> SearchSuggestion {
        try await fallback.searchSuggest(keywords)
    }

    public func searchDefaultKeyword() async throws -> String? {
        try await fallback.searchDefaultKeyword()
    }

    // MARK: - MusicDiscovery

    public func toplists() async throws -> [Chart] {
        try await fallback.toplists()
    }

    public func topArtists(limit: Int) async throws -> [ArtistSummary] {
        try await fallback.topArtists(limit: limit)
    }

    public func newAlbums(area: String, limit: Int, offset: Int) async throws -> [AlbumSummary] {
        try await fallback.newAlbums(area: area, limit: limit, offset: offset)
    }

    public func personalizedNewSongs(limit: Int) async throws -> [Track] {
        try await fallback.personalizedNewSongs(limit: limit)
    }

    public func dislikeRecommendedSong(_ id: MusicID) async throws -> Track {
        try await fallback.dislikeRecommendedSong(id)
    }

    public func personalizedPlaylists(limit: Int) async throws -> [PlaylistSummary] {
        try await fallback.personalizedPlaylists(limit: limit)
    }

    public func recommendResource() async throws -> [PlaylistSummary] {
        try await fallback.recommendResource()
    }

    public func dailyRecommendSongs() async throws -> [Track] {
        try await fallback.dailyRecommendSongs()
    }

    public func topPlaylists(category: String, order: String, limit: Int, offset: Int) async throws -> ChartList {
        try await fallback.topPlaylists(category: category, order: order, limit: limit, offset: offset)
    }

    public func highQualityPlaylists(category: String, limit: Int, before: Int?) async throws -> HighQualityList {
        try await fallback.highQualityPlaylists(category: category, limit: limit, before: before)
    }

    // MARK: - MusicAlbum

    public func album(id: MusicID) async throws -> AlbumDetail {
        try await fallback.album(id: id)
    }

    public func albumDynamic(id: MusicID) async throws -> AlbumDynamic {
        try await fallback.albumDynamic(id: id)
    }

    public func subscribeAlbum(_ id: MusicID, subscribe: Bool) async throws {
        try await fallback.subscribeAlbum(id, subscribe: subscribe)
    }

    // MARK: - MusicArtist

    public func artist(id: MusicID) async throws -> ArtistDetail {
        try await fallback.artist(id: id)
    }

    public func artistAlbums(id: MusicID, limit: Int, offset: Int) async throws -> ArtistAlbums {
        try await fallback.artistAlbums(id: id, limit: limit, offset: offset)
    }

    public func subscribeArtist(_ id: MusicID, subscribe: Bool) async throws {
        try await fallback.subscribeArtist(id, subscribe: subscribe)
    }

    public func similarArtists(id: MusicID) async throws -> [ArtistSummary] {
        try await fallback.similarArtists(id: id)
    }
}
