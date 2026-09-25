import Foundation

// Sources/Kumone/Core/Providers/NetEaseMusicProvider+Playback.swift
//
// NetEase 源 provider 的播放（MusicPlayback）与搜索（MusicSearch）能力域
//（Phase 1 / P1-c）。以独立 extension 补齐主定义（P1-a）缺失的这两个域；
// Library/Playlist（P1-b）与 Discovery/Album/Artist 及 4 个特有域（P1-d/e）
// 由各自 extension 文件实现，此处不碰。
//
// Access level: internal（与 MusicProvider.swift / 主文件一致；public 引用
// internal 模型是 hard error，同 target 亦无需 public）。

extension NetEaseMusicProvider: MusicPlayback, MusicSearch {

    // MARK: - MusicPlayback

    public func songURL(ids: [MusicID], quality: SongQuality) async throws -> [SongURLData] {
        // netease 的 id 恒为数字字符串；非数字属上游数据错误，`?? 0` 会在调试期暴露。
        let neteaseIDs = ids.map { Int($0.sourceID) ?? 0 }
        return try await NeteaseAPI.songURL(ids: neteaseIDs, level: quality.neteaseLevel)
    }

    public func songDetails(ids: [MusicID]) async throws -> [Track] {
        let neteaseIDs = ids.map { Int($0.sourceID) ?? 0 }
        let response = try await NeteaseAPI.songDetails(ids: neteaseIDs)
        let privilegesByID = Dictionary(
            (response.privileges ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        return response.songs.map { track in
            var track = track
            track.embeddedPrivilege = privilegesByID[track.id] ?? track.embeddedPrivilege
            return track
        }
    }

    public func lyric(id: MusicID) async throws -> LyricResponse {
        try await NeteaseAPI.lyric(id: Int(id.sourceID) ?? 0)
    }

    public func scrobbleStart(trackID: MusicID, sourceID: MusicID) async {
        await NeteaseAPI.scrobbleStart(trackID: Int(trackID.sourceID) ?? 0,
                                       sourceID: Int(sourceID.sourceID) ?? 0)
    }

    public func scrobbleFinish(trackID: MusicID, sourceID: MusicID, seconds: Int) async {
        await NeteaseAPI.scrobbleFinish(trackID: Int(trackID.sourceID) ?? 0,
                                        sourceID: Int(sourceID.sourceID) ?? 0,
                                        seconds: seconds)
    }

    public func similarSongs(id: MusicID, limit: Int) async throws -> [Track] {
        try await NeteaseAPI.similarSongs(id: Int(id.sourceID) ?? 0, limit: limit)
    }

    // MARK: - MusicSearch

    public func search(_ keywords: String, category: SearchCategory, limit: Int, offset: Int) async throws -> SearchResult {
        // SearchCategory.neteaseRawValue（1/10/100/1000）与 NeteaseAPI.SearchType
        // 的 rawValue 一一对应；四个类别全覆盖，构造失败属不可达的上游数据错误。
        guard let type = NeteaseAPI.SearchType(rawValue: category.neteaseRawValue) else {
            throw URLError(.cannotParseResponse)
        }
        let result = try await NeteaseAPI.search(keywords, type: type, limit: limit, offset: offset)
        return SearchResult(
            songs: result.songs ?? [],
            albums: result.albums ?? [],
            artists: result.artists ?? [],
            playlists: result.playlists ?? [],
            counts: SearchCounts(songs: result.songCount ?? 0,
                                 albums: result.albumCount ?? 0,
                                 artists: result.artistCount ?? 0,
                                 playlists: result.playlistCount ?? 0))
    }

    public func searchSuggest(_ keywords: String) async throws -> SearchSuggestion {
        // searchSuggest 返回 `SearchSuggestResponse.Body?`：无建议时后端给 nil，
        // 映射为空集合前先 guard，避免强解包。
        guard let body = try await NeteaseAPI.searchSuggest(keywords) else {
            throw URLError(.cannotParseResponse)
        }
        return SearchSuggestion(songs: body.songs ?? [],
                                artists: body.artists ?? [],
                                albums: body.albums ?? [],
                                playlists: body.playlists ?? [])
    }

    public func searchDefaultKeyword() async throws -> String? {
        try await NeteaseAPI.searchDefaultKeyword()
    }
}
