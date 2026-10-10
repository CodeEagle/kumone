import XCTest
import Foundation
@testable import KumoneCore

private final class PendingArtworkProtocol: URLProtocol {
    static let lock = NSLock()
    static var onStart: (() -> Void)?
    static var onStop: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.onStart }?() }
    override func stopLoading() { Self.lock.withLock { Self.onStop }?() }
}

final class ImageCacheCancellationTests: XCTestCase {
    func testDiagnosticDisablesDownloadsAndCancelsExistingFlight() async {
        let (cache, session, directory) = makeCache()
        defer {
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: directory)
            PendingArtworkProtocol.lock.withLock {
                PendingArtworkProtocol.onStart = nil
                PendingArtworkProtocol.onStop = nil
            }
        }
        let started = expectation(description: "first download starts")
        let stopped = expectation(description: "diagnostic stops download")
        PendingArtworkProtocol.lock.withLock {
            PendingArtworkProtocol.onStart = { started.fulfill() }
            PendingArtworkProtocol.onStop = { stopped.fulfill() }
        }
        let url = URL(string: "https://artwork.test/diagnostic")!
        let task = Task { await cache.image(for: url) }
        await fulfillment(of: [started], timeout: 2)
        await cache.setLoadingDisabled(true)
        await fulfillment(of: [stopped], timeout: 2)
        let result = await task.value
        XCTAssertNil(result)
        let blocked = await cache.image(for: url)
        XCTAssertNil(blocked)
        XCTAssertNil(cache.cachedImage(for: url))
        let pending = await cache.pendingWaiterCount
        XCTAssertEqual(pending, 0)

        let restarted = expectation(description: "reenabling starts download")
        PendingArtworkProtocol.lock.withLock {
            PendingArtworkProtocol.onStart = { restarted.fulfill() }
            PendingArtworkProtocol.onStop = nil
        }
        await cache.setLoadingDisabled(false)
        let next = Task { await cache.image(for: url) }
        await fulfillment(of: [restarted], timeout: 2)
        next.cancel()
        _ = await next.value
    }
    private func makeCache() -> (ImageCache, URLSession, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PendingArtworkProtocol.self]
        let session = URLSession(configuration: config)
        return (ImageCache(diskURL: directory, session: session), session, directory)
    }

    private func waitForWaiters(_ count: Int, cache: ImageCache) async -> Bool {
        for _ in 0..<200 {
            if await cache.pendingWaiterCount == count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    func testLastConsumerCancellationStopsActualURLSessionDownload() async {
        let (cache, session, directory) = makeCache()
        defer {
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: directory)
            PendingArtworkProtocol.lock.withLock {
                PendingArtworkProtocol.onStart = nil
                PendingArtworkProtocol.onStop = nil
            }
        }
        let started = expectation(description: "download started")
        let stopped = expectation(description: "download stopped")
        PendingArtworkProtocol.lock.withLock {
            PendingArtworkProtocol.onStart = { started.fulfill() }
            PendingArtworkProtocol.onStop = { stopped.fulfill() }
        }
        let task = Task { await cache.image(for: URL(string: "https://artwork.test/old")!) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [stopped], timeout: 2)
        let image = await task.value
        XCTAssertNil(image)
        let empty = await waitForWaiters(0, cache: cache)
        XCTAssertTrue(empty)
    }

    func testCancellingOneConsumerKeepsSharedDownloadAlive() async {
        let (cache, session, directory) = makeCache()
        defer {
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: directory)
            PendingArtworkProtocol.lock.withLock {
                PendingArtworkProtocol.onStart = nil
                PendingArtworkProtocol.onStop = nil
            }
        }
        let started = expectation(description: "single coalesced download")
        started.assertForOverFulfill = true
        let stopped = expectation(description: "last consumer stopped download")
        var stopCount = 0
        PendingArtworkProtocol.lock.withLock {
            PendingArtworkProtocol.onStart = { started.fulfill() }
            PendingArtworkProtocol.onStop = {
                PendingArtworkProtocol.lock.withLock { stopCount += 1 }
                stopped.fulfill()
            }
        }
        let url = URL(string: "https://artwork.test/shared")!
        let first = Task { await cache.image(for: url) }
        await fulfillment(of: [started], timeout: 2)
        let second = Task { await cache.image(for: url) }
        let joined = await waitForWaiters(2, cache: cache)
        XCTAssertTrue(joined)
        first.cancel()
        let stillNeeded = await waitForWaiters(1, cache: cache)
        XCTAssertTrue(stillNeeded)
        // The first waiter remains suspended until the shared request ends;
        // cancelling it must not cancel the second waiter's network task.
        XCTAssertEqual(PendingArtworkProtocol.lock.withLock { stopCount }, 0)
        second.cancel()
        await fulfillment(of: [stopped], timeout: 2)
        let firstImage = await first.value
        let secondImage = await second.value
        XCTAssertNil(firstImage)
        XCTAssertNil(secondImage)
        let empty = await waitForWaiters(0, cache: cache)
        XCTAssertTrue(empty)
    }
}
