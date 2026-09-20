import ComposableArchitecture
import Foundation

/// The NetEase Cloud Music API, as a dependency.
///
/// This is a thin `@DependencyClient` facade over the existing `NeteaseAPI`
/// surface (which owns the weapi/eapi crypto, the cookie jar, and decoding).
/// Reducers talk to this client so that every network hop is injectable and
/// exhaustively testable; the live implementation simply forwards.
@DependencyClient
struct NeteaseMusicClient {
    // MARK: - Auth

    var qrKey: @Sendable () async throws -> String
    /// The QR image payload for a unikey (pure: no network).
    var qrLoginURL: @Sendable (_ unikey: String) -> String = { _ in "" }
    var qrCheck: @Sendable (_ unikey: String) async throws -> NeteaseAPI.QRCheckResponse
    var sendSMSCode: @Sendable (_ phone: String, _ countryCode: String) async throws -> Void
    var loginCellphone: @Sendable (_ phone: String, _ captcha: String, _ countryCode: String) async throws -> Void
    var logout: @Sendable () async -> Void
    var refreshLogin: @Sendable () async -> Void

    // MARK: - Account & library

    var userAccount: @Sendable () async throws -> UserProfile?
    var userPlaylists: @Sendable (_ uid: Int, _ limit: Int, _ offset: Int) async throws -> [PlaylistSummary]
    var likedTrackIDs: @Sendable (_ uid: Int) async throws -> [Int]
    var likeTrack: @Sendable (_ id: Int, _ like: Bool) async throws -> Void
    var likedAlbums: @Sendable (_ limit: Int, _ offset: Int) async throws -> [AlbumSummary]
    var likedArtists: @Sendable (_ limit: Int, _ offset: Int) async throws -> [ArtistSummary]
    var playRecords: @Sendable (_ uid: Int, _ week: Bool) async throws -> [PlayRecordItem]

    // MARK: - Cloud disk

    var cloudSongs: @Sendable (_ limit: Int, _ offset: Int) async throws -> NeteaseAPI.CloudResponse
    var cloudDelete: @Sendable (_ id: Int) async throws -> Void

    // MARK: - Discovery

    var personalizedPlaylists: @Sendable (_ limit: Int) async throws -> [PlaylistSummary]
    var recommendResource: @Sendable () async throws -> [PlaylistSummary]
    var dailyRecommendSongs: @Sendable () async throws -> [Track]
    var dislikeRecommendedSong: @Sendable (_ id: Int) async throws -> Track
    var toplists: @Sendable () async throws -> [ToplistItem]
    var topPlaylists: @Sendable (_ category: String, _ order: String, _ limit: Int, _ offset: Int) async throws -> NeteaseAPI.TopPlaylistResponse
    var highQualityPlaylists: @Sendable (_ category: String, _ limit: Int, _ before: Int) async throws -> NeteaseAPI.HighQualityResponse
    var newAlbums: @Sendable (_ area: String, _ limit: Int, _ offset: Int) async throws -> [AlbumSummary]
    var topArtists: @Sendable (_ limit: Int) async throws -> [ArtistSummary]
    var personalizedNewSongs: @Sendable (_ limit: Int) async throws -> [Track]
    var searchSuggest: @Sendable (_ keywords: String) async throws -> NeteaseAPI.SearchSuggestResponse.Body?
    var searchDefaultKeyword: @Sendable () async throws -> String?

    // MARK: - Playback support

    var songURL: @Sendable (_ ids: [Int], _ level: String) async throws -> [SongURLData]
    var lyric: @Sendable (_ id: Int) async throws -> LyricResponse
    var personalFM: @Sendable () async throws -> [Track]
    var fmTrash: @Sendable (_ id: Int) async throws -> Void
    var scrobbleStart: @Sendable (_ trackID: Int, _ sourceID: Int) async -> Void
    var scrobbleFinish: @Sendable (_ trackID: Int, _ sourceID: Int, _ seconds: Int) async -> Void
    var intelligenceList: @Sendable (_ songID: Int, _ playlistID: Int) async throws -> [Track]
    var similarSongs: @Sendable (_ id: Int, _ limit: Int) async throws -> [Track]

    // MARK: - Detail pages

    var playlistDetail: @Sendable (_ id: Int) async throws -> NeteaseAPI.PlaylistDetailResponse
    var playlistBrief: @Sendable (_ id: Int) async throws -> NeteaseAPI.PlaylistBrief.Body
    var songDetails: @Sendable (_ ids: [Int]) async throws -> NeteaseAPI.SongDetailResponse
    var album: @Sendable (_ id: Int) async throws -> AlbumDetailResponse
    var albumDynamic: @Sendable (_ id: Int) async throws -> NeteaseAPI.AlbumDynamicResponse
    var subscribeAlbum: @Sendable (_ id: Int, _ subscribe: Bool) async throws -> Void
    var artist: @Sendable (_ id: Int) async throws -> NeteaseAPI.ArtistResponse
    var artistAlbums: @Sendable (_ id: Int, _ limit: Int, _ offset: Int) async throws -> NeteaseAPI.ArtistAlbumsResponse
    var subscribeArtist: @Sendable (_ id: Int, _ subscribe: Bool) async throws -> Void
    var similarArtists: @Sendable (_ id: Int) async throws -> [ArtistSummary]

    // MARK: - Library management

    var createPlaylist: @Sendable (_ name: String, _ isPrivate: Bool) async throws -> Int?
    var deletePlaylist: @Sendable (_ id: Int) async throws -> Void
    var subscribePlaylist: @Sendable (_ id: Int, _ subscribe: Bool) async throws -> Void
    var playlistTracks: @Sendable (_ op: String, _ playlistID: Int, _ trackIDs: [Int]) async throws -> Void

    // MARK: - Search

    var search: @Sendable (_ keywords: String, _ type: NeteaseAPI.SearchType, _ limit: Int, _ offset: Int) async throws -> NeteaseAPI.SearchResult
}

extension NeteaseMusicClient: DependencyKey {
    static let liveValue = NeteaseMusicClient(
        qrKey: { try await NeteaseAPI.qrKey() },
        qrLoginURL: { NeteaseAPI.qrLoginURL(unikey: $0) },
        qrCheck: { try await NeteaseAPI.qrCheck(unikey: $0) },
        sendSMSCode: { try await NeteaseAPI.sendSMSCode(phone: $0, countryCode: $1) },
        loginCellphone: { try await NeteaseAPI.loginCellphone(phone: $0, captcha: $1, countryCode: $2) },
        logout: { await NeteaseAPI.logout() },
        refreshLogin: { await NeteaseAPI.refreshLogin() },

        userAccount: { try await NeteaseAPI.userAccount() },
        userPlaylists: { try await NeteaseAPI.userPlaylists(uid: $0, limit: $1, offset: $2) },
        likedTrackIDs: { try await NeteaseAPI.likedTrackIDs(uid: $0) },
        likeTrack: { try await NeteaseAPI.likeTrack(id: $0, like: $1) },
        likedAlbums: { try await NeteaseAPI.likedAlbums(limit: $0, offset: $1) },
        likedArtists: { try await NeteaseAPI.likedArtists(limit: $0, offset: $1) },
        playRecords: { try await NeteaseAPI.playRecords(uid: $0, week: $1) },

        cloudSongs: { try await NeteaseAPI.cloudSongs(limit: $0, offset: $1) },
        cloudDelete: { try await NeteaseAPI.cloudDelete(id: $0) },

        personalizedPlaylists: { try await NeteaseAPI.personalizedPlaylists(limit: $0) },
        recommendResource: { try await NeteaseAPI.recommendResource() },
        dailyRecommendSongs: { try await NeteaseAPI.dailyRecommendSongs() },
        dislikeRecommendedSong: { try await NeteaseAPI.dislikeRecommendedSong(id: $0) },
        toplists: { try await NeteaseAPI.toplists() },
        topPlaylists: { try await NeteaseAPI.topPlaylists(category: $0, order: $1, limit: $2, offset: $3) },
        highQualityPlaylists: { try await NeteaseAPI.highQualityPlaylists(category: $0, limit: $1, before: $2) },
        newAlbums: { try await NeteaseAPI.newAlbums(area: $0, limit: $1, offset: $2) },
        topArtists: { try await NeteaseAPI.topArtists(limit: $0) },
        personalizedNewSongs: { try await NeteaseAPI.personalizedNewSongs(limit: $0) },
        searchSuggest: { try await NeteaseAPI.searchSuggest($0) },
        searchDefaultKeyword: { try await NeteaseAPI.searchDefaultKeyword() },

        songURL: { try await NeteaseAPI.songURL(ids: $0, level: $1) },
        lyric: { try await NeteaseAPI.lyric(id: $0) },
        personalFM: { try await NeteaseAPI.personalFM() },
        fmTrash: { try await NeteaseAPI.fmTrash(id: $0) },
        scrobbleStart: { await NeteaseAPI.scrobbleStart(trackID: $0, sourceID: $1) },
        scrobbleFinish: { await NeteaseAPI.scrobbleFinish(trackID: $0, sourceID: $1, seconds: $2) },
        intelligenceList: { try await NeteaseAPI.intelligenceList(songID: $0, playlistID: $1) },
        similarSongs: { try await NeteaseAPI.similarSongs(id: $0, limit: $1) },

        playlistDetail: { try await NeteaseAPI.playlistDetail(id: $0) },
        playlistBrief: { try await NeteaseAPI.playlistBrief(id: $0) },
        songDetails: { try await NeteaseAPI.songDetails(ids: $0) },
        album: { try await NeteaseAPI.album(id: $0) },
        albumDynamic: { try await NeteaseAPI.albumDynamic(id: $0) },
        subscribeAlbum: { try await NeteaseAPI.subscribeAlbum(id: $0, subscribe: $1) },
        artist: { try await NeteaseAPI.artist(id: $0) },
        artistAlbums: { try await NeteaseAPI.artistAlbums(id: $0, limit: $1, offset: $2) },
        subscribeArtist: { try await NeteaseAPI.subscribeArtist(id: $0, subscribe: $1) },
        similarArtists: { try await NeteaseAPI.similarArtists(id: $0) },

        createPlaylist: { try await NeteaseAPI.createPlaylist(name: $0, isPrivate: $1) },
        deletePlaylist: { try await NeteaseAPI.deletePlaylist(id: $0) },
        subscribePlaylist: { try await NeteaseAPI.subscribePlaylist(id: $0, subscribe: $1) },
        playlistTracks: { try await NeteaseAPI.playlistTracks(op: $0, playlistID: $1, trackIDs: $2) },

        search: { try await NeteaseAPI.search($0, type: $1, limit: $2, offset: $3) }
    )
}

extension DependencyValues {
    var netease: NeteaseMusicClient {
        get { self[NeteaseMusicClient.self] }
        set { self[NeteaseMusicClient.self] = newValue }
    }
}
