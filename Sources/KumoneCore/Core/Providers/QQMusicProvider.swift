import Foundation

// QQ 音乐匿名接入：热搜、榜单、推荐歌单和歌词使用已验证接口。
// 尚未接入的能力继续明确抛错，不支持任何登录方式。
// 刻意只实现主协议，四个可选能力由 registry 解析为 nil。
public struct QQMusicProvider: MusicProvider {
    private let fallback = UnimplementedProvider()

    private let api: QQMusicAPI

    public init(api: QQMusicAPI = QQMusicAPI()) {
        self.api = api
    }

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
        throw QQMusicAPIError.loginRequired
    }

    public func songDetails(ids: [MusicID]) async throws -> [Track] {
        try await fallback.songDetails(ids: ids)
    }

    public func lyric(id: MusicID) async throws -> LyricResponse {
        guard case .source(_, .qq) = id else { throw QQMusicAPIError.invalidIdentifier }
        let lyrics = try await api.lyric(songMID: id.sourceID)
        func body(_ encoded: String?) -> LyricResponse.LyricBody? {
            guard let encoded, let data = Data(base64Encoded: encoded),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return .init(lyric: text)
        }
        return LyricResponse(lrc: body(lyrics.lyric), tlyric: body(lyrics.trans),
            romalrc: body(lyrics.roma), yrc: nil, ytlrc: nil, yromalrc: nil,
            lyricUser: nil, transUser: nil, nolyric: nil, uncollected: nil)
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
        throw QQMusicAPIError.searchUnavailable
    }

    public func searchSuggest(_ keywords: String) async throws -> SearchSuggestion {
        try await fallback.searchSuggest(keywords)
    }

    public func searchDefaultKeyword() async throws -> String? {
        try await api.hotkeys().first
    }

    // MARK: - MusicDiscovery

    public func toplists() async throws -> [Chart] {
        try await api.toplists().map {
            Chart(id: .source(id: String($0.topId), provider: .qq), name: $0.title ?? "",
                  coverURL: $0.picUrl.flatMap(URL.init(string:)),
                  updateFrequency: $0.updateTime, playCount: $0.listenNum ?? 0)
        }
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
        guard limit > 0 else { return [] }
        return try await api.recommendFeed(from: 0, size: limit).prefix(limit).map(PlaylistSummary.init(qq:))
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

// Keep the existing common model intact; QQ lacks the remaining NetEase metadata.
private extension PlaylistSummary {
    init(qq: QQMusicAPI.PlaylistBasic) {
        id = qq.tid
        name = qq.title ?? ""
        coverURL = qq.cover?.medium_url
        playCount = qq.play_cnt ?? 0
        trackCount = qq.song_cnt ?? 0
        copywriter = nil
        creator = nil
        specialType = 0
        privacy = 0
        subscribed = false
    }
}
