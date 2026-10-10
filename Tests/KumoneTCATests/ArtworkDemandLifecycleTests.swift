import Combine
import XCTest
import KumoneCore
@testable import KumoneTCA

private final class WeakArtworkStoreReference {
    weak var value: NowPlayingArtworkStore?
    init(_ value: NowPlayingArtworkStore?) { self.value = value }
}

private final class WeakStoreArtwork {
    weak var image: PlatformImage?
    init(_ image: PlatformImage?) { self.image = image }
}

@MainActor
final class ArtworkDemandLifecycleTests: XCTestCase {
    func testTrackChangeReleasesPreviousArtworkBeforeNextLoadCompletes() async {
        let nextStarted = expectation(description: "next artwork loading")
        let nextCancelled = expectation(description: "next artwork cancelled")
        let store = NowPlayingArtworkStore { url in
            if url.path == "/first" { return PlatformImage() }
            nextStarted.fulfill()
            do { try await Task.sleep(for: .seconds(30)) }
            catch { nextCancelled.fulfill() }
            return nil
        }
        store.setArtworkNeeded(true)
        store.update(trackID: 1, artworkURL: "https://image.test/first")
        for _ in 0..<100 where store.artwork == nil { await Task.yield() }
        XCTAssertNotNil(store.artwork)
        let old = WeakStoreArtwork(store.artwork)
        store.update(trackID: 2, artworkURL: "https://image.test/second")
        XCTAssertNil(store.artwork)
        XCTAssertNil(old.image, "The previous cover must not wait for the next download to finish")
        await fulfillment(of: [nextStarted], timeout: 2)
        store.setArtworkNeeded(false)
        await fulfillment(of: [nextCancelled], timeout: 2)
    }
    func testDemandRequiresAnActualShaderUnlessDetailsAreVisible() {
        for enabled in [false, true] {
            for shaderID in [nil, "shader"] as [String?] {
                XCTAssertTrue(NowPlayingArtworkStore.needsArtwork(
                    backgroundEnabled: enabled, shaderID: shaderID, isNowPlayingPresented: true))
                XCTAssertEqual(NowPlayingArtworkStore.needsArtwork(
                    backgroundEnabled: enabled, shaderID: shaderID, isNowPlayingPresented: false),
                    enabled && shaderID != nil)
            }
        }
    }

    func testDroppingStoreCancelsPendingLoadWithoutRetainingOwner() async {
        let started = expectation(description: "load started")
        let cancelled = expectation(description: "load cancelled")
        var store: NowPlayingArtworkStore? = NowPlayingArtworkStore { _ in
            started.fulfill()
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancelled.fulfill() }
            return nil
        }
        let reference = WeakArtworkStoreReference(store)
        store?.setArtworkNeeded(true)
        store?.update(trackID: 1, artworkURL: "https://example.com/cover")
        await fulfillment(of: [started], timeout: 2)
        store = nil
        XCTAssertNil(reference.value)
        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testDisabledConsumerDoesNotLoadFollowingTracks() async {
        let started = expectation(description: "load started")
        let cancelled = expectation(description: "load cancelled")
        var calls = 0
        let store = NowPlayingArtworkStore { _ in
            calls += 1
            started.fulfill()
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancelled.fulfill() }
            return nil
        }
        store.setArtworkNeeded(true)
        store.update(trackID: 1, artworkURL: "https://example.com/first")
        await fulfillment(of: [started], timeout: 2)
        store.setArtworkNeeded(false)
        for id in 2...20 {
            store.update(trackID: id, artworkURL: "https://example.com/\(id)")
        }
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(calls, 1)
        XCTAssertNil(store.artwork)
    }

    #if os(macOS)
    func testCancellingUpdaterConsumerCancelsPublisherSubscription() async {
        let subscribed = expectation(description: "publisher subscribed")
        let cancelled = expectation(description: "publisher cancelled")
        let subject = PassthroughSubject<Bool, Never>()
        let stream = UpdaterAdapter.values(from: subject.handleEvents(
            receiveSubscription: { _ in subscribed.fulfill() },
            receiveCancel: { cancelled.fulfill() }))
        let consumer = Task { for await _ in stream {} }
        await fulfillment(of: [subscribed], timeout: 2)
        consumer.cancel()
        await consumer.value
        await fulfillment(of: [cancelled], timeout: 2)
    }
    #endif
}
