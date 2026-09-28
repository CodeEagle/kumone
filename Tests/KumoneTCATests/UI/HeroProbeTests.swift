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
        viewport: CGRect? = nil,
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
            viewportFrame: viewport,
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

    @Test func targetMeasuredOffScreenFails() {
        // The Now Playing slide-in regression: the gate locked the target on
        // the transition's first frame, so the target (and the stand-in that
        // matched it exactly) sat below the window. Geometry alone scored it a
        // pass; the viewport check has to catch it.
        let r = record(
            target: CGRect(x: 438, y: 900, width: 320, height: 320),
            landed: CGRect(x: 438, y: 900, width: 320, height: 320),
            viewport: CGRect(x: 0, y: 0, width: 800, height: 750)
        )
        let verdict = HeroProbe.judge(record: r)
        #expect(verdict.isFailure)
        #expect(verdict.failureReason?.contains("target off-screen") ?? false)
    }

    @Test func sourceOffScreenFails() {
        let r = record(
            source: CGRect(x: 20, y: 900, width: 38, height: 38),
            viewport: CGRect(x: 0, y: 0, width: 800, height: 750)
        )
        let verdict = HeroProbe.judge(record: r)
        #expect(verdict.isFailure)
        #expect(verdict.failureReason?.contains("source off-screen") ?? false)
    }

    @Test func targetFlushWithViewportEdgePasses() {
        // A header pinned to the top of the hosting surface is visible, so the
        // check expands the viewport by its margin instead of failing a
        // legitimate full-bleed target.
        let r = record(
            target: CGRect(x: 0, y: 0, width: 800, height: 320),
            landed: CGRect(x: 0, y: 0, width: 800, height: 320),
            viewport: CGRect(x: 0, y: 0, width: 800, height: 750)
        )
        #expect(HeroProbe.judge(record: r) == .pass)
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
        #expect(line.contains("viewport=—"))
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
        probe.recordViewport(CGRect(x: 0, y: 0, width: 800, height: 750))
        let verdict = probe.recordLanding(frame: CGRect(x: 438, y: 300, width: 320, height: 320), scale: 0.95)

        #expect(verdict == .pass)
        let archived = probe.records.last { $0.id == id }
        #expect(archived?.verdict == .pass)
        #expect(archived?.sourceFrame == CGRect(x: 20, y: 700, width: 38, height: 38))
        #expect(archived?.viewportFrame == CGRect(x: 0, y: 0, width: 800, height: 750))
    }

    @MainActor
    @Test func recordLandingWithoutAViewportFails() {
        // A missing viewport means the visibility check was skipped, which is
        // how an off-screen flight used to pass. The runtime path must refuse
        // to pass a transition it could not see.
        let probe = HeroProbe.shared
        let id = "unit-test-\(UUID().uuidString)"
        probe.begin(id)
        probe.recordSource(frame: CGRect(x: 20, y: 700, width: 38, height: 38), scale: 1)
        probe.recordTarget(frame: CGRect(x: 438, y: 300, width: 320, height: 320), scale: 0.95)
        let verdict = probe.recordLanding(frame: CGRect(x: 438, y: 300, width: 320, height: 320), scale: 0.95)

        #expect(verdict.isFailure)
        #expect(verdict.failureReason?.contains("viewport not recorded") ?? false)
    }
}
