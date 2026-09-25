import Foundation
import XCTest
@testable import KumoneCore

final class UnblockServiceTests: XCTestCase {
    private let track = Track(
        id: 123, name: "Fixture", artists: [],
        album: AlbumRef(id: 0, name: "Album", picUrl: nil),
        durationMS: 200_000, alias: [], transNames: [], fee: 0, mvID: 0,
        trackNo: 0, disc: nil, noCopyright: false, isCloud: false, embeddedPrivilege: nil)

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnblockLXFixtureProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        UnblockLXFixtureProtocol.handler = nil
        super.tearDown()
    }

    func testLXUnconfiguredReturnsNilWithoutRequest() async {
        UnblockLXFixtureProtocol.handler = { _ in
            XCTFail("An unconfigured LX source must not send a request")
            throw URLError(.badURL)
        }
        let api = LXMusicAPI(session: session, settings: { LXSourceSettings() })
        let result = await UnblockService.lx(track, api: api)
        XCTAssertNil(result, "nil allows resolve to continue to kugou/kuwo")
    }

    func testLXUsesOriginalNetEaseIDAndStandardQuality() async {
        let requested = expectation(description: "LX request replayed")
        UnblockLXFixtureProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.host, "lx.example.test")
            XCTAssertEqual(request.url?.path, "/prefix/url/wy/123/128k")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-LxM-Auth"), "fixture-key")
            requested.fulfill()
            return (200, Data(#"{"code":0,"msg":"constructed fixture","data":"https://media.example.test/song.mp3"}"#.utf8))
        }
        let api = configuredAPI()
        let result = await UnblockService.lx(track, api: api)
        XCTAssertEqual(result, URL(string: "https://media.example.test/song.mp3"))
        await fulfillment(of: [requested], timeout: 1)
    }

    func testLXHTTPAndBusinessErrorsReturnNil() async {
        for (status, body) in [
            (503, #"{"code":0,"msg":"fixture","data":"https://media.example.test/song.mp3"}"#),
            (200, #"{"code":5,"msg":"rate limited","data":null}"#),
            (200, #"{"code":0,"msg":"invalid URL","data":"not a URL"}"#)
        ] {
            UnblockLXFixtureProtocol.handler = { _ in (status, Data(body.utf8)) }
            let result = await UnblockService.lx(track, api: configuredAPI())
            XCTAssertNil(result, "Failure must allow subsequent fallback sources: \(status), \(body)")
        }
    }

    func testLXTransportErrorReturnsNil() async {
        UnblockLXFixtureProtocol.handler = { _ in throw URLError(.timedOut) }
        let result = await UnblockService.lx(track, api: configuredAPI())
        XCTAssertNil(result)
    }

    func testKuwoSearchFindsFirstNonemptyMusicPageAndEncodesKeyword() async {
        let page = #"{"musicpage":{"abslist":[{"MUSICRID":"MUSIC_42","DURATION":"200"}]}}"#
        for content in [
            "[\(page),null]",
            "[null,\(page)]",
            "[{\"musicpage\":null},\(page)]",
            "[{\"musicpage\":{\"abslist\":[]}},null,\(page)]"
        ] {
            let converted = expectation(description: "Kuwo conversion")
            UnblockLXFixtureProtocol.handler = { request in
                let url = try XCTUnwrap(request.url)
                let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
                let params = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
                if url.host == "search.kuwo.cn" {
                    XCTAssertEqual(params, ["correct": "1", "vipver": "1", "stype": "comprehensive",
                        "encoding": "utf8", "rformat": "json", "mobi": "1",
                        "show_copyright_off": "1", "searchapi": "6", "all": "A&B=C 中文 #? Artist"])
                    return (200, Data("{\"content\":\(content)}".utf8))
                }
                XCTAssertEqual(url.host, "antiserver.kuwo.cn")
                XCTAssertEqual(params["rid"], "MUSIC_42")
                converted.fulfill()
                return (200, Data("https://media.example.test/42.mp3".utf8))
            }
            let result = await UnblockService.kuwo(keywordTrack, session: session)
            XCTAssertEqual(result?.absoluteString, "https://media.example.test/42.mp3")
            await fulfillment(of: [converted], timeout: 1)
        }
    }

    func testFallbackDurationsRejectNegativeAndOverflowingSeconds() async {
        for seconds in [Int.min, -1, Int.max / 1000 + 1, Int.max] {
            for isKuwo in [true, false] {
                let converted = expectation(description: "Select valid duration")
                UnblockLXFixtureProtocol.handler = { request in
                    let url = try XCTUnwrap(request.url)
                    let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
                    let params = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
                    if url.host == "search.kuwo.cn" {
                        return (200, Data("{\"content\":[{\"musicpage\":{\"abslist\":[{\"MUSICRID\":\"MUSIC_bad\",\"DURATION\":\"\(seconds)\"},{\"MUSICRID\":\"MUSIC_good\",\"DURATION\":200}]}}]}".utf8))
                    }
                    if url.host == "mobilecdn.kugou.com" {
                        XCTAssertEqual(params, ["format": "json", "keyword": "A&B=C 中文 #? Artist", "page": "1", "pagesize": "10"])
                        return (200, Data("{\"data\":{\"info\":[{\"hash\":\"bad\",\"duration\":\(seconds)},{\"hash\":\"good\",\"duration\":200}]}}".utf8))
                    }
                    converted.fulfill()
                    if isKuwo {
                        XCTAssertEqual(params["rid"], "MUSIC_good")
                        return (200, Data("https://media.example.test/good.mp3".utf8))
                    }
                    XCTAssertEqual(url.host, "trackercdn.kugou.com")
                    XCTAssertEqual(params["hash"], "good")
                    return (200, Data(#"{"url":["https://media.example.test/good.mp3"]}"#.utf8))
                }
                let result: URL?
                if isKuwo {
                    result = await UnblockService.kuwo(keywordTrack, session: session)
                } else {
                    result = await UnblockService.kugou(keywordTrack, session: session)
                }
                XCTAssertEqual(result?.absoluteString, "https://media.example.test/good.mp3")
                await fulfillment(of: [converted], timeout: 1)
            }
        }
    }

    private var keywordTrack: Track {
        Track(id: 123, name: "A&B=C 中文 #?", artists: [ArtistRef(id: 1, name: "Artist")],
            album: track.album, durationMS: 200_000, alias: [], transNames: [], fee: 0,
            mvID: 0, trackNo: 0, disc: nil, noCopyright: false, isCloud: false,
            embeddedPrivilege: nil)
    }

    private func configuredAPI() -> LXMusicAPI {
        LXMusicAPI(session: session, settings: {
            // The fallback must use wy even when the standalone LX provider uses QQ.
            LXSourceSettings(baseURL: "https://lx.example.test/prefix", apiKey: "fixture-key", platform: "tx")
        })
    }
}

/// Constructed contract responses, not recordings from a deployed LX service.
private final class UnblockLXFixtureProtocol: URLProtocol {
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
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
