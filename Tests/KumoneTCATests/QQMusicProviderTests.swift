import Foundation
import XCTest
@testable import KumoneCore

final class QQMusicProviderTests: XCTestCase {
    /// One sequential test keeps the URLProtocol handler local to this suite's lifetime.
    func testVerifiedAnonymousCapabilitiesAndFailures() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QQFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer {
            session.invalidateAndCancel()
            QQFixtureProtocol.handler = nil
        }
        let api = QQMusicAPI(session: session)
        let provider = QQMusicProvider(api: api)
        var expectedModule = "music.musicsearch.HotkeyService"
        var expectedMethod = "GetHotkeyForQQMusicMobile"
        var expectedParams: [String: Int] = [:]
        var response = try fixture("hotkey")
        var status = 200
        QQFixtureProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://u.y.qq.com/cgi-bin/musicu.fcg")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://y.qq.com/")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("Chrome/120.0.0.0") == true)
            XCTAssertEqual(request.timeoutInterval, 30)
            let body: Data
            if let data = request.httpBody { body = data } else {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                body = data
            }
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let comm = try XCTUnwrap(json["comm"] as? [String: Any])
            XCTAssertEqual(comm["ct"] as? Int, 24)
            XCTAssertEqual(comm["cv"] as? Int, 4747474)
            XCTAssertEqual(comm["g_tk"] as? Int, 5381)
            XCTAssertEqual(comm["uin"] as? String, "0")
            XCTAssertEqual(comm["platform"] as? String, "yqq.json")
            XCTAssertEqual(comm["format"] as? String, "json")
            let call = try XCTUnwrap(json["req_0"] as? [String: Any])
            XCTAssertEqual(call["module"] as? String, expectedModule)
            XCTAssertEqual(call["method"] as? String, expectedMethod)
            let params = try XCTUnwrap(call["param"] as? [String: Any])
            for (key, value) in expectedParams { XCTAssertEqual(params[key] as? Int, value) }
            if expectedMethod == "GetHotkeyForQQMusicMobile" {
                XCTAssertFalse((params["search_id"] as? String ?? "").isEmpty)
            }
            if expectedMethod == "GetPlayLyricInfo" {
                XCTAssertEqual(params["songMID"] as? String, "0009bt6G3LvTNk")
            }
            return (status, response)
        }
        let hotkeys = try await api.hotkeys()
        XCTAssertEqual(hotkeys.count, 30)
        let keyword = try await provider.searchDefaultKeyword()
        XCTAssertEqual(keyword, "周深 自己就是自己的光")

        expectedModule = "music.musicToplist.Toplist"
        expectedMethod = "GetAll"
        response = try fixture("toplist")
        let charts = try await provider.toplists()
        XCTAssertEqual(charts.count, 30)
        XCTAssertEqual(charts.first?.id, .source(id: "62", provider: .qq))
        XCTAssertEqual(charts.first?.name, "飙升榜")
        XCTAssertNil(charts.first?.coverURL) // The verified response omits picUrl.

        expectedMethod = "GetDetail"
        expectedParams = ["topId": 62, "offset": 0, "num": 10]
        response = try fixture("toplist-detail")
        let songs = try await api.toplistDetail(topId: 62, offset: 0, num: 10)
        let song = try XCTUnwrap(songs.first)
        XCTAssertEqual(song.musicID, .source(id: "0009bt6G3LvTNk", provider: .qq))
        XCTAssertEqual(song.track.id, 725476373)
        XCTAssertEqual(song.track.name, "恋恋不忘")
        XCTAssertEqual(song.track.artists.first?.name, "刘宇")
        XCTAssertEqual(song.track.album.id, 102493726)
        XCTAssertEqual(song.track.durationMS, 232000)

        expectedModule = "music.playlist.PlaylistSquare"
        expectedMethod = "GetRecommendFeed"
        expectedParams = ["From": 0, "Size": 10]
        response = try fixture("recommend-feed")
        let playlists = try await provider.personalizedPlaylists(limit: 10)
        XCTAssertEqual(playlists.first?.id, 8643520573)
        XCTAssertEqual(playlists.first?.trackCount, 1753)
        XCTAssertEqual(playlists.first?.playCount, 38454202)
        XCTAssertNotNil(playlists.first?.coverURL)
        expectedParams = ["From": 20, "Size": 10]
        _ = try await api.recommendFeed(from: 20, size: 10)

        expectedModule = "music.musichallSong.PlayLyricInfo"
        expectedMethod = "GetPlayLyricInfo"
        expectedParams = [:]
        response = try fixture("lyric")
        let mid = MusicID.source(id: "0009bt6G3LvTNk", provider: .qq)
        let lyrics = try await provider.lyric(id: mid)
        XCTAssertTrue(lyrics.lrc?.lyric?.contains("[00:00.00]恋恋不忘") == true)
        response = Data(#"{"code":0,"req_0":{"code":0,"data":{"lyric":"!invalid!","trans":"WzAwOjAxXWhlbGxv","roma":"/w=="}}}"#.utf8)
        let partial = try await provider.lyric(id: mid)
        XCTAssertNil(partial.lrc)
        XCTAssertEqual(partial.tlyric?.lyric, "[00:01]hello")
        XCTAssertNil(partial.romalrc)
        response = Data(#"{"code":0,"req_0":{"code":0,"data":{}}}"#.utf8)
        let empty = try await provider.lyric(id: mid)
        XCTAssertNil(empty.lrc)

        for (json, expected) in [
            (#"{"code":2001,"req_0":{"code":0,"data":[]}}"#, QQMusicAPIError.business(code: 2001)),
            (#"{"code":0,"req_0":{"code":2001,"data":[]}}"#, .business(code: 2001)),
            (#"{"code":0,"req_0":{"code":0}}"#, .invalidResponse),
            (#"{"code":0}"#, .invalidResponse),
            (#"{"req_0":{"code":0}}"#, .invalidResponse),
            ("<html>not JSON</html>", .invalidResponse),
            (#"{"code":"invalid"}"#, .invalidResponse),
            (#"{"code":0,"req_0":{"code":0,"data":{"lyric":42}}}"#, .invalidResponse)
        ] {
            response = Data(json.utf8)
            do { _ = try await provider.lyric(id: mid); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? QQMusicAPIError, expected) }
        }
        status = 503
        do { _ = try await provider.lyric(id: mid); XCTFail("Expected HTTP failure") }
        catch { XCTAssertEqual(error as? QQMusicAPIError, .httpStatus(503)) }
        QQFixtureProtocol.handler = { _ in throw URLError(.timedOut) }
        do { _ = try await provider.lyric(id: mid); XCTFail("Expected transport failure") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        // These methods must fail before attempting transport.
        QQFixtureProtocol.handler = { _ in XCTFail("Unexpected network request"); throw URLError(.badURL) }
        do { _ = try await provider.search("test", category: .songs, limit: 10, offset: 0); XCTFail() }
        catch { XCTAssertEqual(error as? QQMusicAPIError, .searchUnavailable) }
        do { _ = try await provider.songURL(ids: [mid], quality: .standard); XCTFail() }
        catch { XCTAssertEqual(error as? QQMusicAPIError, .loginRequired) }
        do { _ = try await provider.lyric(id: .source(id: "123", provider: .netease)); XCTFail() }
        catch { XCTAssertEqual(error as? QQMusicAPIError, .invalidIdentifier) }
        let zero = try await provider.personalizedPlaylists(limit: 0)
        XCTAssertTrue(zero.isEmpty)
    }

    func testSongDurationBoundaries() throws {
        for (seconds, expected) in [
            (Int.min, 0), (-1, 0), (0, 0), (232, 232_000),
            (Int.max / 1000, (Int.max / 1000) * 1000),
            (Int.max / 1000 + 1, 0), (Int.max, 0)
        ] {
            let data = Data("{\"id\":1,\"mid\":\"fixture\",\"interval\":\(seconds)}".utf8)
            let song = try JSONDecoder().decode(QQMusicAPI.Song.self, from: data)
            XCTAssertEqual(song.track.durationMS, expected, "seconds: \(seconds)")
        }
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/QQ/\(name).json"))
    }
}

private final class QQFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
