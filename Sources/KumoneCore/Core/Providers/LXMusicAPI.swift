import Foundation

public enum LXAPIError: Error, LocalizedError, Equatable {
    case httpStatus(Int), business(code: Int)
    case invalidResponse, notConfigured, unsupportedQuality, parseFailed, invalidIdentifier

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "LX 请求失败（HTTP \(code)）"
        case .business(let code):
            switch code {
            case -1: return "lx 解析源不提供搜索/发现能力或账号、资料库操作"
            case -2: return "LX 不支持此歌曲平台"
            case 1: return "LX IP 已被封禁"
            case 2: return "LX 获取失败"
            case 3: return "LX 验证失败"
            case 4: return "LX 服务内部错误"
            case 5: return "LX 请求被限流"
            case 6: return "LX 参数错误"
            default: return "LX 接口返回错误（\(code)）"
            }
        case .invalidResponse: return "LX 响应缺少有效数据"
        case .notConfigured: return "请先填写自部署 LX-Source 服务地址"
        case .unsupportedQuality: return "LX 不支持沉浸声音质"
        case .parseFailed: return "LX 服务地址无效，请填写 HTTP 或 HTTPS 地址"
        case .invalidIdentifier: return "LX 需要不含路径或查询参数的歌曲 ID"
        }
    }
}

public struct LXMusicAPI: Sendable {
    private let session: URLSession
    private let settings: @Sendable () -> LXSourceSettings

    /// Read current preferences for each operation; tests may supply isolated settings.
    public init(session: URLSession? = nil,
                settings: @escaping @Sendable () -> LXSourceSettings = { .current }) {
        self.settings = settings
        if let session { self.session = session } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: configuration)
        }
    }

    static func qualityParameter(_ quality: SongQuality) throws -> String {
        switch quality {
        case .standard: return "128k"
        case .high: return "320k"
        case .lossless: return "flac"
        case .hires: return "flac24bit"
        case .immersive: throw LXAPIError.unsupportedQuality
        }
    }

    static func validate(source: String, songID: String) throws {
        guard ["wy", "mg", "kg", "kw", "tx", "lx"].contains(source) else {
            throw LXAPIError.business(code: -2)
        }
        // QQ MIDs and Kugou hashes are not numeric. Keep each ID one route component.
        guard !songID.isEmpty, songID != ".", songID != "..",
              songID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0) }) else {
            throw LXAPIError.invalidIdentifier
        }
    }

    func source(for id: MusicID) throws -> String {
        let source: String
        switch id {
        case .source(_, .netease): source = "wy"
        case .source(_, .qq): source = "tx"
        case .source(_, .kuwo): source = "kw"
        case .source(_, .lx): source = settings().platform
        }
        try Self.validate(source: source, songID: id.sourceID)
        return source
    }

    public func songURL(source: String, songID: String, quality: SongQuality) async throws -> URL {
        let quality = try Self.qualityParameter(quality)
        return try Self.mediaURL(await request(method: "url", source: source, songID: songID, quality: quality))
    }

    public func cover(source: String, songID: String) async throws -> URL {
        try Self.mediaURL(await request(method: "pic", source: source, songID: songID))
    }

    public func lyric(source: String, songID: String) async throws -> LyricResponse {
        let text = try await request(method: "lrc", source: source, songID: songID)
        var original = text
        var translation: String?
        // Constructed compatibility cases; the live service's lyric shape still needs verification.
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           object["lrc"] != nil || object["tlyric"] != nil {
            func extract(_ value: Any?) -> String? {
                (value as? String) ?? (value as? [String: Any])?["lyric"] as? String
            }
            guard let lrc = extract(object["lrc"]), !lrc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LXAPIError.invalidResponse
            }
            original = lrc
            translation = extract(object["tlyric"])
        }
        return LyricResponse(lrc: .init(lyric: original), tlyric: translation.map { .init(lyric: $0) },
            romalrc: nil, yrc: nil, ytlrc: nil, yromalrc: nil,
            lyricUser: nil, transUser: nil, nolyric: nil, uncollected: nil)
    }

    private static func mediaURL(_ text: String) throws -> URL {
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty,
              !text.contains(where: { $0.isWhitespace }) else { throw LXAPIError.invalidResponse }
        return url
    }

    private struct Status: Decodable { let code: Int; let msg: String? }
    private struct Payload: Decodable { let data: String }

    private func request(method: String, source: String, songID: String, quality: String? = nil) async throws -> String {
        let config = settings()
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw LXAPIError.notConfigured }
        try Self.validate(source: source, songID: songID)
        guard var components = URLComponents(string: base),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { throw LXAPIError.parseFailed }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/").map(String.init).map { "/" + $0 }.joined()
            + "/\(method)/\(source)/\(songID)" + (quality.map { "/" + $0 } ?? "")
        if !config.apiKey.isEmpty { components.queryItems = [URLQueryItem(name: "key", value: config.apiKey)] }
        guard let url = components.url else { throw LXAPIError.parseFailed }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.httpShouldHandleCookies = false
        if !config.apiKey.isEmpty { request.setValue(config.apiKey, forHTTPHeaderField: "X-LxM-Auth") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LXAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw LXAPIError.httpStatus(http.statusCode) }
        guard let status = try? JSONDecoder().decode(Status.self, from: data) else { throw LXAPIError.invalidResponse }
        guard status.code == 0 else { throw LXAPIError.business(code: status.code) }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.data.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LXAPIError.invalidResponse }
        return payload.data
    }
}
