import Foundation

// Sources/Kumone/Core/Providers/NetEaseMusicProvider+Discovery.swift
//
// NetEase 源 provider 的 MusicDiscovery + MusicAlbum + MusicArtist 三个能力域
// （Phase 1 / P1-d）。主定义见 NetEaseMusicProvider.swift（P1-a，仅 MusicAuth +
// MusicLogin）；Library/Playlist 见 +Library（P1-b），Playback/Search 见 +Playback
// （P1-c）。本文件只实现这三个域，不触碰其它域。
//
// Access level: internal（与主定义一致；public 引用 internal 模型是 hard error，
// 同 target 亦无需 public）。

extension NetEaseMusicProvider: MusicDiscovery, MusicAlbum, MusicArtist {

    // MARK: - MusicDiscovery

    public func toplists() async throws -> [Chart] {
        // ToplistItem{...tracks} → Chart：丢弃 tracks 预览，通用模型按需拉取曲目。
        try await NeteaseAPI.toplists().map(chart(fromToplist:))
    }

    public func topArtists(limit: Int) async throws -> [ArtistSummary] {
        try await NeteaseAPI.topArtists(limit: limit)
    }

    public func newAlbums(area: String, limit: Int, offset: Int) async throws -> [AlbumSummary] {
        try await NeteaseAPI.newAlbums(area: area, limit: limit, offset: offset)
    }

    public func personalizedNewSongs(limit: Int) async throws -> [Track] {
        try await NeteaseAPI.personalizedNewSongs(limit: limit)
    }

    public func dislikeRecommendedSong(_ id: MusicID) async throws -> Track {
        try await NeteaseAPI.dislikeRecommendedSong(id: neteaseID(id))
    }

    public func personalizedPlaylists(limit: Int) async throws -> [PlaylistSummary] {
        try await NeteaseAPI.personalizedPlaylists(limit: limit)
    }

    public func recommendResource() async throws -> [PlaylistSummary] {
        try await NeteaseAPI.recommendResource()
    }

    public func dailyRecommendSongs() async throws -> [Track] {
        try await NeteaseAPI.dailyRecommendSongs()
    }

    public func topPlaylists(category: String, order: String, limit: Int, offset: Int) async throws -> ChartList {
        // TopPlaylistResponse{ playlists: [PlaylistSummary], total?, more? }
        // → ChartList：playlists 项映射为 Chart（PlaylistSummary 无 updateFrequency）。
        let resp = try await NeteaseAPI.topPlaylists(category: category, order: order,
                                                     limit: limit, offset: offset)
        return ChartList(
            charts: resp.playlists.map(chart(fromPlaylist:)),
            total: resp.total ?? 0,
            hasMore: resp.more ?? false
        )
    }

    public func highQualityPlaylists(category: String, limit: Int, before: Int?) async throws -> HighQualityList {
        // HighQualityResponse{ playlists, lasttime?, more? } → HighQualityList；
        // before 即分页游标 lasttime（毫秒时间戳），nil 表示从最新一页开始。
        let resp = try await NeteaseAPI.highQualityPlaylists(category: category, limit: limit,
                                                             before: before ?? 0)
        return HighQualityList(
            playlists: resp.playlists,
            lastTime: resp.lasttime,
            hasMore: resp.more ?? false
        )
    }

    // MARK: - MusicAlbum

    public func album(id: MusicID) async throws -> AlbumDetail {
        // AlbumDetailResponse{ album, songs } → 直接取 album（Models 层已归一化字段）。
        try await NeteaseAPI.album(id: neteaseID(id)).album
    }

    public func albumDynamic(id: MusicID) async throws -> AlbumDynamic {
        // AlbumDynamicResponse{ isSub?, subCount? } → AlbumDynamic。
        let resp = try await NeteaseAPI.albumDynamic(id: neteaseID(id))
        return AlbumDynamic(
            isSubscribed: resp.isSub ?? false,
            subscriberCount: resp.subCount ?? 0
        )
    }

    public func subscribeAlbum(_ id: MusicID, subscribe: Bool) async throws {
        try await NeteaseAPI.subscribeAlbum(id: neteaseID(id), subscribe: subscribe)
    }

    // MARK: - MusicArtist

    public func artist(id: MusicID) async throws -> ArtistDetail {
        // ArtistResponse{ artist, hotSongs } → ArtistDetail；id 为计算属性，不传入。
        let resp = try await NeteaseAPI.artist(id: neteaseID(id))
        return ArtistDetail(artist: resp.artist, hotSongs: resp.hotSongs)
    }

    public func artistAlbums(id: MusicID, limit: Int, offset: Int) async throws -> ArtistAlbums {
        // ArtistAlbumsResponse{ hotAlbums, more? } → ArtistAlbums。
        let resp = try await NeteaseAPI.artistAlbums(id: neteaseID(id), limit: limit, offset: offset)
        return ArtistAlbums(albums: resp.hotAlbums, hasMore: resp.more ?? false)
    }

    public func subscribeArtist(_ id: MusicID, subscribe: Bool) async throws {
        try await NeteaseAPI.subscribeArtist(id: neteaseID(id), subscribe: subscribe)
    }

    public func similarArtists(id: MusicID) async throws -> [ArtistSummary] {
        try await NeteaseAPI.similarArtists(id: neteaseID(id))
    }

    // MARK: - Response → model mapping

    /// ToplistItem → Chart（丢弃 tracks 预览，通用模型按需拉取曲目）。
    private func chart(fromToplist item: ToplistItem) -> Chart {
        Chart(
            id: MusicID.source(id: String(item.id), provider: .netease),
            name: item.name,
            coverURL: item.coverImgUrl.flatMap(URL.init(string:)),
            updateFrequency: item.updateFrequency,
            playCount: item.playCount
        )
    }

    /// PlaylistSummary → Chart（topPlaylists 的榜单项；该响应无 updateFrequency）。
    private func chart(fromPlaylist playlist: PlaylistSummary) -> Chart {
        Chart(
            id: MusicID.source(id: String(playlist.id), provider: .netease),
            name: playlist.name,
            coverURL: playlist.coverURL.flatMap(URL.init(string:)),
            updateFrequency: nil,
            playCount: playlist.playCount
        )
    }
}

// MARK: - ID conversion

extension NetEaseMusicProvider {

    /// MusicID → NetEase 数字 id。
    ///
    /// netease 的 id 恒为数字字符串；非数字属上游数据错误，`?? 0` 会在调试期暴露。
    fileprivate func neteaseID(_ id: MusicID) -> Int {
        Int(id.sourceID) ?? 0
    }
}
