import Foundation

/// Looks up the latest GitHub release. iOS has no Sparkle, so Settings
/// offers a manual check that links to the release page for re-sideloading.
public enum ReleaseChecker {
    public struct Release {
        public let version: String
        /// The release page (fallback download link).
        public let url: URL
        /// Direct download URL of the iOS IPA asset, when present.
        public let ipaURL: URL?
    }

    /// Why a release lookup failed. Kept separate from the music API errors so a
    /// GitHub failure is not reported as a netease decoding problem.
    public enum Failure: LocalizedError, Equatable {
        case network
        case http(Int)
        case decoding

        public var errorDescription: String? {
            switch self {
            case .network:
                return "网络连接失败，请检查网络后重试"
            case .http(let code):
                return "服务器返回错误（\(code)）"
            case .decoding:
                return "无法解析版本信息"
            }
        }
    }

    public static let releasesPage = URL(string: "https://github.com/missuo/kumone/releases/latest")!

    public static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    public static func latest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/missuo/kumone/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.network
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.decoding }
        guard (200..<300).contains(http.statusCode) else { throw Failure.http(http.statusCode) }
        return try decodeRelease(from: data)
    }

    /// Parses the GitHub release payload; split from the transport so it can be
    /// tested without hitting the network.
    static func decodeRelease(from data: Data) throws -> Release {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let html = obj["html_url"] as? String, let url = URL(string: html)
        else { throw Failure.decoding }
        let assets = obj["assets"] as? [[String: Any]] ?? []
        let ipa = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".ipa") == true }
        let ipaURL = (ipa?["browser_download_url"] as? String).flatMap(URL.init)
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                       url: url, ipaURL: ipaURL)
    }

    /// True when `remote` is newer than `local` (numeric dotted compare).
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = remote.split(separator: ".").map { Int($0) ?? 0 }
        let b = local.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
