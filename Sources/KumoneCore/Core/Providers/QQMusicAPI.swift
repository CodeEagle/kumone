import Foundation

public enum QQMusicAPIError: Error, LocalizedError, Equatable {
    case httpStatus(Int)
    case business(code: Int)
    case invalidResponse
    case invalidIdentifier
    case invalidPagination
    case searchUnavailable
    case loginRequired

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "QQ 音乐请求失败（HTTP \(code)）"
        case .business(let code): return "QQ 音乐接口返回错误（\(code)）"
        case .invalidResponse: return "QQ 音乐响应缺少有效数据"
        case .invalidIdentifier: return "QQ 音乐需要本源的歌曲 MID"
        case .invalidPagination: return "QQ 音乐分页参数无效"
        case .searchUnavailable: return "QQ 音乐匿名搜索接口暂不可用"
        case .loginRequired: return "QQ 音乐播放需要登录票据，当前尚不支持登录"
        }
    }
}

/// Anonymous musicu client. A dedicated session avoids sharing login cookies.
public struct QQMusicAPI: Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? AnonymousSession.make()
    }

    public func hotkeys() async throws -> [String] {
        let data: Hotkeys = try await request(module: "music.musicsearch.HotkeyService",
            method: "GetHotkeyForQQMusicMobile", param: ["search_id": UUID().uuidString])
        return (data.vec_hotkey ?? []).compactMap(\.query).filter { !$0.isEmpty }
    }

    public func toplists() async throws -> [Toplist] {
        let data: Toplists = try await request(module: "music.musicToplist.Toplist",
            method: "GetAll", param: [String: Int]())
        return (data.group ?? []).flatMap { $0.toplist ?? [] }
    }

    public func toplistDetail(topId: Int, offset: Int, num: Int) async throws -> [Song] {
        guard topId > 0, offset >= 0, num > 0 else { throw QQMusicAPIError.invalidPagination }
        let data: ToplistDetail = try await request(module: "music.musicToplist.Toplist",
            method: "GetDetail", param: ["topId": topId, "offset": offset, "num": num])
        return data.songInfoList ?? []
    }

    public func recommendFeed(from: Int, size: Int) async throws -> [PlaylistBasic] {
        guard from >= 0, size > 0 else { throw QQMusicAPIError.invalidPagination }
        let data: RecommendFeed = try await request(module: "music.playlist.PlaylistSquare",
            method: "GetRecommendFeed", param: ["From": from, "Size": size])
        return (data.List ?? []).compactMap { $0.Playlist?.basic }
    }

    public func lyric(songMID: String) async throws -> Lyrics {
        guard !songMID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QQMusicAPIError.invalidIdentifier
        }
        return try await request(module: "music.musichallSong.PlayLyricInfo",
            method: "GetPlayLyricInfo", param: ["songMID": songMID])
    }

    private struct Comm: Encodable {
        let ct = 24, cv = 4747474, g_tk = 5381
        let platform = "yqq.json", uin = "0", format = "json"
    }
    private struct Request<P: Encodable>: Encodable {
        let comm = Comm()
        let req_0: Call<P>
    }
    private struct Call<P: Encodable>: Encodable {
        let module: String
        let method: String
        let param: P
    }
    // Decode status before payload: error responses can contain a differently shaped data block.
    private struct Status: Decodable {
        let code: Int?
        let req_0: Block?
        struct Block: Decodable { let code: Int? }
    }
    private struct Response<T: Decodable>: Decodable {
        let req_0: Block
        struct Block: Decodable { let data: T? }
    }

    private func request<P: Encodable, T: Decodable>(module: String, method: String, param: P) async throws -> T {
        var request = URLRequest(url: URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!)
        request.httpMethod = "POST"
        request.timeoutInterval = AnonymousSession.requestTimeout
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(Request(req_0: Call(module: module, method: method, param: param)))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw QQMusicAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw QQMusicAPIError.httpStatus(http.statusCode) }
        do {
            let decoder = JSONDecoder()
            let status = try decoder.decode(Status.self, from: data)
            guard let code = status.code else { throw QQMusicAPIError.invalidResponse }
            guard code == 0 else { throw QQMusicAPIError.business(code: code) }
            guard let code = status.req_0?.code else { throw QQMusicAPIError.invalidResponse }
            guard code == 0 else { throw QQMusicAPIError.business(code: code) }
            guard let payload = try decoder.decode(Response<T>.self, from: data).req_0.data else {
                throw QQMusicAPIError.invalidResponse
            }
            return payload
        } catch is DecodingError {
            throw QQMusicAPIError.invalidResponse
        }
    }

    private struct Hotkeys: Codable { let vec_hotkey: [Hotkey]? }
    private struct Hotkey: Codable { let query: String? }
    private struct Toplists: Codable { let group: [Group]? }
    private struct Group: Codable { let toplist: [Toplist]? }
    private struct ToplistDetail: Codable { let songInfoList: [Song]? }
    private struct RecommendFeed: Codable { let List: [FeedItem]? }
    private struct FeedItem: Codable { let Playlist: PlaylistItem? }
    private struct PlaylistItem: Codable { let basic: PlaylistBasic? }

    public struct Toplist: Codable, Sendable {
        public let topId: Int
        public let title: String?
        public let picUrl: String?
        public let listenNum: Int?
        public let updateTime: String?
        public let period: String?
        public let song: [Preview]?
    }
    public struct Preview: Codable, Sendable {
        public let title: String?
        public let singerName: String?
    }
    public struct Song: Codable, Sendable {
        public let id: Int
        public let mid: String
        public let name: String?
        public let singer: [Singer]?
        public let album: Album?
        public let interval: Int?

        public var musicID: MusicID { .source(id: mid, provider: .qq) }
        public var track: Track {
            Track(id: id, name: name ?? "", artists: (singer ?? []).map {
                ArtistRef(id: $0.id ?? 0, name: $0.name ?? "")
            }, album: AlbumRef(id: album?.id ?? 0, name: album?.name ?? "", picUrl: nil),
                durationMS: milliseconds(fromSeconds: interval ?? 0), alias: [], transNames: [], fee: 0,
                mvID: 0, trackNo: 0, disc: nil, noCopyright: false, isCloud: false,
                embeddedPrivilege: nil)
        }
    }
    public struct Singer: Codable, Sendable {
        public let id: Int?
        public let mid: String?
        public let name: String?
    }
    public struct Album: Codable, Sendable {
        public let id: Int?
        public let mid: String?
        public let name: String?
        public let time_public: String?
        public let pmid: String?
    }
    public struct PlaylistBasic: Codable, Sendable {
        public let tid: Int
        public let title: String?
        public let cover: Cover?
        public let creator: Creator?
        public let song_cnt: Int?
        public let play_cnt: Int?
    }
    public struct Cover: Codable, Sendable { public let medium_url: String? }
    public struct Creator: Codable, Sendable { public let nick: String? }
    public struct Lyrics: Codable, Sendable {
        public let lyric: String?
        public let trans: String?
        public let roma: String?
    }
}
