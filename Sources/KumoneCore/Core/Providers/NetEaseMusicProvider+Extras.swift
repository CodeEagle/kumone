import Foundation

// Sources/Kumone/Core/Providers/NetEaseMusicProvider+Extras.swift
//
// NetEase 源 provider 的 4 个特有 optional 能力域（Phase 1 / P1-e）：
// MusicPlayHistory / MusicPersonalFM / MusicCloudStorage / MusicIntelligence。
// 主定义见 NetEaseMusicProvider.swift（P1-a，仅 MusicAuth + MusicLogin）。
//
// Access level: internal（与主定义一致；public 引用 internal 模型是 hard error，
// 同 target 亦无需 public）。
//
// 此处不收口 `NetEaseProvider`（那是 P1-final 的工作），只实现 4 个特有域本身。

extension NetEaseMusicProvider: MusicPlayHistory, MusicPersonalFM,
                                MusicCloudStorage, MusicIntelligence {

    // MARK: - MusicPlayHistory

    public func playRecords(uid: MusicID, week: Bool) async throws -> [PlayRecord] {
        // PlayRecordItem{ playCount, score, song } → PlayRecord{ playCount, score, song }：
        // 三字段同名同型，逐个搬运即可。
        try await NeteaseAPI.playRecords(uid: neteaseID(uid), week: week)
            .map { PlayRecord(playCount: $0.playCount, score: $0.score, song: $0.song) }
    }

    // MARK: - MusicPersonalFM

    public func personalFM() async throws -> [Track] {
        try await NeteaseAPI.personalFM()
    }

    public func fmTrash(_ id: MusicID) async throws {
        try await NeteaseAPI.fmTrash(id: neteaseID(id))
    }

    // MARK: - MusicCloudStorage

    public func cloudSongs(limit: Int, offset: Int) async throws -> CloudStoragePage {
        // CloudResponse{ data, hasMore, size, maxSize }
        // → CloudStoragePage{ items, hasMore, usedBytes, maxBytes }：
        // size/maxBytes 已在 Decodable 层收敛 Int/String → Int64，此处仅处理 optional。
        let resp = try await NeteaseAPI.cloudSongs(limit: limit, offset: offset)
        return CloudStoragePage(
            items: resp.data ?? [],
            hasMore: resp.hasMore ?? false,
            usedBytes: resp.size ?? 0,
            maxBytes: resp.maxSize ?? 0
        )
    }

    public func cloudDelete(_ id: MusicID) async throws {
        try await NeteaseAPI.cloudDelete(id: neteaseID(id))
    }

    // MARK: - MusicIntelligence

    public func intelligenceList(songID: MusicID, playlistID: MusicID) async throws -> [Track] {
        try await NeteaseAPI.intelligenceList(songID: neteaseID(songID),
                                              playlistID: neteaseID(playlistID))
    }
}

// MARK: - ID conversion

extension NetEaseMusicProvider {

    /// MusicID → NetEase 数字 id。
    ///
    /// netease 的 id 恒为数字字符串；非数字属上游数据错误，`?? 0` 会在调试期暴露。
    /// 与 NetEaseMusicProvider+Library.swift 同款（fileprivate 按文件隔离，互不冲突）。
    fileprivate func neteaseID(_ id: MusicID) -> Int {
        Int(id.sourceID) ?? 0
    }
}

// MARK: - Composite conformance (P1-final)

/// 全部 12 个能力域方法由 P1-a~e 各 extension 补齐后，此处才可安全 conform
/// `NetEaseProvider`（通用 8 域 + 特有 4 域）。缺任何一域都会在此编译失败。
extension NetEaseMusicProvider: NetEaseProvider {}
