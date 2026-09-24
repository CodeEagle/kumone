import ComposableArchitecture
import CryptoKit
import Dependencies
import Foundation
import Combine
import XCTest
import AppKit
import Testing
import KumoneCore
@testable import KumoneTCA

@Suite("Now Playing Artwork Store Tests")
@MainActor
struct NowPlayingArtworkStoreTests {
    @Test func latestArtworkRequestWins() async {
        let firstArtwork = artwork(color: .systemRed)
        let secondArtwork = artwork(color: .systemBlue)
        let store = NowPlayingArtworkStore { url in
            if url.absoluteString.contains("first-artwork") {
                try? await Task.sleep(nanoseconds: 20_000_000)
                return firstArtwork
            }
            return secondArtwork
        }
        store.setArtworkNeeded(true)

        store.update(
            trackID: 1,
            artworkURL: "https://example.com/first-artwork.jpg"
        )
        store.update(
            trackID: 2,
            artworkURL: "https://example.com/second-artwork.jpg"
        )
        try? await Task.sleep(nanoseconds: 40_000_000)

        #expect(store.trackID == 2)
        #expect(store.artwork === secondArtwork)
    }

    @Test func missingArtworkImmediatelyUsesFallback() {
        let store = NowPlayingArtworkStore { _ in artwork(color: .systemRed) }

        store.update(trackID: 1, artworkURL: nil)

        #expect(store.trackID == 1)
        #expect(store.artwork == nil)
        #expect(store.colors == .fallback)
    }

    @Test func failedArtworkLoadUsesFallback() async {
        let loaderCalls = ImageLoaderCallSignal()
        let store = NowPlayingArtworkStore { _ in
            await loaderCalls.record()
            return nil
        }
        store.setArtworkNeeded(true)

        store.update(
            trackID: 1,
            artworkURL: "https://example.com/missing-artwork.jpg"
        )
        await loaderCalls.waitForCall()

        #expect(store.trackID == 1)
        #expect(store.artwork == nil)
        #expect(store.colors == .fallback)
    }

    @Test func waitsForAConsumerBeforeLoadingArtwork() async {
        let loaderCalls = ImageLoaderCallSignal()
        let store = NowPlayingArtworkStore { _ in
            await loaderCalls.record()
            return nil
        }

        store.update(
            trackID: 1,
            artworkURL: "https://example.com/artwork.jpg"
        )

        #expect(await loaderCalls.callCount() == 0)

        store.setArtworkNeeded(true)
        await loaderCalls.waitForCall()

        #expect(await loaderCalls.callCount() == 1)
    }

    private func artwork(color: NSColor) -> PlatformImage {
        let image = PlatformImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        return image
    }
}

private actor ImageLoaderCallSignal {
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record() {
        count += 1
        let waiters = waiters
        self.waiters = []
        waiters.forEach { $0.resume() }
    }

    func waitForCall() async {
        guard count == 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func callCount() -> Int { count }
}

@MainActor
final class NowPlayingArtworkStoreCoverageTests: XCTestCase {
    func testDefaultInitializerStartsWithoutArtwork() {
        let store = NowPlayingArtworkStore()
        XCTAssertNil(store.trackID)
        XCTAssertNil(store.artwork)
        XCTAssertEqual(store.colors, .fallback)
        store.setArtworkNeeded(false)
        store.update(trackID: nil, artworkURL: nil)
        XCTAssertNil(store.artwork)
    }

    func testEnablingArtworkLoadsCurrentTrackAndIdenticalUpdatesDoNotReload() async {
        let loaded = expectation(description: "Current artwork is published")
        let duplicateLoad = expectation(description: "Identical inputs do not reload")
        duplicateLoad.isInverted = true
        let image = PlatformImage(size: NSSize(width: 2, height: 2))
        var calls = 0
        let store = NowPlayingArtworkStore { url in
            calls += 1
            XCTAssertEqual(url.absoluteString, "https://example.com/current.jpg?param=768y768")
            if calls > 1 { duplicateLoad.fulfill() }
            return image
        }
        let observation = store.$artwork.compactMap { $0 }.prefix(1).sink { _ in loaded.fulfill() }
        defer { observation.cancel() }
        store.update(trackID: 7, artworkURL: "https://example.com/current.jpg")
        XCTAssertEqual(calls, 0)
        store.setArtworkNeeded(false)
        store.setArtworkNeeded(true)
        await fulfillment(of: [loaded], timeout: 1)
        XCTAssertTrue(store.artwork === image)

        store.update(trackID: 7, artworkURL: "https://example.com/current.jpg")
        store.setArtworkNeeded(true)
        await fulfillment(of: [duplicateLoad], timeout: 0.05)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(store.artwork === image)
        XCTAssertEqual(store.trackID, 7)
        store.setArtworkNeeded(false)
        XCTAssertNil(store.artwork)
        XCTAssertEqual(store.colors, .fallback)
    }

    func testDefaultImageLoaderLoadsInlineArtwork() async throws {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
        let artworkURL = "https://example.com/inline-artwork-\(UUID()).png"
        let imageURL = try XCTUnwrap(artworkURL.resizedImageURL(768))
        let key = Insecure.MD5.hash(data: Data(imageURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let diskDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("im.missuo.Kumone/images", isDirectory: true)
        let diskPath = diskDirectory.appendingPathComponent(key)
        try FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        // Seed the default loader's disk cache so this test does not need the network.
        try XCTUnwrap(Data(base64Encoded: png)).write(to: diskPath, options: .atomic)
        defer { try? FileManager.default.removeItem(at: diskPath) }
        let loaded = expectation(description: "Default loader publishes inline artwork")
        let store = NowPlayingArtworkStore()
        let observation = store.$artwork.compactMap { $0 }.prefix(1).sink { _ in loaded.fulfill() }
        defer {
            observation.cancel()
            store.setArtworkNeeded(false)
        }
        store.update(trackID: 42, artworkURL: artworkURL)
        XCTAssertNil(store.artwork)
        store.setArtworkNeeded(true)
        await fulfillment(of: [loaded], timeout: 3)
        XCTAssertNotNil(store.artwork)
        XCTAssertEqual(store.trackID, 42)
    }

}
