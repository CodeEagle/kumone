import Foundation
import Testing
@testable import KumoneCore

@Suite("Recently Played Filter")
struct RecentlyPlayedStoreTests {

    private func track(_ id: Int) throws -> Track {
        try JSONDecoder().decode(
            Track.self,
            from: Data("""
            {"id":\(id),"name":"T\\(id)","ar":[],"al":{"id":1,"name":"Album"},"dt":1000}
            """.utf8))
    }

    @Test func filtersOutRecentlyPlayed() async throws {
        let store = RecentlyPlayedStore(days: 30, enabled: true, storeURL: nil)
        await store.record(trackID: 1)
        let kept = await store.filter([try track(1), try track(2)])
        #expect(kept.map(\.id) == [2])
    }

    @Test func keepsEverythingWhenDisabled() async throws {
        let store = RecentlyPlayedStore(days: 30, enabled: false, storeURL: nil)
        await store.record(trackID: 1)
        let kept = await store.filter([try track(1), try track(2)])
        #expect(kept.map(\.id) == [1, 2])
    }

    @Test func keepsEverythingWhenRetentionIsZero() async throws {
        let store = RecentlyPlayedStore(days: 0, enabled: true, storeURL: nil)
        await store.record(trackID: 1)
        let kept = await store.filter([try track(1), try track(2)])
        #expect(kept.map(\.id) == [1, 2])
    }

    @Test func prunesEntriesPastTheWindow() async throws {
        let clock = TestClock(1_000_000)
        let store = RecentlyPlayedStore(days: 2, enabled: true,
                                        clock: { clock.date }, storeURL: nil)
        await store.record(trackID: 1)
        clock.advanceDays(3)  // 3 days later, a 2-day entry has expired
        let kept = await store.filter([try track(1), try track(2)])
        #expect(kept.map(\.id) == [1, 2])
    }

    @Test func replayingASongRefreshesItsWindow() async throws {
        let clock = TestClock(1_000_000)
        let store = RecentlyPlayedStore(days: 2, enabled: true,
                                        clock: { clock.date }, storeURL: nil)
        await store.record(trackID: 1)
        clock.advanceDays(1)
        await store.record(trackID: 1)  // refresh
        clock.advanceDays(1)            // 2 days since the *refresh*, still fresh
        let kept = await store.filter([try track(1)])
        #expect(kept.isEmpty)
    }

    @Test func persistsAcrossInstances() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kumone-recently-played-\(UUID().uuidString).json")
        let writer = RecentlyPlayedStore(days: 30, enabled: true, storeURL: url)
        await writer.record(trackID: 42)
        let reader = RecentlyPlayedStore(days: 30, enabled: true, storeURL: url)
        let kept = await reader.filter([try track(42), try track(43)])
        #expect(kept.map(\.id) == [43])
        try? FileManager.default.removeItem(at: url)
    }
}

/// Mutable, injectable clock so tests can advance time past the window.
private final class TestClock: @unchecked Sendable {
    var since1970: TimeInterval
    init(_ since1970: TimeInterval) { self.since1970 = since1970 }
    func advanceDays(_ days: Double) { since1970 += days * 86_400 }
    var date: Date { Date(timeIntervalSince1970: since1970) }
}
