import Foundation

public enum KuwoAPIError: Error, LocalizedError, Equatable {
    case httpStatus(Int), business(code: Int)
    case invalidResponse, invalidIdentifier, invalidPagination
    case lyricUnavailable, playlistUnavailable, searchCategoryUnavailable, unavailable

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return String(localized: "酷我请求失败（HTTP \(code)）")
        case .business(let code): return String(localized: "酷我接口返回错误（\(code)）")
        case .invalidResponse: return String(localized: "酷我响应缺少有效数据")
        case .invalidIdentifier: return String(localized: "酷我需要本源的数字歌曲 RID")
        case .invalidPagination: return String(localized: "酷我分页参数无效（最多读取前 1000 条）")
        case .lyricUnavailable: return String(localized: "酷我匿名歌词接口暂不可用")
        case .playlistUnavailable: return String(localized: "酷我匿名歌单接口暂不可用")
        case .searchCategoryUnavailable: return String(localized: "酷我匿名搜索暂只支持歌曲类目")
        case .unavailable: return String(localized: "酷我匿名接口暂不可用")
        }
    }
}

public struct KuwoMusicAPI: Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? AnonymousSession.make()
    }

    static func validRID(_ rid: String) -> Bool {
        !rid.isEmpty && rid.utf8.allSatisfy { (48...57).contains($0) } && (Int(rid) ?? 0) > 0
    }

    // Fetch a bounded prefix and slice locally: arbitrary offsets are not page numbers.
    private func prefixSize(offset: Int, limit: Int) throws -> Int {
        guard offset >= 0, limit > 0, limit <= 1000, offset <= 1000 - limit else {
            throw KuwoAPIError.invalidPagination
        }
        return offset + limit
    }

    public func search(keyword: String, limit: Int, offset: Int) async throws -> SearchPage {
        let size = try prefixSize(offset: offset, limit: limit)
        let data = try await request("https://search.kuwo.cn/r.s", [
            "correct": "1", "vipver": "1", "stype": "comprehensive", "encoding": "utf8",
            "rformat": "json", "mobi": "1", "show_copyright_off": "1", "searchapi": "6",
            "all": keyword, "pn": "0", "rn": String(size)
        ])
        let response: SearchResponse = try decode(data)
        guard let page = response.content.compactMap(\.musicpage).first else {
            throw KuwoAPIError.invalidResponse
        }
        return SearchPage(TOTAL: page.TOTAL, abslist: Array(page.abslist.dropFirst(offset).prefix(limit)))
    }

    public func playURL(rid: String) async throws -> URL {
        guard Self.validRID(rid) else { throw KuwoAPIError.invalidIdentifier }
        let data = try await request("https://antiserver.kuwo.cn/anti.s", [
            "type": "convert_url", "format": "mp3", "response": "url", "rid": "MUSIC_\(rid)"
        ])
        guard let text = String(data: data, encoding: .utf8),
              let range = text.range(of: #"https?://[^\s$"]+"#, options: .regularExpression),
              let url = URL(string: String(text[range])), url.host != nil else {
            throw KuwoAPIError.invalidResponse
        }
        return url
    }

    public func bangContent(id: String, offset: Int, num: Int) async throws -> BangContent {
        guard Self.validRID(id) else { throw KuwoAPIError.invalidIdentifier }
        let size = try prefixSize(offset: offset, limit: num)
        let data = try await request("http://kbangserver.kuwo.cn/ksong.s", [
            "from": "pc", "fmt": "json", "type": "bang", "data": "content",
            "id": id, "pn": "0", "rn": String(size)
        ])
        var content: BangContent = try decode(data)
        content.musiclist = Array(content.musiclist.dropFirst(offset).prefix(num))
        return content
    }

    /// The anonymous menu returns {}; these are the three verified chart IDs.
    /// Fetch content for current artwork and publication date rather than freezing a probe date.
    public func bangList() async throws -> [Chart] {
        var charts: [Chart] = []
        for (id, name) in [("93", String(localized: "酷我飙升榜")), ("16", String(localized: "酷我热歌榜")), ("17", String(localized: "酷我新歌榜"))] {
            let content = try await bangContent(id: id, offset: 0, num: 1)
            let coverURL = content.pic.flatMap { pic -> URL? in
                guard !pic.isEmpty, !pic.hasSuffix("/"),
                      let url = URL(string: pic), !url.hasDirectoryPath,
                      !url.pathExtension.isEmpty else { return nil }
                return url
            }
            charts.append(Chart(id: .source(id: id, provider: .kuwo), name: name,
                coverURL: coverURL, updateFrequency: content.pub, playCount: 0))
        }
        return charts
    }

    private func request(_ endpoint: String, _ query: [String: String]) async throws -> Data {
        var components = URLComponents(string: endpoint)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = AnonymousSession.requestTimeout
        request.httpShouldHandleCookies = false
        request.setValue("http://www.kuwo.cn/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw KuwoAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw KuwoAPIError.httpStatus(http.statusCode) }
        return data
    }

    private struct Status: Decodable { let code: Int?; let success: Bool? }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        if let status = try? JSONDecoder().decode(Status.self, from: data) {
            if let code = status.code, code != 0, code != 200 { throw KuwoAPIError.business(code: code) }
            if status.success == false { throw KuwoAPIError.unavailable }
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw KuwoAPIError.invalidResponse }
    }

    private struct SearchResponse: Decodable { let content: [SearchBlock] }
    private struct SearchBlock: Decodable {
        let musicpage: SearchPage?
        enum CodingKeys: String, CodingKey { case musicpage }
        init(from decoder: Decoder) throws {
            // Other content blocks may be arbitrarily shaped; only decode musicpage.
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                musicpage = nil
                return
            }
            musicpage = try container.decodeIfPresent(SearchPage.self, forKey: .musicpage)
        }
    }
    public struct SearchPage: Codable, Sendable {
        public let TOTAL: String?
        public let abslist: [SearchSong]
    }
    public struct SearchSong: Codable, Sendable {
        public let MUSICRID: String
        public let SONGNAME: String?, ARTIST: String?, ALBUM: String?
        public let ALBUMID: String?, ARTISTID: String?, DURATION: String?
        public let web_albumpic_short: String?
        public var rid: String { MUSICRID.hasPrefix("MUSIC_") ? String(MUSICRID.dropFirst(6)) : MUSICRID }
        public var musicID: MusicID { .source(id: rid, provider: .kuwo) }
        public var track: Track {
            makeTrack(rid: rid, name: SONGNAME, artist: ARTIST, artistID: ARTISTID,
                album: ALBUM, albumID: ALBUMID, seconds: DURATION,
                cover: web_albumpic_short.flatMap { $0.isEmpty ? nil : "https://img1.kuwo.cn/star/albumcover/\($0)" })
        }
    }
    public struct BangContent: Codable, Sendable {
        public let name: String?, leader: String?, info: String?, pic: String?, pub: String?, num: String?
        public var musiclist: [KuwoSong]
    }
    public struct KuwoSong: Codable, Sendable {
        public let id: String
        public let name: String?, artist: String?, artistid: String?, album: String?, albumid: String?
        public let song_duration: String?
        public var musicID: MusicID { .source(id: id, provider: .kuwo) }
        public var track: Track {
            makeTrack(rid: id, name: name, artist: artist, artistID: artistid,
                album: album, albumID: albumid, seconds: song_duration, cover: nil)
        }
    }
}

private func makeTrack(rid: String, name: String?, artist: String?, artistID: String?,
                       album: String?, albumID: String?, seconds: String?, cover: String?) -> Track {
    let duration = max(0, Int(seconds ?? "") ?? 0)
    return Track(id: Int(rid) ?? 0, name: name ?? "",
        artists: artist.map { [ArtistRef(id: Int(artistID ?? "") ?? 0, name: $0)] } ?? [],
        album: AlbumRef(id: Int(albumID ?? "") ?? 0, name: album ?? "", picUrl: cover),
        durationMS: duration <= Int.max / 1000 ? duration * 1000 : 0,
        alias: [], transNames: [], fee: 0, mvID: 0, trackNo: 0, disc: nil,
        noCopyright: false, isCloud: false, embeddedPrivilege: nil)
}
