import XCTest
@testable import KumoneTCA

final class AudioCacheLimitStopsTests: XCTestCase {
    func testElevenStopsCoverExistingCapacityRangeAndDefault() {
        XCTAssertEqual(AudioCacheLimitStops.valuesMB.count, 11)
        XCTAssertEqual(AudioCacheLimitStops.valuesMB.first, 64)
        XCTAssertEqual(AudioCacheLimitStops.valuesMB.last, 4095)
        XCTAssertEqual(AudioCacheLimitStops.megabytes(at: AudioCacheLimitStops.index(nearestTo: 256)), 256)
        XCTAssertEqual(AudioCacheLimitStops.valuesMB, AudioCacheLimitStops.valuesMB.sorted())
    }

    func testEveryStopRoundTripsAndSelectionClamps() {
        for (index, limit) in AudioCacheLimitStops.valuesMB.enumerated() {
            XCTAssertEqual(AudioCacheLimitStops.index(nearestTo: Double(limit)), index)
            XCTAssertEqual(AudioCacheLimitStops.megabytes(at: index), limit)
        }
        XCTAssertEqual(AudioCacheLimitStops.megabytes(at: -1), 64)
        XCTAssertEqual(AudioCacheLimitStops.megabytes(at: 11), 4095)
    }

    func testLegacyFineGrainedLimitSelectsNearestCapacityWithoutMutation() {
        XCTAssertEqual(AudioCacheLimitStops.index(nearestTo: 300), 2)
        XCTAssertEqual(AudioCacheLimitStops.index(nearestTo: 1000), 4)
    }
}
