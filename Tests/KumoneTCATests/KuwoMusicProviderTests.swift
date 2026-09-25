import Foundation
import XCTest
@testable import KumoneCore

final class KuwoMusicProviderTests: XCTestCase {
    func testVerifiedAnonymousCapabilitiesAndFailures() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [KuwoFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); KuwoFixtureProtocol.handler = nil }
        let api = KuwoMusicAPI(session: session)
        let provider = KuwoMusicProvider(api: api)
        var response = try fixture("search.json")
        var status = 200
        var host = "search.kuwo.cn"
        var path = "/r.s"
        var query = ["all": "Adele & 你好", "pn": "0", "rn": "5", "stype": "comprehensive", "searchapi": "6"]
        KuwoFixtureProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.host, host)
            XCTAssertEqual(request.url?.path, path)
            XCTAssertEqual(request.timeoutInterval, 30)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "http://www.kuwo.cn/")
            XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("Chrome/120.0.0.0") == true)
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            for (key, value) in query { XCTAssertEqual(items.first { $0.name == key }?.value, value) }
            return (status, response)
        }
        let page = try await api.search(keyword: "Adele & 你好", limit: 5, offset: 0)
        let song = try XCTUnwrap(page.abslist.first)
        XCTAssertEqual(song.musicID, .source(id: "6686351", provider: .kuwo))
        XCTAssertEqual(song.musicID.sourceID, "6686351")
        XCTAssertEqual(song.track.id, 6686351)
        XCTAssertEqual(song.track.name, "Hello")
        XCTAssertEqual(song.track.artists.first?.name, "Adele")
        XCTAssertEqual(song.track.album.id, 519830)
        XCTAssertEqual(song.track.album.name, "25")
        XCTAssertEqual(song.track.album.picUrl, "https://img1.kuwo.cn/star/albumcover/120/s4s55/55/3847750561.jpg")
        XCTAssertEqual(song.track.durationMS, 295000)
        let result = try await provider.search("Adele & 你好", category: .songs, limit: 5, offset: 0)
        XCTAssertEqual(result.songs.count, 5)
        XCTAssertEqual(result.counts.songs, 3324)
        let suggestions = try await provider.searchSuggest("Adele & 你好")
        XCTAssertEqual(suggestions.songs.map(\.name), result.songs.map(\.name))
        let sliced = try await api.search(keyword: "Adele & 你好", limit: 3, offset: 2)
        XCTAssertEqual(sliced.abslist.map(\.musicID), Array(page.abslist.dropFirst(2).map(\.musicID)))

        host = "antiserver.kuwo.cn"; path = "/anti.s"
        query = ["type": "convert_url", "format": "mp3", "response": "url", "rid": "MUSIC_6686351"]
        response = try fixture("convert-url.txt")
        let expectedURL = String(data: response, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
        let rid = MusicID.source(id: "6686351", provider: .kuwo)
        for quality: SongQuality in [.standard, .high, .lossless, .hires, .immersive] {
            let urls = try await provider.songURL(ids: [rid], quality: quality)
            XCTAssertEqual(urls.first?.url, expectedURL)
            XCTAssertEqual(urls.first?.id, 6686351)
            XCTAssertEqual(urls.first?.br, 128000)
            XCTAssertEqual(urls.first?.type, "mp3")
            XCTAssertEqual(urls.first?.level, "standard")
        }
        response = Data("\"\(expectedURL)$ignored\"\n".utf8)
        let parsed = try await api.playURL(rid: "6686351")
        XCTAssertEqual(parsed.absoluteString, expectedURL)
        for body in ["", "not available", "{\"code\":403}"] {
            response = Data(body.utf8)
            await expect(.invalidResponse) { _ = try await api.playURL(rid: "6686351") }
        }
        status = 503
        await expect(.httpStatus(503)) { _ = try await api.playURL(rid: "6686351") }
        status = 200
        host = "kbangserver.kuwo.cn"; path = "/ksong.s"
        query = ["id": "93", "rn": "5", "pn": "0", "data": "content"]
        response = try fixture("bang-93.json")
        let bang = try await api.bangContent(id: "93", offset: 0, num: 5)
        XCTAssertEqual(bang.musiclist.count, 5)
        XCTAssertEqual(bang.musiclist.first?.musicID, .source(id: "651031866", provider: .kuwo))
        XCTAssertEqual(bang.musiclist.first?.track.name, "红尘误此生")
        XCTAssertEqual(bang.musiclist.first?.track.durationMS, 225000)
        let bangSlice = try await api.bangContent(id: "93", offset: 2, num: 3)
        XCTAssertEqual(bangSlice.musiclist.map(\.musicID), Array(bang.musiclist.dropFirst(2).map(\.musicID)))
        let fixtures = try ["93", "16", "17"].reduce(into: [String: Data]()) { $0[$1] = try fixture("bang-\($1).json") }
        KuwoFixtureProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "kbangserver.kuwo.cn")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let id = items.first { $0.name == "id" }!.value!
            return (200, fixtures[id]!)
        }
        let charts = try await provider.toplists()
        XCTAssertEqual(charts.map(\.id.sourceID), ["93", "16", "17"])
        XCTAssertEqual(charts.map(\.name), ["酷我飙升榜", "酷我热歌榜", "酷我新歌榜"])
        XCTAssertTrue(charts.allSatisfy { $0.updateFrequency == "2026-09-25" && $0.coverURL != nil })
        for (body, error) in [("{}", KuwoAPIError.invalidResponse), ("{\"code\":401}", .business(code: 401)),
                              ("{\"success\":false}", .unavailable), ("garbage", .invalidResponse)] {
            KuwoFixtureProtocol.handler = { _ in (200, Data(body.utf8)) }
            await expect(error) { _ = try await api.search(keyword: "test", limit: 5, offset: 0) }
        }
        KuwoFixtureProtocol.handler = { _ in (200, Data(#"{"content":[null,{"other":[]},{"musicpage":{"abslist":[]}}]}"#.utf8)) }
        let empty = try await api.search(keyword: "empty", limit: 5, offset: 0)
        XCTAssertTrue(empty.abslist.isEmpty)
        KuwoFixtureProtocol.handler = { _ in XCTFail("Unexpected network request"); throw URLError(.badURL) }
        await expect(.lyricUnavailable) { _ = try await provider.lyric(id: rid) }
        await expect(.playlistUnavailable) { _ = try await provider.personalizedPlaylists(limit: 5) }
        await expect(.unavailable) { _ = try await provider.songDetails(ids: [rid]) }
        await expect(.unavailable) { _ = try await provider.searchDefaultKeyword() }
        await expect(.searchCategoryUnavailable) { _ = try await provider.search("test", category: .albums, limit: 5, offset: 0) }
        await expect(.invalidIdentifier) { _ = try await provider.songURL(ids: [rid, .source(id: "1", provider: .qq)], quality: .standard) }
        for bad in ["", "MUSIC_1", "-1", "0", "1&x=2", String(repeating: "9", count: 40)] {
            await expect(.invalidIdentifier) { _ = try await api.playURL(rid: bad) }
        }
        for (limit, offset) in [(0, 0), (5, -1), (Int.max, 1), (1, Int.max)] {
            await expect(.invalidPagination) { _ = try await api.search(keyword: "test", limit: limit, offset: offset) }
            await expect(.invalidPagination) { _ = try await api.bangContent(id: "93", offset: offset, num: limit) }
        }
        let noURLs = try await provider.songURL(ids: [], quality: .standard)
        XCTAssertTrue(noURLs.isEmpty)
        let generic: any MusicProvider = provider
        XCTAssertNil(generic as? any MusicPersonalFM)
        XCTAssertNil(generic as? any MusicCloudStorage)
        XCTAssertNil(generic as? any MusicIntelligence)
        XCTAssertNil(generic as? any MusicPlayHistory)
    }

    private func expect(_ expected: KuwoAPIError, _ operation: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? KuwoAPIError, expected, file: file, line: line) }
    }
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Kuwo/\(name)"))
    }
}

private final class KuwoFixtureProtocol: URLProtocol {
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
