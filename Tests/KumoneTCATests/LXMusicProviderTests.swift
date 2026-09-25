import Foundation
import XCTest
@testable import KumoneCore

final class LXMusicProviderTests: XCTestCase {
    /// Fixtures below are hand-authored contract examples, NOT recordings from a deployed LX-Source.
    func testConstructedLXContract() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LXFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); LXFixtureProtocol.handler = nil }
        let api = LXMusicAPI(session: session, settings: {
            LXSourceSettings(baseURL: "https://lx.example.test/prefix/", apiKey: "key &+?", platform: "mg")
        })
        let provider = LXMusicProvider(api: api)
        var path = "/prefix/url/wy/123/128k"
        var status = 200
        var body = try envelope("https://media.example.test/song.mp3")
        var requests = 0
        LXFixtureProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.host, "lx.example.test")
            XCTAssertEqual(request.url?.path, path)
            XCTAssertEqual(request.timeoutInterval, 30)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-LxM-Auth"), "key &+?")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "key", value: "key &+?")])
            return (status, body)
        }
        let tiers: [(SongQuality, String, Int)] = [(.standard, "128k", 128000), (.high, "320k", 320000),
                                                (.lossless, "flac", 999000), (.hires, "flac24bit", 999000)]
        for (quality, parameter, bitrate) in tiers {
            path = "/prefix/url/wy/123/\(parameter)"
            let urls = try await provider.songURL(ids: [.source(id: "123", provider: .netease)], quality: quality)
            XCTAssertEqual(urls.first?.url, "https://media.example.test/song.mp3")
            XCTAssertEqual(urls.first?.id, 123)
            XCTAssertEqual(urls.first?.br, bitrate)
            XCTAssertNil(urls.first?.type)
            XCTAssertNil(urls.first?.level)
        }
        for (source, platform, id): (MusicProviderID, String, String) in [(.qq, "tx", "003MID"), (.kuwo, "kw", "6686351"), (.lx, "mg", "123")] {
            path = "/prefix/url/\(platform)/\(id)/128k"
            _ = try await provider.songURL(ids: [.source(id: id, provider: source)], quality: .standard)
        }
        path = "/prefix/lrc/wy/123"
        body = try envelope("[00:01.00]Hello")
        let plain = try await provider.lyric(id: .source(id: "123", provider: .netease))
        XCTAssertEqual(plain.lrc?.lyric, "[00:01.00]Hello")
        XCTAssertNil(plain.tlyric)
        for nested in [#"{"lrc":"[00:01]Hello","tlyric":"[00:01]你好"}"#,
                       #"{"lrc":{"lyric":"[00:01]Hello"},"tlyric":{"lyric":"[00:01]你好"}}"#] {
            body = try envelope(nested)
            let lyrics = try await api.lyric(source: "wy", songID: "123")
            XCTAssertEqual(lyrics.lrc?.lyric, "[00:01]Hello")
            XCTAssertEqual(lyrics.tlyric?.lyric, "[00:01]你好")
        }
        path = "/prefix/pic/wy/123"
        body = try envelope("https://media.example.test/cover.jpg")
        let cover = try await api.cover(source: "wy", songID: "123")
        XCTAssertEqual(cover.pathExtension, "jpg")
        path = "/prefix/url/wy/123/128k"
        for code in [1, 2, 3, 4, 5, 6, 200] {
            body = Data("{\"code\":\(code),\"msg\":\"constructed failure\",\"data\":null}".utf8)
            await expect(.business(code: code)) { _ = try await api.songURL(source: "wy", songID: "123", quality: .standard) }
        }
        for invalid in ["{}", "not json", #"{"code":0,"data":123}"#, #"{"code":0,"data":""}"#,
                        #"{"code":0,"data":"file:///tmp/song"}"#, #"{"code":0,"data":"https://"}"#] {
            body = Data(invalid.utf8)
            await expect(.invalidResponse) { _ = try await api.songURL(source: "wy", songID: "123", quality: .standard) }
        }
        for httpStatus in [401, 403, 429, 503] {
            status = httpStatus
            await expect(.httpStatus(httpStatus)) { _ = try await api.songURL(source: "wy", songID: "123", quality: .standard) }
        }
        let count = requests
        LXFixtureProtocol.handler = { _ in XCTFail("Unexpected network request"); throw URLError(.notConnectedToInternet) }
        await expect(.unsupportedQuality) { _ = try await provider.songURL(ids: [.source(id: "123", provider: .netease)], quality: .immersive) }
        for bad in ["", "../1", "a/b", "1?key=x", "a#b"] {
            await expect(.invalidIdentifier) {
                _ = try await provider.songURL(ids: [.source(id: "123", provider: .netease), .source(id: bad, provider: .lx)], quality: .standard)
            }
        }
        let unconfigured = LXMusicAPI(session: session, settings: { LXSourceSettings() })
        await expect(.notConfigured) { _ = try await unconfigured.songURL(source: "wy", songID: "123", quality: .standard) }
        let invalidBase = LXMusicAPI(session: session, settings: { LXSourceSettings(baseURL: "file:///tmp/lx") })
        await expect(.parseFailed) { _ = try await invalidBase.lyric(source: "wy", songID: "123") }
        let invalidSource = LXMusicProvider(api: LXMusicAPI(session: session, settings: { LXSourceSettings(platform: "unknown") }))
        await expect(.business(code: -2)) { _ = try await invalidSource.songURL(ids: [.source(id: "123", provider: .lx)], quality: .standard) }
        await expect(.business(code: -1)) { _ = try await provider.search("test", category: .songs, limit: 10, offset: 0) }
        await expect(.business(code: -1)) { _ = try await provider.searchSuggest("test") }
        await expect(.business(code: -1)) { _ = try await provider.searchDefaultKeyword() }
        await expect(.business(code: -1)) { _ = try await provider.toplists() }
        await expect(.business(code: -1)) { _ = try await provider.personalizedPlaylists(limit: 5) }
        await expect(.business(code: -1)) { _ = try await provider.songDetails(ids: []) }
        await expect(.business(code: -1)) { _ = try await provider.qrKey() }
        await expect(.business(code: -1)) { _ = try await provider.qrCheck("key") }
        await expect(.business(code: -1)) { try await provider.sendSMSCode(phone: "1", countryCode: "86") }
        await expect(.business(code: -1)) { try await provider.loginCellphone(phone: "1", captcha: "1", countryCode: "86") }
        XCTAssertEqual(requests, count)
        let empty = try await provider.songURL(ids: [], quality: .standard)
        XCTAssertTrue(empty.isEmpty)
    }

    func testAnonymousAuthenticationIsOmitted() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LXFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); LXFixtureProtocol.handler = nil }
        let response = try envelope("https://media.example.test/song.mp3")
        LXFixtureProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "X-LxM-Auth"))
            XCTAssertNil(request.url?.query)
            return (200, response)
        }
        let api = LXMusicAPI(session: session, settings: { LXSourceSettings(baseURL: "http://localhost:8080") })
        _ = try await api.songURL(source: "kg", songID: "ABC123", quality: .standard)
    }

    private func envelope(_ text: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["code": 0, "msg": "constructed fixture", "data": text])
    }

    private func expect(_ expected: LXAPIError, _ operation: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? LXAPIError, expected, file: file, line: line) }
    }
}

private final class LXFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.notConnectedToInternet) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
