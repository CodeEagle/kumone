import Foundation

/// 音乐源尚未接入的能力域。
public enum UnimplementedProviderError: Error, LocalizedError {
    case auth
    case login
    case library
    case playlist
    case playback
    case search
    case discovery
    case album
    case artist
    case playHistory
    case personalFM
    case cloudStorage
    case intelligence

    public var errorDescription: String? {
        switch self {
        case .auth: return String(localized: "该源未实现认证能力域")
        case .login: return String(localized: "该源未实现登录能力域")
        case .library: return String(localized: "该源未实现音乐库能力域")
        case .playlist: return String(localized: "该源未实现歌单能力域")
        case .playback: return String(localized: "该源未实现播放能力域")
        case .search: return String(localized: "该源未实现搜索能力域")
        case .discovery: return String(localized: "该源未实现发现能力域")
        case .album: return String(localized: "该源未实现专辑能力域")
        case .artist: return String(localized: "该源未实现歌手能力域")
        case .playHistory: return String(localized: "该源未实现播放记录能力域")
        case .personalFM: return String(localized: "该源未实现私人电台能力域")
        case .cloudStorage: return String(localized: "该源未实现云盘能力域")
        case .intelligence: return String(localized: "该源未实现心动模式能力域")
        }
    }
}

/// 未注册或尚未接入的源使用的哨兵；不声明任何可选能力。
public struct UnimplementedProvider: MusicProvider {
    public init() {}

    public var isLoggedIn: Bool { false }
    public var supportedMethods: [LoginMethod] { [] }

    // MARK: - MusicAuth

    // 协议的非 throwing 方法无法报告错误；无会话、无上报，安全空操作。

    public func logout() async {}

    public func refreshLogin() async {}

    // MARK: - MusicLogin

    public func qrLoginURL(_ unikey: String) -> URL {
        URL(string: "about:blank")!
    }

    public func qrKey() async throws -> String {
        throw UnimplementedProviderError.login
    }

    public func qrCheck(_ unikey: String) async throws -> LoginCheck {
        throw UnimplementedProviderError.login
    }

    public func sendSMSCode(phone: String, countryCode: String) async throws {
        throw UnimplementedProviderError.login
    }

    public func loginCellphone(phone: String, captcha: String, countryCode: String) async throws {
        throw UnimplementedProviderError.login
    }

    // MARK: - MusicLibrary

    public func userAccount() async throws -> UserProfile {
        throw UnimplementedProviderError.library
    }

    public func userPlaylists(uid: MusicID, limit: Int, offset: Int) async throws -> [PlaylistSummary] {
        throw UnimplementedProviderError.library
    }

    public func likedTrackIDs(uid: MusicID) async throws -> [MusicID] {
        throw UnimplementedProviderError.library
    }

    public func likeTrack(_ id: MusicID, like: Bool) async throws {
        throw UnimplementedProviderError.library
    }

    public func likedAlbums(limit: Int, offset: Int) async throws -> [AlbumSummary] {
        throw UnimplementedProviderError.library
    }

    public func likedArtists(limit: Int, offset: Int) async throws -> [ArtistSummary] {
        throw UnimplementedProviderError.library
    }

    // MARK: - MusicPlaylist

    public func playlistDetail(id: MusicID) async throws -> PlaylistDetail {
        throw UnimplementedProviderError.playlist
    }

    public func playlistBrief(id: MusicID) async throws -> PlaylistBriefInfo {
        throw UnimplementedProviderError.playlist
    }

    public func createPlaylist(name: String, isPrivate: Bool) async throws -> MusicID? {
        throw UnimplementedProviderError.playlist
    }

    public func deletePlaylist(_ id: MusicID) async throws {
        throw UnimplementedProviderError.playlist
    }

    public func subscribePlaylist(_ id: MusicID, subscribe: Bool) async throws {
        throw UnimplementedProviderError.playlist
    }

    public func playlistTracks(_ op: PlaylistOp, playlistID: MusicID, trackIDs: [MusicID]) async throws {
        throw UnimplementedProviderError.playlist
    }

    // MARK: - MusicPlayback

    // 协议的非 throwing 方法无法报告错误；无会话、无上报，安全空操作。

    public func songURL(ids: [MusicID], quality: SongQuality) async throws -> [SongURLData] {
        throw UnimplementedProviderError.playback
    }

    public func songDetails(ids: [MusicID]) async throws -> [Track] {
        throw UnimplementedProviderError.playback
    }

    public func lyric(id: MusicID) async throws -> LyricResponse {
        throw UnimplementedProviderError.playback
    }

    public func scrobbleStart(trackID: MusicID, sourceID: MusicID) async {}

    public func scrobbleFinish(trackID: MusicID, sourceID: MusicID, seconds: Int) async {}

    public func similarSongs(id: MusicID, limit: Int) async throws -> [Track] {
        throw UnimplementedProviderError.playback
    }

    // MARK: - MusicSearch

    public func search(_ keywords: String, category: SearchCategory, limit: Int, offset: Int) async throws -> SearchResult {
        throw UnimplementedProviderError.search
    }

    public func searchSuggest(_ keywords: String) async throws -> SearchSuggestion {
        throw UnimplementedProviderError.search
    }

    public func searchDefaultKeyword() async throws -> String? {
        throw UnimplementedProviderError.search
    }

    // MARK: - MusicDiscovery

    public func toplists() async throws -> [Chart] {
        throw UnimplementedProviderError.discovery
    }

    public func topArtists(limit: Int) async throws -> [ArtistSummary] {
        throw UnimplementedProviderError.discovery
    }

    public func newAlbums(area: String, limit: Int, offset: Int) async throws -> [AlbumSummary] {
        throw UnimplementedProviderError.discovery
    }

    public func personalizedNewSongs(limit: Int) async throws -> [Track] {
        throw UnimplementedProviderError.discovery
    }

    public func dislikeRecommendedSong(_ id: MusicID) async throws -> Track {
        throw UnimplementedProviderError.discovery
    }

    public func personalizedPlaylists(limit: Int) async throws -> [PlaylistSummary] {
        throw UnimplementedProviderError.discovery
    }

    public func recommendResource() async throws -> [PlaylistSummary] {
        throw UnimplementedProviderError.discovery
    }

    public func dailyRecommendSongs() async throws -> [Track] {
        throw UnimplementedProviderError.discovery
    }

    public func topPlaylists(category: String, order: String, limit: Int, offset: Int) async throws -> ChartList {
        throw UnimplementedProviderError.discovery
    }

    public func highQualityPlaylists(category: String, limit: Int, before: Int?) async throws -> HighQualityList {
        throw UnimplementedProviderError.discovery
    }

    // MARK: - MusicAlbum

    public func album(id: MusicID) async throws -> AlbumDetail {
        throw UnimplementedProviderError.album
    }

    public func albumDynamic(id: MusicID) async throws -> AlbumDynamic {
        throw UnimplementedProviderError.album
    }

    public func subscribeAlbum(_ id: MusicID, subscribe: Bool) async throws {
        throw UnimplementedProviderError.album
    }

    // MARK: - MusicArtist

    public func artist(id: MusicID) async throws -> ArtistDetail {
        throw UnimplementedProviderError.artist
    }

    public func artistAlbums(id: MusicID, limit: Int, offset: Int) async throws -> ArtistAlbums {
        throw UnimplementedProviderError.artist
    }

    public func subscribeArtist(_ id: MusicID, subscribe: Bool) async throws {
        throw UnimplementedProviderError.artist
    }

    public func similarArtists(id: MusicID) async throws -> [ArtistSummary] {
        throw UnimplementedProviderError.artist
    }
}
