import CryptoKit
import Foundation
import os.log

/// Native reimplementation of UnblockNeteaseMusic's core providers.
/// When NetEase refuses to serve a track (no copyright / delisted / paid),
/// resolve an alternative stream from third-party sources.
///
/// Provider order prioritizes original NetEase IDs before search matches:
/// 1. pyncmd — GD Studio API, resolves by the ORIGINAL NetEase id (best fidelity)
/// 2. lx     — configured LX source, resolves by the original NetEase id
/// 3. kugou  — fuzzy search + duration match, tracker URL
/// 4. kuwo   — fuzzy search + duration match (±5 s), then convert_url
public enum UnblockService {
    private static let log = Logger(subsystem: "im.missuo.kumone", category: "unblock")

    public struct Resolved {
        public let url: URL
        public let source: String
    }

    public static func resolve(_ track: Track) async -> Resolved? {
        guard !Task.isCancelled else { return nil }
        if let url = await pyncmd(track) {
            return Resolved(url: url, source: "pyncmd")
        }
        guard !Task.isCancelled else { return nil }
        if let url = await lx(track) {
            return Resolved(url: url, source: String(localized: "LX 解析"))
        }
        // kugou before kuwo: kuwo's convert_url increasingly serves a
        // "请在酷我音乐APP播放" promo clip instead of the real audio, so keep it
        // as the last resort rather than the first fallback (#44).
        guard !Task.isCancelled else { return nil }
        if let url = await kugou(track) {
            return Resolved(url: url, source: String(localized: "酷狗音乐"))
        }
        guard !Task.isCancelled else { return nil }
        if let url = await kuwo(track) {
            return Resolved(url: url, source: String(localized: "酷我音乐"))
        }
        return nil
    }

    private static func keyword(for track: Track) -> String {
        "\(track.name) \(track.artists.first?.name ?? "")"
            .trimmingCharacters(in: .whitespaces)
    }

    /// UNM's `select`: first of the top 5 within ±5 s of the target duration, else the first.
    private static func selectMatch<T>(_ list: [T], durationMS: Int,
                                       duration: (T) -> Int) -> T? {
        if let match = list.prefix(5).first(where: {
            duration($0) > 0 && abs(duration($0) - durationMS) < 5000
        }) {
            return match
        }
        return list.first
    }

    private static func get(_ urlString: String, userAgent: String = "Mozilla/5.0", session: URLSession = .shared) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false
        else { return nil }
        return data
    }

    // MARK: - pyncmd

    private static func pyncmd(_ track: Track) async -> URL? {
        let urlString = "https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=\(track.id)&br=320"
        guard let data = await get(urlString),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let br = obj["br"] as? Int, br > 0,
              let urlValue = obj["url"] as? String,
              let url = URL(string: urlValue.replacingOccurrences(of: "http://", with: "https://"))
        else { return nil }
        return url
    }

    // MARK: - lx

    private static func lx(_ track: Track) async -> URL? {
        await lx(track, api: LXMusicAPI())
    }

    /// Inject an API with an isolated session/settings for offline replay tests.
    static func lx(_ track: Track, api: LXMusicAPI) async -> URL? {
        // Track has no platform identifier; like pyncmd, this assumes a NetEase ID.
        try? await api.songURL(source: "wy", songID: String(track.id), quality: .standard)
    }

    // MARK: - kuwo

    static func kuwo(_ track: Track, session: URLSession = .shared) async -> URL? {
        var components = URLComponents(string: "https://search.kuwo.cn/r.s")!
        components.queryItems = [
            URLQueryItem(name: "correct", value: "1"),
            URLQueryItem(name: "vipver", value: "1"),
            URLQueryItem(name: "stype", value: "comprehensive"),
            URLQueryItem(name: "encoding", value: "utf8"),
            URLQueryItem(name: "rformat", value: "json"),
            URLQueryItem(name: "mobi", value: "1"),
            URLQueryItem(name: "show_copyright_off", value: "1"),
            URLQueryItem(name: "searchapi", value: "6"),
            URLQueryItem(name: "all", value: keyword(for: track)),
        ]
        guard let searchURL = components.url,
              let data = await get(searchURL.absoluteString, session: session),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [Any],
              let abslist = content.compactMap({ block -> [[String: Any]]? in
                  guard let block = block as? [String: Any],
                        let musicpage = block["musicpage"] as? [String: Any],
                        let list = musicpage["abslist"] as? [[String: Any]], !list.isEmpty
                  else { return nil }
                  return list
              }).first
        else { return nil }

        struct KuwoSong {
            let rid: String
            let durationMS: Int
        }
        let songs: [KuwoSong] = abslist.compactMap { item in
            guard let musicrid = item["MUSICRID"] as? String,
                  let rid = musicrid.components(separatedBy: "_").last else { return nil }
            let duration = Int((item["DURATION"] as? String) ?? "") ?? (item["DURATION"] as? Int ?? 0)
            return KuwoSong(rid: rid, durationMS: milliseconds(fromSeconds: duration))
        }
        guard let match = selectMatch(songs, durationMS: track.durationMS, duration: \.durationMS)
        else { return nil }

        let convertURL = "https://antiserver.kuwo.cn/anti.s?type=convert_url&format=mp3&response=url&rid=MUSIC_\(match.rid)"
        guard let body = await get(convertURL, userAgent: "okhttp/3.10.0", session: session),
              let text = String(data: body, encoding: .utf8),
              let range = text.range(of: #"http[^\s$"]+"#, options: .regularExpression),
              let url = URL(string: String(text[range]))
        else { return nil }
        return url
    }

    // MARK: - kugou

    static func kugou(_ track: Track, session: URLSession = .shared) async -> URL? {
        var components = URLComponents(string: "http://mobilecdn.kugou.com/api/v3/search/song")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "keyword", value: keyword(for: track)),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "pagesize", value: "10"),
        ]
        guard let searchURL = components.url,
              let data = await get(searchURL.absoluteString, session: session),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = obj["data"] as? [String: Any],
              let info = dataObj["info"] as? [[String: Any]], !info.isEmpty
        else { return nil }

        struct KugouSong {
            let hash: String
            let albumID: String
            let durationMS: Int
        }
        let songs: [KugouSong] = info.compactMap { item in
            guard let hash = item["hash"] as? String else { return nil }
            let albumID = (item["album_id"] as? String) ?? String(item["album_id"] as? Int ?? 0)
            let duration = item["duration"] as? Int ?? 0
            return KugouSong(hash: hash, albumID: albumID, durationMS: milliseconds(fromSeconds: duration))
        }
        guard let match = selectMatch(songs, durationMS: track.durationMS, duration: \.durationMS)
        else { return nil }

        let key = Insecure.MD5.hash(data: Data("\(match.hash)kgcloudv2".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let trackURL = "https://trackercdn.kugou.com/i/v2/?key=\(key)&hash=\(match.hash)"
            + "&appid=1005&pid=2&cmd=25&behavior=play&album_id=\(match.albumID)"
        guard let body = await get(trackURL, session: session),
              let obj2 = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let urls = obj2["url"] as? [String],
              let first = urls.first, let url = URL(string: first)
        else { return nil }
        return url
    }
}
