import Foundation

// Sources/Kumone/Core/Providers/NetEaseMusicProvider+Library.swift
//
// NetEase 源 provider 的 MusicLibrary + MusicPlaylist 两个能力域（Phase 1 / P1-b）。
// 主定义见 NetEaseMusicProvider.swift（P1-a，仅 MusicAuth + MusicLogin）。
//
// Access level: internal（与主定义一致；public 引用 internal 模型是 hard error，
// 同 target 亦无需 public）。

extension NetEaseMusicProvider: MusicLibrary, MusicPlaylist {

    // MARK: - MusicLibrary

    public func userAccount() async throws -> UserProfile {
        // NeteaseAPI 返回 UserProfile?：未登录时为 nil。协议要求非 optional，
        // 故 nil 时抛 userAuthenticationRequired，由调用方提示登录，而不强解包。
        guard let profile = try await NeteaseAPI.userAccount() else {
            throw URLError(.userAuthenticationRequired)
        }
        return profile
    }

    public func userPlaylists(uid: MusicID, limit: Int, offset: Int) async throws -> [PlaylistSummary] {
        try await NeteaseAPI.userPlaylists(uid: neteaseID(uid), limit: limit, offset: offset)
    }

    public func likedTrackIDs(uid: MusicID) async throws -> [MusicID] {
        // 显式标 .netease：不依赖 activeProviderID（MusicID(_:) 的隐式约定）。
        try await NeteaseAPI.likedTrackIDs(uid: neteaseID(uid))
            .map { MusicID.source(id: String($0), provider: .netease) }
    }

    public func likeTrack(_ id: MusicID, like: Bool) async throws {
        try await NeteaseAPI.likeTrack(id: neteaseID(id), like: like)
    }

    public func likedAlbums(limit: Int, offset: Int) async throws -> [AlbumSummary] {
        try await NeteaseAPI.likedAlbums(limit: limit, offset: offset)
    }

    public func likedArtists(limit: Int, offset: Int) async throws -> [ArtistSummary] {
        try await NeteaseAPI.likedArtists(limit: limit, offset: offset)
    }

    // MARK: - MusicPlaylist

    public func playlistDetail(id: MusicID) async throws -> PlaylistDetail {
        let response = try await NeteaseAPI.playlistDetail(id: neteaseID(id))
        return PlaylistDetail(detail: response.playlist, privileges: response.privileges)
    }

    public func playlistBrief(id: MusicID) async throws -> PlaylistBriefInfo {
        // PlaylistBrief.Body{ id: Int, name: String?, coverImgUrl: String? }
        // → PlaylistBriefInfo{ id: MusicID, name: String, coverURL: URL? }
        let body = try await NeteaseAPI.playlistBrief(id: neteaseID(id))
        return PlaylistBriefInfo(
            id: .source(id: String(body.id), provider: .netease),
            name: body.name ?? "",
            coverURL: body.coverImgUrl.flatMap(URL.init(string:))
        )
    }

    public func createPlaylist(name: String, isPrivate: Bool) async throws -> MusicID? {
        try await NeteaseAPI.createPlaylist(name: name, isPrivate: isPrivate)
            .map { MusicID.source(id: String($0), provider: .netease) }
    }

    public func deletePlaylist(_ id: MusicID) async throws {
        try await NeteaseAPI.deletePlaylist(id: neteaseID(id))
    }

    public func subscribePlaylist(_ id: MusicID, subscribe: Bool) async throws {
        try await NeteaseAPI.subscribePlaylist(id: neteaseID(id), subscribe: subscribe)
    }

    public func playlistTracks(_ op: PlaylistOp, playlistID: MusicID, trackIDs: [MusicID]) async throws {
        try await NeteaseAPI.playlistTracks(
            op: op.rawValue,
            playlistID: neteaseID(playlistID),
            trackIDs: trackIDs.map { neteaseID($0) }
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
