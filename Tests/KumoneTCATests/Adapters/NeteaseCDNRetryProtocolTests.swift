#if os(macOS)
import Foundation
import APlay
import os
import XCTest
@testable import KumoneCore
@testable import KumoneTCA

final class NeteaseCDNRetryProtocolTests: XCTestCase {
    override func setUp() {
        super.setUp()
        NeteaseCDNHost.reset()
        CDNTransportStub.configure(mode: .dns)
    }

    private func makeProtocol(_ client: CDNProtocolClient) -> NeteaseCDNRetryProtocol {
        var request = URLRequest(url: URL(string: "https://m801.music.126.net/signed/song.mp3?token=original")!)
        request.setValue("bytes=1024-2047", forHTTPHeaderField: "Range")
        request.setValue("audio-test", forHTTPHeaderField: "User-Agent")
        let result = NeteaseCDNRetryProtocol(request: request, cachedResponse: nil, client: client)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CDNTransportStub.self]
        result.transportConfiguration = config
        return result
    }

    func testRetryPreservesSignedURLRangeAndHeadersAndStreamsOnce() {
        let client = CDNProtocolClient(done: expectation(description: "twin completes"))
        let loader = makeProtocol(client)
        loader.startLoading()
        wait(for: [client.done], timeout: 3)
        loader.stopLoading()
        let requests = CDNTransportStub.requests
        XCTAssertEqual(requests.map { $0.url?.host }, ["m801.music.126.net", "m801c.music.126.net"])
        for request in requests {
            XCTAssertEqual(request.url?.path, "/signed/song.mp3")
            XCTAssertEqual(request.url?.query, "token=original")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=1024-2047")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "audio-test")
        }
        XCTAssertEqual(client.data, Data([1, 2, 3, 4]))
        XCTAssertEqual(client.responses.count, 1)
        XCTAssertEqual(client.responses.first?.statusCode, 206)
        XCTAssertNil(client.error)
        XCTAssertEqual(NeteaseCDNHost.preferred(for: loader.request.url!).host, "m801c.music.126.net")
    }

    func testBothHostsUnreachableStopsAfterOneRetry() {
        CDNTransportStub.configure(mode: .bothDead)
        let client = CDNProtocolClient(done: expectation(description: "bounded failure"))
        let loader = makeProtocol(client)
        loader.startLoading()
        wait(for: [client.done], timeout: 3)
        loader.stopLoading()
        XCTAssertEqual(CDNTransportStub.requests.count, 2)
        XCTAssertNotNil(client.error)
        XCTAssertTrue(client.responses.isEmpty)
        XCTAssertTrue(client.data.isEmpty)
    }

    func testFailureAfterResponseIsNotReplayedOrDuplicated() {
        CDNTransportStub.configure(mode: .afterResponse)
        let client = CDNProtocolClient(done: expectation(description: "midstream error"))
        let loader = makeProtocol(client)
        loader.startLoading()
        wait(for: [client.done], timeout: 3)
        loader.stopLoading()
        XCTAssertEqual(CDNTransportStub.requests.count, 1)
        XCTAssertEqual(client.responses.count, 1)
        XCTAssertNotNil(client.error)
    }

    func testCancelledTransportReleasesProtocolOwner() {
        CDNTransportStub.configure(mode: .hang)
        let client = CDNProtocolClient(done: expectation(description: "no callback after cancel"))
        client.done.isInverted = true
        var loader: NeteaseCDNRetryProtocol? = makeProtocol(client)
        weak var weakLoader = loader
        loader?.startLoading()
        loader?.stopLoading()
        loader = nil
        wait(for: [client.done], timeout: 0.3)
        XCTAssertNil(weakLoader, "cancelled session must stop retaining its delegate")
    }

    func testCompletedTransportReleasesProtocolOwner() {
        let client = CDNProtocolClient(done: expectation(description: "complete"))
        var loader: NeteaseCDNRetryProtocol? = makeProtocol(client)
        weak var weakLoader = loader
        loader?.startLoading()
        wait(for: [client.done], timeout: 3)
        loader = nil
        let drained = expectation(description: "delegate callback drained")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertNil(weakLoader, "successful transfer must not retain its request owner")
    }

    func testRedirectTargetFailureDoesNotPoisonOriginalHost() {
        CDNTransportStub.configure(mode: .afterRedirect)
        let client = CDNProtocolClient(done: expectation(description: "redirect target fails"))
        let loader = makeProtocol(client)
        loader.startLoading()
        wait(for: [client.done], timeout: 3)
        loader.stopLoading()
        XCTAssertEqual(CDNTransportStub.requests.map { $0.url?.host }, ["m801.music.126.net", "redirect.invalid"])
        XCTAssertEqual(NeteaseCDNHost.preferred(for: loader.request.url!), loader.request.url!)
        XCTAssertNotNil(client.error)
    }

    func testOnlyNetEaseAudioRequestsAreIntercepted() {
        for url in ["https://example.com/a.mp3", "https://p1.music.126.net/cover.jpg", "file:///tmp/a.mp3"] {
            XCTAssertFalse(NeteaseCDNRetryProtocol.canInit(with: URLRequest(url: URL(string: url)!)))
        }
        let session = NeteaseCDNRetryProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        XCTAssertTrue(session.configuration.protocolClasses?.contains { $0 == NeteaseCDNRetryProtocol.self } == true)
        XCTAssertNil(session.configuration.urlCache, "no second HTTP audio cache")
    }

    func testRealAPlayTransportRetriesThenReopensOriginalCacheWithoutNetwork() throws {
        CDNTransportStub.configure(mode: .fullSong)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-cdn-aplay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = APlay.Configuration(logPolicy: .disable,
            cacheNaming: .custom { ($0.host ?? "local") + "-song" }, cacheDirectory: directory.path,
            sessionBuilder: { _ in
                let inner = URLSessionConfiguration.ephemeral
                inner.protocolClasses = [CDNRetryHarness.self]
                return URLSession(configuration: inner)
            })
        // CAF avoids APlay's separate ID3 tail probe, keeping this test about
        // the audio request/cache path rather than the metadata side request.
        let url = URL(string: "https://m801.music.126.net/signed/song.caf?token=original")!
        let count = OSAllocatedUnfairLock(initialState: 0)
        let observer = NSObject()
        for round in 0..<2 {
            let streamer = CacheAwareStreamProvider(config: config)
            let done = expectation(description: "APlay receives every byte round \(round)")
            let ended = expectation(description: "APlay emits EOF round \(round)")
            ended.assertForOverFulfill = true
            streamer.outputPipeline.delegate(to: observer) { _, event in
                switch event {
                case let .hasBytesAvailable(_, bytes, first):
                    let received = count.withLock { $0 += Int(bytes); return $0 }
                    if round == 1 && first { XCTAssertEqual(streamer.bufferingProgress, 1) }
                    if received == (round + 1) * 131_072 { done.fulfill() }
                case .endEncountered: ended.fulfill()
                case let .errorOccurred(error): XCTFail("APlay failed: \(error)")
                default: break
                }
            }
            let before = CDNTransportStub.requests.count
            streamer.open(url: url, at: 0)
            wait(for: [done, ended], timeout: 5)
            if round == 1 { XCTAssertEqual(CDNTransportStub.requests.count, before, "completed cache needs no network") }
            streamer.outputPipeline.removeDelegate()
            streamer.destroy()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(count.withLock { $0 }, 2 * 131_072, "each playback gets exactly one full byte stream")
        XCTAssertEqual(CDNTransportStub.requests.map { $0.url?.host }, ["m801.music.126.net", "m801c.music.126.net"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("m801.music.126.net-song").path))
        config.session.invalidateAndCancel()
        withExtendedLifetime(config) {}
    }
}

private final class CDNRetryHarness: NeteaseCDNRetryProtocol, @unchecked Sendable {
    override func startLoading() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CDNTransportStub.self]
        transportConfiguration = config
        super.startLoading()
    }
}

private final class CDNTransportStub: URLProtocol, @unchecked Sendable {
    enum Mode { case dns, bothDead, afterResponse, afterRedirect, fullSong, hang }
    private struct State { var mode: Mode; var requests: [URLRequest] = [] }
    private static let state = OSAllocatedUnfairLock(initialState: State(mode: .dns))
    static var requests: [URLRequest] { state.withLock { $0.requests } }
    static func configure(mode: Mode) { state.withLock { $0 = State(mode: mode) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let mode = Self.state.withLock { state in state.requests.append(request); return state.mode }
        if mode == .hang { return }
        if mode == .afterRedirect {
            if request.url?.host == "redirect.invalid" {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)); return
            }
            var redirected = request
            redirected.url = URL(string: "https://redirect.invalid/song.mp3")!
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": redirected.url!.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            return
        }
        if mode == .bothDead || ((mode == .dns || mode == .fullSong) && request.url?.host == "m801.music.126.net") {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)); return
        }
        if mode == .fullSong {
            let body = Data(repeating: 0x7f, count: 131_072)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(body.count)", "Content-Type": "audio/x-caf"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Range": "bytes 1024-1027/4096", "Content-Type": "audio/mpeg",
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if mode == .afterResponse {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        client?.urlProtocol(self, didLoad: Data([1, 2]))
        client?.urlProtocol(self, didLoad: Data([3, 4]))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class CDNProtocolClient: NSObject, URLProtocolClient, @unchecked Sendable {
    let done: XCTestExpectation
    private struct State { var data = Data(); var responses: [HTTPURLResponse] = []; var error: Error? }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var data: Data { state.withLock { $0.data } }
    var responses: [HTTPURLResponse] { state.withLock { $0.responses } }
    var error: Error? { state.withLock { $0.error } }
    init(done: XCTestExpectation) { self.done = done }
    func urlProtocol(_ protocol: URLProtocol, wasRedirectedTo request: URLRequest, redirectResponse: URLResponse) {}
    func urlProtocol(_ protocol: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) {}
    func urlProtocol(_ protocol: URLProtocol, didReceive response: URLResponse, cacheStoragePolicy policy: URLCache.StoragePolicy) {
        if let response = response as? HTTPURLResponse { state.withLock { $0.responses.append(response) } }
    }
    func urlProtocol(_ protocol: URLProtocol, didLoad data: Data) { state.withLock { $0.data.append(data) } }
    func urlProtocol(_ protocol: URLProtocol, didFailWithError error: Error) {
        state.withLock { $0.error = error }; done.fulfill()
    }
    func urlProtocolDidFinishLoading(_ protocol: URLProtocol) { done.fulfill() }
    func urlProtocol(_ protocol: URLProtocol, didReceive challenge: URLAuthenticationChallenge) {}
    func urlProtocol(_ protocol: URLProtocol, didCancel challenge: URLAuthenticationChallenge) {}
}
#endif
