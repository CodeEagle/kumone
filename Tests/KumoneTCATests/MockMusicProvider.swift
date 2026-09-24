import Foundation
@testable import KumoneCore

/// Safe defaults for every common capability; tests override only the calls they exercise.
struct MockMusicProvider: MusicProvider {
    var isLoggedIn = false
    var supportedMethods: [LoginMethod] = []

    var personalizedPlaylistsHandler: @Sendable (Int) async throws -> [PlaylistSummary] = { _ in [] }
    var recommendResourceHandler: @Sendable () async throws -> [PlaylistSummary] = { [] }
    var newAlbumsHandler: @Sendable (String, Int, Int) async throws -> [AlbumSummary] = { _, _, _ in [] }
    var topArtistsHandler: @Sendable (Int) async throws -> [ArtistSummary] = { _ in [] }
    var dailyRecommendSongsHandler: @Sendable () async throws -> [Track] = { [] }
    var likedAlbumsHandler: @Sendable (Int, Int) async throws -> [AlbumSummary] = { _, _ in [] }
    var likedArtistsHandler: @Sendable (Int, Int) async throws -> [ArtistSummary] = { _, _ in [] }

    func logout() async {}
    func refreshLogin() async {}

    func qrLoginURL(_ unikey: String) -> URL { URL(fileURLWithPath: "/") }
    func qrKey() async throws -> String { "" }
    func qrCheck(_ unikey: String) async throws -> LoginCheck {
        LoginCheck(code: 800, message: nil, nickname: nil, avatar: nil)
    }
    func sendSMSCode(phone: String, countryCode: String) async throws {}
    func loginCellphone(phone: String, captcha: String, countryCode: String) async throws {}

    // These Decodable models have no memberwise initializer. Decode minimal,
    // valid empty fixtures without force-try, so decoding can never trap.
    func userAccount() async throws -> UserProfile {
        try JSONDecoder().decode(UserProfile.self, from: Data(#"{"userId":0}"#.utf8))
    }
    func userPlaylists(uid: MusicID, limit: Int, offset: Int) async throws -> [PlaylistSummary] { [] }
    func likedTrackIDs(uid: MusicID) async throws -> [MusicID] { [] }
    func likeTrack(_ id: MusicID, like: Bool) async throws {}
    func likedAlbums(limit: Int, offset: Int) async throws -> [AlbumSummary] {
        try await likedAlbumsHandler(limit, offset)
    }
    func likedArtists(limit: Int, offset: Int) async throws -> [ArtistSummary] {
        try await likedArtistsHandler(limit, offset)
    }

    func playlistDetail(id: MusicID) async throws -> PlaylistDetail {
        try JSONDecoder().decode(PlaylistDetail.self, from: Data(#"{"id":0}"#.utf8))
    }
    func playlistBrief(id: MusicID) async throws -> PlaylistBriefInfo {
        PlaylistBriefInfo(id: id, name: "", coverURL: nil)
    }
    func createPlaylist(name: String, isPrivate: Bool) async throws -> MusicID? { nil }
    func deletePlaylist(_ id: MusicID) async throws {}
    func subscribePlaylist(_ id: MusicID, subscribe: Bool) async throws {}
    func playlistTracks(_ op: PlaylistOp, playlistID: MusicID, trackIDs: [MusicID]) async throws {}

    func songURL(ids: [MusicID], quality: SongQuality) async throws -> [SongURLData] { [] }
    func songDetails(ids: [MusicID]) async throws -> [Track] { [] }
    func lyric(id: MusicID) async throws -> LyricResponse {
        LyricResponse(lrc: nil, tlyric: nil, romalrc: nil, yrc: nil, ytlrc: nil,
                      yromalrc: nil, lyricUser: nil, transUser: nil, nolyric: true, uncollected: nil)
    }
    func scrobbleStart(trackID: MusicID, sourceID: MusicID) async {}
    func scrobbleFinish(trackID: MusicID, sourceID: MusicID, seconds: Int) async {}
    func similarSongs(id: MusicID, limit: Int) async throws -> [Track] { [] }

    func search(_ keywords: String, category: SearchCategory, limit: Int, offset: Int) async throws -> SearchResult {
        SearchResult()
    }
    func searchSuggest(_ keywords: String) async throws -> SearchSuggestion {
        SearchSuggestion(songs: [], artists: [], albums: [], playlists: [])
    }
    func searchDefaultKeyword() async throws -> String? { nil }

    func toplists() async throws -> [Chart] { [] }
    func topArtists(limit: Int) async throws -> [ArtistSummary] {
        try await topArtistsHandler(limit)
    }
    func newAlbums(area: String, limit: Int, offset: Int) async throws -> [AlbumSummary] {
        try await newAlbumsHandler(area, limit, offset)
    }
    func personalizedNewSongs(limit: Int) async throws -> [Track] { [] }
    func dislikeRecommendedSong(_ id: MusicID) async throws -> Track {
        Track(id: 0, name: "", artists: [], album: AlbumRef(id: 0, name: "", picUrl: nil),
              durationMS: 0, alias: [], transNames: [], fee: 0, mvID: 0, trackNo: 0,
              disc: nil, noCopyright: false, isCloud: false, embeddedPrivilege: nil)
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
        ChartList(charts: [], total: 0, hasMore: false)
    }
    func highQualityPlaylists(category: String, limit: Int, before: Int?) async throws -> HighQualityList {
        HighQualityList(playlists: [], lastTime: nil, hasMore: false)
    }

    func album(id: MusicID) async throws -> AlbumDetail {
        try JSONDecoder().decode(AlbumDetail.self, from: Data(#"{"id":0}"#.utf8))
    }
    func albumDynamic(id: MusicID) async throws -> AlbumDynamic {
        AlbumDynamic(isSubscribed: false, subscriberCount: 0)
    }
    func subscribeAlbum(_ id: MusicID, subscribe: Bool) async throws {}

    func artist(id: MusicID) async throws -> ArtistDetail {
        let artist = try JSONDecoder().decode(ArtistSummary.self, from: Data(#"{"id":0}"#.utf8))
        return ArtistDetail(artist: artist, hotSongs: [])
    }
    func artistAlbums(id: MusicID, limit: Int, offset: Int) async throws -> ArtistAlbums {
        ArtistAlbums(albums: [], hasMore: false)
    }
    func subscribeArtist(_ id: MusicID, subscribe: Bool) async throws {}
    func similarArtists(id: MusicID) async throws -> [ArtistSummary] { [] }
}

struct MockPersonalFM: MusicPersonalFM {
    var tracks: [Track] = []
    var isLoggedIn: Bool { true }

    func logout() async {}
    func refreshLogin() async {}
    func personalFM() async throws -> [Track] { tracks }
    func fmTrash(_ id: MusicID) async throws {}
}
