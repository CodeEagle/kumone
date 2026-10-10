import XCTest
import KumoneCore
import APlay
@testable import KumoneTCA

private final class WeakArtworkLoaderReference {
    weak var value: PlaybackArtworkLoader?
    init(_ value: PlaybackArtworkLoader?) { self.value = value }
}

final class PlaybackArtworkLoaderTests: XCTestCase {
    func testEngineMetadataCannotStartIndependentOriginalArtworkDownload() {
        let metadata = APlay.NowPlayingMetadata(title: "Track", artist: "Artist", album: "Album",
            artworkURL: "https://image.test/original-3000px.jpg", artwork: PlatformImage())
        let textOnly = PlaybackArtworkLoader.textOnlyMetadata(metadata)
        XCTAssertEqual(textOnly?.title, "Track")
        XCTAssertEqual(textOnly?.artist, "Artist")
        XCTAssertEqual(textOnly?.album, "Album")
        XCTAssertNil(textOnly?.artworkURL)
        XCTAssertNil(textOnly?.artwork)
        XCTAssertNotNil(metadata.artworkURL)
        XCTAssertNil(PlaybackArtworkLoader.textOnlyMetadata(nil))
    }
    func testCancelledOldTrackCannotPublishEvenWhenLoaderIgnoresCancellation() async {
        let started = expectation(description: "old started")
        let finished = expectation(description: "old finished")
        let stale = expectation(description: "stale publication")
        stale.isInverted = true
        let loader = PlaybackArtworkLoader { url in
            if url.lastPathComponent == "old" {
                started.fulfill()
                try? await Task.sleep(for: .seconds(10))
                finished.fulfill()
            }
            return nil
        }
        loader.load(URL(string: "https://example.com/old")!) { _ in stale.fulfill() }
        await fulfillment(of: [started], timeout: 2)
        let published = expectation(description: "new published")
        loader.load(URL(string: "https://example.com/new")!) { _ in published.fulfill() }
        await fulfillment(of: [finished, published], timeout: 2)
        await fulfillment(of: [stale], timeout: 0.05)
    }

    func testNilCoverCancelsPreviousRequest() async {
        let started = expectation(description: "started")
        let stale = expectation(description: "stale")
        stale.isInverted = true
        let loader = PlaybackArtworkLoader { _ in
            started.fulfill()
            try? await Task.sleep(for: .seconds(10))
            return nil
        }
        loader.load(URL(string: "https://example.com/cover")!) { _ in stale.fulfill() }
        await fulfillment(of: [started], timeout: 2)
        var nilPublished = false
        loader.load(nil) { image in nilPublished = image == nil }
        XCTAssertTrue(nilPublished)
        await fulfillment(of: [stale], timeout: 0.05)
    }

    func testPendingTaskDoesNotRetainOwner() async {
        let started = expectation(description: "started")
        var loader: PlaybackArtworkLoader? = PlaybackArtworkLoader { _ in
            started.fulfill()
            try? await Task.sleep(for: .seconds(10))
            return nil
        }
        let reference = WeakArtworkLoaderReference(loader)
        loader?.load(URL(string: "https://example.com/cover")!) { _ in }
        await fulfillment(of: [started], timeout: 2)
        loader = nil
        XCTAssertNil(reference.value)
    }
}
