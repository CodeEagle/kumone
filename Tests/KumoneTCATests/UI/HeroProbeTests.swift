import CoreGraphics
import Foundation
import Testing
@testable import KumoneTCA

@Suite("Hero transition measurement")
struct HeroProbeTests {
    private func record(
        source: CGRect? = CGRect(x: 20, y: 700, width: 38, height: 38),
        target: CGRect? = CGRect(x: 438, y: 300, width: 320, height: 320),
        landed: CGRect? = CGRect(x: 438, y: 300, width: 320, height: 320),
        sourceScale: CGFloat = 1,
        targetScale: CGFloat = 0.95,
        landedScale: CGFloat = 0.95,
        verdict: HeroProbe.Verdict? = nil
    ) -> HeroProbe.Record {
        HeroProbe.Record(
            id: "test",
            sourceFrame: source,
            targetFrame: target,
            landedFrame: landed,
            sourceScale: sourceScale,
            targetScale: targetScale,
            landedScale: landedScale,
            verdict: verdict
        )
    }

    @Test func exactLandingOnTargetPasses() {
        #expect(HeroProbe.judge(record: record()) == .pass)
    }

    @Test func landingWithinOnePointPasses() {
        let r = record(
            landed: CGRect(x: 438.6, y: 299.4, width: 320.5, height: 319.7),
            landedScale: 0.953
        )
        #expect(HeroProbe.judge(record: r) == .pass)
    }

    @Test func horizontalDriftBeyondToleranceFails() {
        let r = record(landed: CGRect(x: 441, y: 300, width: 320, height: 320))
        let verdict = HeroProbe.judge(record: r)
        #expect(verdict.isFailure)
        #expect(verdict.failureReason?.contains("origin") ?? false)
    }

    @Test func verticalDriftBeyondToleranceFails() {
        let r = record(landed: CGRect(x: 438, y: 303, width: 320, height: 320))
        #expect(HeroProbe.judge(record: r).isFailure)
    }

    @Test func sizeMismatchFails() {
        let r = record(landed: CGRect(x: 438, y: 300, width: 326, height: 320))
        let verdict = HeroProbe.judge(record: r)
        #expect(verdict.isFailure)
        #expect(verdict.failureReason?.contains("size") ?? false)
    }

    @Test func scaleMismatchBeyondToleranceFails() {
        let r = record(landedScale: 0.90)
        let verdict = HeroProbe.judge(record: r)
        #expect(verdict.isFailure)
        #expect(verdict.failureReason?.contains("scale") ?? false)
    }

    @Test func missingTargetGeometryFails() {
        #expect(HeroProbe.judge(record: record(target: nil)).isFailure)
    }

    @Test func missingLandedGeometryFails() {
        #expect(HeroProbe.judge(record: record(landed: nil)).isFailure)
    }

    @Test func customToleranceIsHonoured() {
        // A 3pt drift fails under the default 1pt tolerance but passes when the
        // test widens it, which is how a flaky settle gets triaged.
        var wide = HeroProbe.Tolerance()
        wide.position = 5
        let r = record(landed: CGRect(x: 441, y: 300, width: 320, height: 320))
        #expect(HeroProbe.judge(record: r).isFailure)
        #expect(HeroProbe.judge(record: r, tolerance: wide) == .pass)
    }

    @Test func formatReportsEveryMeasurement() {
        let line = HeroProbe.format(record(verdict: .pass))
        #expect(line.hasPrefix("HERO PASS test src="))
        #expect(line.contains("landed=(438.0,300.0,320.0,320.0)"))
        #expect(line.contains("scale src=1.000 tgt=0.950 landed=0.950"))
    }

    @Test func formatMarksUnjudgedRecords() {
        #expect(HeroProbe.format(record()).hasPrefix("HERO MEASURED test"))
    }

    @Test func formatReportsFailureReason() {
        let r = record(landed: CGRect(x: 441, y: 300, width: 320, height: 320))
        let judged = record(
            landed: CGRect(x: 441, y: 300, width: 320, height: 320),
            verdict: HeroProbe.judge(record: r)
        )
        let line = HeroProbe.format(judged)
        #expect(line.hasPrefix("HERO FAIL test"))
        #expect(line.contains("origin"))
    }

    @MainActor
    @Test func recordLandingJudgesAndArchives() {
        let probe = HeroProbe.shared
        let id = "unit-test-\(UUID().uuidString)"
        probe.begin(id)
        probe.recordSource(frame: CGRect(x: 20, y: 700, width: 38, height: 38), scale: 1)
        probe.recordTarget(frame: CGRect(x: 438, y: 300, width: 320, height: 320), scale: 0.95)
        let verdict = probe.recordLanding(frame: CGRect(x: 438, y: 300, width: 320, height: 320), scale: 0.95)

        #expect(verdict == .pass)
        let archived = probe.records.last { $0.id == id }
        #expect(archived?.verdict == .pass)
        #expect(archived?.sourceFrame == CGRect(x: 20, y: 700, width: 38, height: 38))
    }
}
