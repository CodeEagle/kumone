import Foundation
import Testing
@testable import KumoneCore

@Suite("Safe Double → Int conversion")
struct SafeIntConversionTests {
    @Test func wholeValueIsPreserved() {
        #expect((42.0).safeIntValue() == 42)
        #expect((0.0).safeIntValue() == 0)
    }

    @Test func fractionIsTruncatedTowardZero() {
        #expect((41.7).safeIntValue() == 41)
        #expect((999_999.9).safeIntValue() == 999_999)
        #expect((-1.5).safeIntValue() == -1)
        #expect((-999.9).safeIntValue() == -999)
    }

    @Test func negativeWholeValueIsPreserved() {
        #expect((-5.0).safeIntValue() == -5)
        #expect((-.pi).safeIntValue() == -3)
    }

    @Test func largeInRangeValueIsConverted() {
        #expect((1e18).safeIntValue() == 1_000_000_000_000_000_000)
    }

    @Test func hugeValueFallsBackInsteadOfTrapping() {
        #expect((1e30).safeIntValue() == 0)
        #expect((1e308).safeIntValue() == 0)
        #expect((-1e30).safeIntValue() == 0)
        #expect((Double.greatestFiniteMagnitude).safeIntValue() == 0)
    }

    @Test func nanAndInfinityFallBack() {
        #expect((Double.nan).safeIntValue() == 0)
        #expect((Double.infinity).safeIntValue() == 0)
        #expect((-Double.infinity).safeIntValue() == 0)
    }

    @Test func customFallbackIsHonored() {
        #expect((1e30).safeIntValue(or: -1) == -1)
        #expect((Double.nan).safeIntValue(or: -1) == -1)
    }

    @Test func decodedHugePlayCountDoesNotTrap() throws {
        // A legal JSON number that overflows Int; previously `Int(count)` trapped.
        let json = Data("""
            {"id": 1, "name": "x", "playCount": 1e30, "trackCount": 0}
            """.utf8)
        let summary = try #require(try JSONDecoder().decode(PlaylistSummary.self, from: json))
        #expect(summary.playCount == 0)

        let detail = try #require(try JSONDecoder().decode(
            PlaylistDetail.self,
            from: Data("""
                {"id": 1, "name": "x", "playCount": 1e30}
                """.utf8)))
        #expect(detail.playCount == 0)

        let toplist = try #require(try JSONDecoder().decode(
            ToplistItem.self,
            from: Data("""
                {"id": 1, "name": "x", "playCount": 1e30}
                """.utf8)))
        #expect(toplist.playCount == 0)
    }

    @Test func decodedFractionalPlayCountIsTruncated() throws {
        let summary = try #require(try JSONDecoder().decode(
            PlaylistSummary.self,
            from: Data("""
                {"id": 1, "name": "x", "playCount": 1234.9, "trackCount": 0}
                """.utf8)))
        #expect(summary.playCount == 1234)
    }
}
