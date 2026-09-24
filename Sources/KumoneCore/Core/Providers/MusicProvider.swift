import Foundation

// Sources/Kumone/Core/Providers/MusicProvider.swift
//
// Capability protocols for the abstracted music provider. Method signatures are
// the source-agnostic contract; NetEase remains the only implementation for now
// (Phase 1) but the shape is what a QQ/Kuwo source would conform to as well.
//
// Access level: everything here is internal on purpose. The models these
// protocols reference (Track, PlaylistSummary, … in Core/Models) are internal,
// and a `public` declaration referencing an internal type is a hard error in
// Swift. Same-target compilation needs no `public`; the raise happens when the
// multi-target split lands (清单序号 13).

/// 所有音乐 provider 必须实现的认证最小集。
public protocol MusicAuth: Sendable {
    /// 当前是否已登录（抽象掉 cookie/token 的差异）。
    var isLoggedIn: Bool { get }

    /// 登出。
    func logout() async

    /// 刷新登录态。
    func refreshLogin() async
}

/// 歌单曲目增删改的操作类型。
///
/// Declared at file scope rather than inside `MusicPlaylist` because Swift does
/// not allow a concrete enum declaration inside a protocol body; protocols may
/// only *require* nested types, not define them.
public enum PlaylistOp: String, Sendable {
    case add, delete, update
}

/// 登录方式由各 provider 自行暴露；不放进主协议，避免 Feature 假设扫码存在。
public enum LoginMethod: Sendable {
    /// QR 图片 URL 由 provider 的 `qrLoginURL(_:)` 提供（见 MusicLogin），故本 case 不带闭包。
    case qrCode
    case smsPhone(countryCode: String)
    case oauth2(authorizationURL: URL)
}

public protocol MusicLibrary: MusicAuth {
    func userAccount() async throws -> UserProfile
    func userPlaylists(uid: MusicID, limit: Int, offset: Int) async throws -> [PlaylistSummary]
    func likedTrackIDs(uid: MusicID) async throws -> [MusicID]
    func likeTrack(_ id: MusicID, like: Bool) async throws
    func likedAlbums(limit: Int, offset: Int) async throws -> [AlbumSummary]
    func likedArtists(limit: Int, offset: Int) async throws -> [ArtistSummary]
}

public protocol MusicPlaylist: MusicAuth {
    func playlistDetail(id: MusicID) async throws -> PlaylistDetail
    func playlistBrief(id: MusicID) async throws -> PlaylistBriefInfo
    func createPlaylist(name: String, isPrivate: Bool) async throws -> MusicID?
    func deletePlaylist(_ id: MusicID) async throws
    func subscribePlaylist(_ id: MusicID, subscribe: Bool) async throws
    func playlistTracks(_ op: PlaylistOp, playlistID: MusicID, trackIDs: [MusicID]) async throws
}

public protocol MusicPlayback: MusicAuth {
    func songURL(ids: [MusicID], quality: SongQuality) async throws -> [SongURLData]
    func songDetails(ids: [MusicID]) async throws -> [Track]
    func lyric(id: MusicID) async throws -> LyricResponse
    func scrobbleStart(trackID: MusicID, sourceID: MusicID) async
    func scrobbleFinish(trackID: MusicID, sourceID: MusicID, seconds: Int) async
    func similarSongs(id: MusicID, limit: Int) async throws -> [Track]
}

public protocol MusicSearch: MusicAuth {
    func search(_ keywords: String, category: SearchCategory, limit: Int, offset: Int) async throws -> SearchResult
    func searchSuggest(_ keywords: String) async throws -> SearchSuggestion
    func searchDefaultKeyword() async throws -> String?
}

public protocol MusicDiscovery: MusicAuth {
    /// `songDetails` 归属 `MusicPlayback`（T4 修订：删除此处重复声明，避免两协议同名方法歧义）。
    func toplists() async throws -> [Chart]
    func topArtists(limit: Int) async throws -> [ArtistSummary]
    func newAlbums(area: String, limit: Int, offset: Int) async throws -> [AlbumSummary]
    func personalizedNewSongs(limit: Int) async throws -> [Track]
    func dislikeRecommendedSong(_ id: MusicID) async throws -> Track
    func personalizedPlaylists(limit: Int) async throws -> [PlaylistSummary]
    func recommendResource() async throws -> [PlaylistSummary]
    func dailyRecommendSongs() async throws -> [Track]
    func topPlaylists(category: String, order: String, limit: Int, offset: Int) async throws -> ChartList
    func highQualityPlaylists(category: String, limit: Int, before: Int?) async throws -> HighQualityList
}

public protocol MusicAlbum: MusicAuth {
    func album(id: MusicID) async throws -> AlbumDetail
    func albumDynamic(id: MusicID) async throws -> AlbumDynamic
    func subscribeAlbum(_ id: MusicID, subscribe: Bool) async throws
}

public protocol MusicArtist: MusicAuth {
    func artist(id: MusicID) async throws -> ArtistDetail
    func artistAlbums(id: MusicID, limit: Int, offset: Int) async throws -> ArtistAlbums
    func subscribeArtist(_ id: MusicID, subscribe: Bool) async throws
    func similarArtists(id: MusicID) async throws -> [ArtistSummary]
}

// MARK: - Optional capabilities (NetEase-specific)

public protocol MusicPlayHistory: MusicAuth {
    func playRecords(uid: MusicID, week: Bool) async throws -> [PlayRecord]
}

public protocol MusicPersonalFM: MusicAuth {
    func personalFM() async throws -> [Track]
    func fmTrash(_ id: MusicID) async throws
}

public protocol MusicCloudStorage: MusicAuth {
    func cloudSongs(limit: Int, offset: Int) async throws -> CloudStoragePage
    func cloudDelete(_ id: MusicID) async throws
}

public protocol MusicIntelligence: MusicAuth {
    func intelligenceList(songID: MusicID, playlistID: MusicID) async throws -> [Track]
}

public protocol MusicLogin: MusicAuth {
    var supportedMethods: [LoginMethod] { get }
    /// The QR image payload for a unikey (pure: no network).
    func qrLoginURL(_ unikey: String) -> URL
    func qrKey() async throws -> String                // 仅当 supportedMethods 含 .qrCode
    func qrCheck(_ unikey: String) async throws -> LoginCheck
    func sendSMSCode(phone: String, countryCode: String) async throws
    func loginCellphone(phone: String, captcha: String, countryCode: String) async throws
}

// MARK: - Composite

/// 主协议：只继承**通用**能力（8 个域）。Feature 层用单一 @Dependency(\.musicProvider)。
/// NetEase 特有的 optional 能力（PlayHistory/PersonalFM/CloudStorage/Intelligence）
/// **不放进主协议**——由各源 provider 按需组合（见下方 NetEaseProvider），
/// Feature 通过可选子 key（@Dependency(\.personalFM) var fm: any MusicPersonalFM?）
/// 声明"用了就要求实现"，不实现时 UI 隐藏入口。这样 QQ 音乐可以只实现 MusicProvider
/// 而不被迫实现云盘/私人电台（与 §2.3、§3.6、§5.2 表述一致）。
public protocol MusicProvider: MusicLogin, MusicLibrary, MusicPlaylist, MusicPlayback,
                        MusicSearch, MusicDiscovery, MusicAlbum, MusicArtist {}

/// NetEase 源组合：通用能力 + 4 个特有 optional 能力。
public protocol NetEaseProvider: MusicProvider, MusicPlayHistory, MusicPersonalFM,
                         MusicCloudStorage, MusicIntelligence {}
