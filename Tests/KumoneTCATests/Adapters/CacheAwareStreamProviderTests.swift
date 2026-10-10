import APlay
import Foundation
import XCTest
@testable import KumoneTCA

final class CacheAwareStreamProviderTests: XCTestCase {
    func testCompleteLocalCacheIsAlreadyFullyAvailable() {
        let info = StreamProvider.URLInfo.local(URL(fileURLWithPath: "/tmp/completed-cache"), .mp3)
        for progress: Float in [0, 0.1, 0.5, 0.99, 1] {
            XCTAssertEqual(CacheAwareStreamProvider.availableProgress(info: info, contentLength: 100_000, readProgress: progress), 1)
        }
    }

    func testSparseResumeAndRemoteProgressAreNeverForcedFull() {
        let partial = StreamProvider.URLInfo.local(URL(fileURLWithPath: "/tmp/cache.part"), .mp3)
        let remote = StreamProvider.URLInfo.remote(URL(string: "https://test.invalid/track.mp3")!, .mp3)
        for info in [partial, remote] {
            for progress: Float in [0, 0.1, 0.5, 0.99] {
                XCTAssertEqual(CacheAwareStreamProvider.availableProgress(info: info, contentLength: 100_000, readProgress: progress), progress)
            }
        }
    }

    func testUnknownOrEmptyLocalFileIsNotACacheHit() {
        let local = StreamProvider.URLInfo.local(URL(fileURLWithPath: "/tmp/empty"), .mp3)
        XCTAssertEqual(CacheAwareStreamProvider.availableProgress(info: local, contentLength: 0, readProgress: 0), 0)
        XCTAssertEqual(CacheAwareStreamProvider.availableProgress(info: .none, contentLength: 0, readProgress: 0), 0)
    }

    func testRealUpstreamReopensCompletedCacheWithoutNetworkAndFirstPacketIsFull() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-buffer-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let remoteURL = URL(string: "https://nonexistent.invalid/already-downloaded.mp3")!
        let cachedURL = directory.appendingPathComponent("completed")
        try Data(repeating: 0x7f, count: 1_000_000).write(to: cachedURL)
        let config = APlay.Configuration(logPolicy: .disable, cacheNaming: .custom { _ in "completed" }, cacheDirectory: directory.path)
        for _ in 0..<2 {
            let streamer = CacheAwareStreamProvider(config: config)
            let firstPacket = expectation(description: "reads cached local bytes, no working network endpoint")
            let ended = expectation(description: "local EOF")
            let observer = NSObject()
            streamer.outputPipeline.delegate(to: observer) { _, event in
                switch event {
                case let .hasBytesAvailable(_, _, first):
                    if first {
                        XCTAssertEqual(streamer.info.url, cachedURL)
                        XCTAssertFalse(streamer.info.isRemote)
                        XCTAssertEqual(streamer.bufferingProgress, 1)
                        firstPacket.fulfill()
                    }
                case .endEncountered: ended.fulfill()
                case .errorOccurred: XCTFail("a completed cache must not require the unreachable HTTP origin")
                default: break
                }
            }
            streamer.open(url: remoteURL, at: 0)
            wait(for: [firstPacket, ended], timeout: 5)
            streamer.outputPipeline.removeDelegate()
            streamer.destroy()
            // The upstream close is queued and retains its unowned config.
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        withExtendedLifetime(config) {}
    }
}
