import Foundation
@testable import KumoneCore

/// Safe defaults for every capability; tests override only the calls they exercise.
struct MockMusicProvider: MusicProvider, MusicPlayHistory, MusicPersonalFM, MusicCloudStorage, MusicIntelligence {
    var isLoggedIn = false
    var supportedMethods: [LoginMethod] = [.qrCode]

    var personalizedPlaylistsHandler: @Sendable (Int) async throws -> [PlaylistSummary] = { _ in [] }
    var recommendResourceHandler: @Sendable () async throws -> [PlaylistSummary] = { [] }
    var newAlbumsHandler: @Sendable (String, Int, Int) async throws -> [AlbumSummary] = { _, _, _ in [] }
    var topArtistsHandler: @Sendable (Int) async throws -> [ArtistSummary] = { _ in [] }
    var dailyRecommendSongsHandler: @Sendable () async throws -> [Track] = { [] }
    var likedAlbumsHandler: @Sendable (Int, Int) async throws -> [AlbumSummary] = { _, _ in [] }
    var likedArtistsHandler: @Sendable (Int, Int) async throws -> [ArtistSummary] = { _, _ in [] }

    var playlistDetailHandler: @Sendable (MusicID) async throws -> PlaylistDetail = { _ in
        try JSONDecoder().decode(PlaylistDetail.self, from: Data(#"{"id":0}"#.utf8))
    }
    var songURLHandler: @Sendable ([MusicID], SongQuality) async throws -> [SongURLData] = { _, _ in [] }
    var songDetailsHandler: @Sendable ([MusicID]) async throws -> [Track] = { _ in [] }
    var lyricHandler: @Sendable (MusicID) async throws -> LyricResponse = { _ in
        LyricResponse(lrc: nil, tlyric: nil, romalrc: nil, yrc: nil, ytlrc: nil,
                      yromalrc: nil, lyricUser: nil, transUser: nil, nolyric: true, uncollected: nil)
    }
    var scrobbleStartHandler: @Sendable (MusicID, MusicID) async -> Void = { _, _ in }
    var scrobbleFinishHandler: @Sendable (MusicID, MusicID, Int) async -> Void = { _, _, _ in }
    var albumHandler: @Sendable (MusicID) async throws -> AlbumDetail = { _ in
        try JSONDecoder().decode(AlbumDetail.self, from: Data(#"{"id":0}"#.utf8))
    }
    var artistHandler: @Sendable (MusicID) async throws -> ArtistDetail = { _ in
        let artist = try JSONDecoder().decode(ArtistSummary.self, from: Data(#"{"id":0}"#.utf8))
        return ArtistDetail(artist: artist, hotSongs: [])
    }
    var highQualityPlaylistsHandler: @Sendable (String, Int, Int?) async throws -> HighQualityList = { _, _, _ in
        HighQualityList(playlists: [], lastTime: nil, hasMore: false)
    }
    var topPlaylistsHandler: @Sendable (String, String, Int, Int) async throws -> ChartList = { _, _, _, _ in
        ChartList(charts: [], total: 0, hasMore: false)
    }
    var toplistsHandler: @Sendable () async throws -> [Chart] = { [] }

    var logoutHandler: @Sendable () async -> Void = { }
    var refreshLoginHandler: @Sendable () async -> Void = { }
    var qrLoginURLHandler: @Sendable (String) -> URL = { unikey in
        URL(fileURLWithPath: "/")
    }
    var qrKeyHandler: @Sendable () async throws -> String = {
        ""
    }
    var qrCheckHandler: @Sendable (String) async throws -> LoginCheck = { unikey in
        LoginCheck(code: 800, message: nil, nickname: nil, avatar: nil)
    }
    var sendSMSCodeHandler: @Sendable (String, String) async throws -> Void = { phone, countryCode in }
    var loginCellphoneHandler: @Sendable (String, String, String) async throws -> Void = { phone, captcha, countryCode in }
    var userAccountHandler: @Sendable () async throws -> UserProfile = {
        try JSONDecoder().decode(UserProfile.self, from: Data(#"{"userId":0}"#.utf8))
    }
    var userPlaylistsHandler: @Sendable (MusicID, Int, Int) async throws -> [PlaylistSummary] = { uid, limit, offset in
        []
    }
    var likedTrackIDsHandler: @Sendable (MusicID) async throws -> [MusicID] = { uid in
        []
    }
    var likeTrackHandler: @Sendable (MusicID, Bool) async throws -> Void = { id, like in }
    var playlistBriefHandler: @Sendable (MusicID) async throws -> PlaylistBriefInfo = { id in
        PlaylistBriefInfo(id: id, name: "", coverURL: nil)
    }
    var createPlaylistHandler: @Sendable (String, Bool) async throws -> MusicID? = { name, isPrivate in
        nil
    }
    var deletePlaylistHandler: @Sendable (MusicID) async throws -> Void = { id in }
    var subscribePlaylistHandler: @Sendable (MusicID, Bool) async throws -> Void = { id, subscribe in }
    var playlistTracksHandler: @Sendable (PlaylistOp, MusicID, [MusicID]) async throws -> Void = { op, playlistID, trackIDs in }
    var similarSongsHandler: @Sendable (MusicID, Int) async throws -> [Track] = { id, limit in
        []
    }
    var searchHandler: @Sendable (String, SearchCategory, Int, Int) async throws -> SearchResult = { keywords, category, limit, offset in
        SearchResult()
    }
    var searchSuggestHandler: @Sendable (String) async throws -> SearchSuggestion = { keywords in
        SearchSuggestion(songs: [], artists: [], albums: [], playlists: [])
    }
    var searchDefaultKeywordHandler: @Sendable () async throws -> String? = {
        nil
    }
    var personalizedNewSongsHandler: @Sendable (Int) async throws -> [Track] = { limit in
        []
    }
    var dislikeRecommendedSongHandler: @Sendable (MusicID) async throws -> Track = { id in
        Track(id: 0, name: "", artists: [], album: AlbumRef(id: 0, name: "", picUrl: nil),
              durationMS: 0, alias: [], transNames: [], fee: 0, mvID: 0, trackNo: 0,
              disc: nil, noCopyright: false, isCloud: false, embeddedPrivilege: nil)
    }
    var albumDynamicHandler: @Sendable (MusicID) async throws -> AlbumDynamic = { id in
        AlbumDynamic(isSubscribed: false, subscriberCount: 0)
    }
    var subscribeAlbumHandler: @Sendable (MusicID, Bool) async throws -> Void = { id, subscribe in }
    var artistAlbumsHandler: @Sendable (MusicID, Int, Int) async throws -> ArtistAlbums = { id, limit, offset in
        ArtistAlbums(albums: [], hasMore: false)
    }
    var subscribeArtistHandler: @Sendable (MusicID, Bool) async throws -> Void = { id, subscribe in }
    var similarArtistsHandler: @Sendable (MusicID) async throws -> [ArtistSummary] = { id in
        []
    }

    func logout() async {
        await logoutHandler()
    }
    func refreshLogin() async {
        await refreshLoginHandler()
    }

    func qrLoginURL(_ unikey: String) -> URL {
        qrLoginURLHandler(unikey)
    }
    func qrKey() async throws -> String {
        try await qrKeyHandler()
    }
    func qrCheck(_ unikey: String) async throws -> LoginCheck {
        try await qrCheckHandler(unikey)
    }
    func sendSMSCode(phone: String, countryCode: String) async throws {
        try await sendSMSCodeHandler(phone, countryCode)
    }
    func loginCellphone(phone: String, captcha: String, countryCode: String) async throws {
        try await loginCellphoneHandler(phone, captcha, countryCode)
    }

    func userAccount() async throws -> UserProfile {
        try await userAccountHandler()
    }
    func userPlaylists(uid: MusicID, limit: Int, offset: Int) async throws -> [PlaylistSummary] {
        try await userPlaylistsHandler(uid, limit, offset)
    }
    func likedTrackIDs(uid: MusicID) async throws -> [MusicID] {
        try await likedTrackIDsHandler(uid)
    }
    func likeTrack(_ id: MusicID, like: Bool) async throws {
        try await likeTrackHandler(id, like)
    }
    func likedAlbums(limit: Int, offset: Int) async throws -> [AlbumSummary] {
        try await likedAlbumsHandler(limit, offset)
    }
    func likedArtists(limit: Int, offset: Int) async throws -> [ArtistSummary] {
        try await likedArtistsHandler(limit, offset)
    }

    func playlistDetail(id: MusicID) async throws -> PlaylistDetail {
        try await playlistDetailHandler(id)
    }
    func playlistBrief(id: MusicID) async throws -> PlaylistBriefInfo {
        try await playlistBriefHandler(id)
    }
    func createPlaylist(name: String, isPrivate: Bool) async throws -> MusicID? {
        try await createPlaylistHandler(name, isPrivate)
    }
    func deletePlaylist(_ id: MusicID) async throws {
        try await deletePlaylistHandler(id)
    }
    func subscribePlaylist(_ id: MusicID, subscribe: Bool) async throws {
        try await subscribePlaylistHandler(id, subscribe)
    }
    func playlistTracks(_ op: PlaylistOp, playlistID: MusicID, trackIDs: [MusicID]) async throws {
        try await playlistTracksHandler(op, playlistID, trackIDs)
    }

    func songURL(ids: [MusicID], quality: SongQuality) async throws -> [SongURLData] {
        try await songURLHandler(ids, quality)
    }
    func songDetails(ids: [MusicID]) async throws -> [Track] {
        try await songDetailsHandler(ids)
    }
    func lyric(id: MusicID) async throws -> LyricResponse {
        try await lyricHandler(id)
    }
    func scrobbleStart(trackID: MusicID, sourceID: MusicID) async {
        await scrobbleStartHandler(trackID, sourceID)
    }
    func scrobbleFinish(trackID: MusicID, sourceID: MusicID, seconds: Int) async {
        await scrobbleFinishHandler(trackID, sourceID, seconds)
    }
    func similarSongs(id: MusicID, limit: Int) async throws -> [Track] {
        try await similarSongsHandler(id, limit)
    }

    func search(_ keywords: String, category: SearchCategory, limit: Int, offset: Int) async throws -> SearchResult {
        try await searchHandler(keywords, category, limit, offset)
    }
    func searchSuggest(_ keywords: String) async throws -> SearchSuggestion {
        try await searchSuggestHandler(keywords)
    }
    func searchDefaultKeyword() async throws -> String? {
        try await searchDefaultKeywordHandler()
    }

    func toplists() async throws -> [Chart] {
        try await toplistsHandler()
    }
    func topArtists(limit: Int) async throws -> [ArtistSummary] {
        try await topArtistsHandler(limit)
    }
    func newAlbums(area: String, limit: Int, offset: Int) async throws -> [AlbumSummary] {
        try await newAlbumsHandler(area, limit, offset)
    }
    func personalizedNewSongs(limit: Int) async throws -> [Track] {
        try await personalizedNewSongsHandler(limit)
    }
    func dislikeRecommendedSong(_ id: MusicID) async throws -> Track {
        try await dislikeRecommendedSongHandler(id)
    }
    func personalizedPlaylists(limit: Int) async throws -> [PlaylistSummary] {
        try await personalizedPlaylistsHandler(limit)
    }
    func recommendResource() async throws -> [PlaylistSummary] {
        try await recommendResourceHandler()
    }
    func dailyRecommendSongs() async throws -> [Track] {
        try await dailyRecommendSongsHandler()
    }
    func topPlaylists(category: String, order: String, limit: Int, offset: Int) async throws -> ChartList {
        try await topPlaylistsHandler(category, order, limit, offset)
    }
    func highQualityPlaylists(category: String, limit: Int, before: Int?) async throws -> HighQualityList {
        try await highQualityPlaylistsHandler(category, limit, before)
    }

    func album(id: MusicID) async throws -> AlbumDetail {
        try await albumHandler(id)
    }
    func albumDynamic(id: MusicID) async throws -> AlbumDynamic {
        try await albumDynamicHandler(id)
    }
    func subscribeAlbum(_ id: MusicID, subscribe: Bool) async throws {
        try await subscribeAlbumHandler(id, subscribe)
    }

    func artist(id: MusicID) async throws -> ArtistDetail {
        try await artistHandler(id)
    }
    func artistAlbums(id: MusicID, limit: Int, offset: Int) async throws -> ArtistAlbums {
        try await artistAlbumsHandler(id, limit, offset)
    }
    func subscribeArtist(_ id: MusicID, subscribe: Bool) async throws {
        try await subscribeArtistHandler(id, subscribe)
    }
    func similarArtists(id: MusicID) async throws -> [ArtistSummary] {
        try await similarArtistsHandler(id)
    }

    var playRecordsHandler: @Sendable (MusicID, Bool) async throws -> [PlayRecord] = { _, _ in [] }
    var personalFMHandler: @Sendable () async throws -> [Track] = { [] }
    var fmTrashHandler: @Sendable (MusicID) async throws -> Void = { _ in }
    var cloudSongsHandler: @Sendable (Int, Int) async throws -> CloudStoragePage = { _, _ in
        CloudStoragePage(items: [], hasMore: false, usedBytes: 0, maxBytes: 0)
    }
    var cloudDeleteHandler: @Sendable (MusicID) async throws -> Void = { _ in }
    var intelligenceListHandler: @Sendable (MusicID, MusicID) async throws -> [Track] = { _, _ in [] }

    func playRecords(uid: MusicID, week: Bool) async throws -> [PlayRecord] {
        try await playRecordsHandler(uid, week)
    }
    func personalFM() async throws -> [Track] {
        try await personalFMHandler()
    }
    func fmTrash(_ id: MusicID) async throws {
        try await fmTrashHandler(id)
    }
    func cloudSongs(limit: Int, offset: Int) async throws -> CloudStoragePage {
        try await cloudSongsHandler(limit, offset)
    }
    func cloudDelete(_ id: MusicID) async throws {
        try await cloudDeleteHandler(id)
    }
    func intelligenceList(songID: MusicID, playlistID: MusicID) async throws -> [Track] {
        try await intelligenceListHandler(songID, playlistID)
    }
}

struct MockPersonalFM: MusicPersonalFM {
    var tracks: [Track] = []
    var isLoggedIn: Bool { true }

    func logout() async {}
    func refreshLogin() async {}
    func personalFM() async throws -> [Track] { tracks }
    var fmTrashHandler: @Sendable (MusicID) async throws -> Void = { _ in }
    func fmTrash(_ id: MusicID) async throws { try await fmTrashHandler(id) }
}

struct MockCloudStorage: MusicCloudStorage {
    var isLoggedIn = true
    var cloudSongsHandler: @Sendable (Int, Int) async throws -> CloudStoragePage = { _, _ in
        CloudStoragePage(items: [], hasMore: false, usedBytes: 0, maxBytes: 0)
    }
    func logout() async {}
    func refreshLogin() async {}
    func cloudSongs(limit: Int, offset: Int) async throws -> CloudStoragePage {
        try await cloudSongsHandler(limit, offset)
    }
    func cloudDelete(_ id: MusicID) async throws {}
}
