import CoreGraphics
import Foundation
import Testing
import SwiftUI
@testable import KumoneTCA

@Suite("Hero transition measurement")
struct HeroProbeTests {
    private func record(
        source: CGRect? = CGRect(x: 20, y: 700, width: 38, height: 38),
        target: CGRect? = CGRect(x: 438, y: 300, width: 320, height: 320),
        landed: CGRect? = CGRect(x: 438, y: 300, width: 320, height: 320),
        viewport: CGRect? = CGRect(x: 0, y: 0, width: 800, height: 750),
        proxyInitialFrame: CGRect? = CGRect(x: 20, y: 700, width: 38, height: 38),
        sourceCornerRadius: CGFloat? = 4,
        targetCornerRadius: CGFloat? = 12,
        landedCornerRadius: CGFloat? = 12,
        samples: [HeroProbe.Sample]? = nil,
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
            proxyInitialFrame: proxyInitialFrame,
            sourceCornerRadius: sourceCornerRadius,
            targetCornerRadius: targetCornerRadius,
            landedCornerRadius: landedCornerRadius,
            samples: samples ?? [
                HeroProbe.Sample(
                    timestamp: Date(timeIntervalSince1970: 0),
                    phase: .initial,
                    frame: proxyInitialFrame ?? .zero,
                    sourceVisible: false,
                    targetVisible: false,
                    proxyVisible: true
                ),
                HeroProbe.Sample(
                    timestamp: Date(timeIntervalSince1970: 1),
                    phase: .landed,
                    frame: landed ?? .zero,
                    sourceVisible: false,
                    targetVisible: true,
                    proxyVisible: false
                )
            ],
            sourceScale: sourceScale,
            targetScale: targetScale,
            landedScale: landedScale,
            verdict: verdict
        )
    }

    @Test func exactLandingOnTargetPasses() {
        #expect(HeroProbe.judge(record: record()) == .pass)
    }

    @Test func landingWithinHalfPointPasses() {
        let r = record(
            landed: CGRect(x: 438.4, y: 299.7, width: 320.4, height: 319.7),
            landedScale: 0.953
        )
        #expect(HeroProbe.judge(record: r) == .pass)
    }

    @Test func landingBeyondHalfPointFails() {
        let r = record(landed: CGRect(x: 438.6, y: 300, width: 320, height: 320))
        #expect(HeroProbe.judge(record: r).isFailure)
    }

    @Test func landingAtHalfPointPasses() {
        let r = record(landed: CGRect(x: 438.5, y: 299.5, width: 320.5, height: 319.5))
        #expect(HeroProbe.judge(record: r) == .pass)
    }

    @Test(arguments: [
        CGRect(x: 20.6, y: 700, width: 38, height: 38),
        CGRect(x: 20, y: 700.6, width: 38, height: 38),
        CGRect(x: 20, y: 700, width: 38.6, height: 38),
        CGRect(x: 20, y: 700, width: 38, height: 38.6)
    ])
    func initialFrameBeyondHalfPointFails(initial: CGRect) {
        let verdict = HeroProbe.judge(record: record(proxyInitialFrame: initial))
        #expect(verdict.isFailure)
        #expect(verdict.failureReason?.contains("initial frame off") ?? false)
    }

    @Test func initialFrameAtHalfPointPasses() {
        let r = record(proxyInitialFrame: CGRect(x: 20.5, y: 699.5, width: 38.5, height: 37.5))
        #expect(HeroProbe.judge(record: r) == .pass)
    }

    @Test func missingProxyInitialFrameFails() {
        let verdict = HeroProbe.judge(record: record(proxyInitialFrame: nil))
        #expect(verdict == .fail("proxy initial frame never recorded"))
    }

    @Test func cornerRadiusMismatchFails() {
        let verdict = HeroProbe.judge(record: record(landedCornerRadius: 12.6))
        #expect(verdict == .fail("cornerRadius off"))
    }

    @Test func cornerRadiusAtHalfPointPasses() {
        #expect(HeroProbe.judge(record: record(landedCornerRadius: 12.5)) == .pass)
    }

    @Test(arguments: [true, false])
    func missingCornerRadiusFails(missingTarget: Bool) {
        let r = record(
            targetCornerRadius: missingTarget ? nil : 12,
            landedCornerRadius: missingTarget ? 12 : nil
        )
        #expect(HeroProbe.judge(record: r) == .fail("cornerRadius not recorded"))
    }

    @Test func missingSourceCornerRadiusDoesNotFail() {
        #expect(HeroProbe.judge(record: record(sourceCornerRadius: nil)) == .pass)
    }

    @Test(arguments: [0, 2])
    func invalidPresenceCountFails(count: Int) {
        var r = record()
        r.samples.append(HeroProbe.Sample(
            timestamp: Date(timeIntervalSince1970: 2),
            phase: .animating,
            frame: CGRect(x: 200, y: 500, width: 150, height: 150),
            sourceVisible: count == 2,
            targetVisible: false,
            proxyVisible: count == 2
        ))
        #expect(HeroProbe.judge(record: r) == .fail("presence count \(count) at phase animating"))
    }

    @Test func missingProxySamplesFails() {
        #expect(HeroProbe.judge(record: record(samples: [])) == .fail("no proxy samples recorded"))
    }

    @Test func missingViewportTakesPriorityOverMissingSamples() {
        let verdict = HeroProbe.judge(record: record(viewport: nil, samples: []))
        #expect(verdict.failureReason?.contains("viewport not recorded") ?? false)
    }

    @Test func flippedCoordinateSpaceFails() {
        let r = record(
            landed: CGRect(x: 438, y: 550, width: 320, height: 320),
            viewport: CGRect(x: 0, y: 100, width: 800, height: 750)
        )
        #expect(HeroProbe.judge(record: r) == .fail("unflipped coordinate space"))
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
        // A 3pt drift fails under the default 0.5pt tolerance but passes when the
        // test widens it, which is how a flaky settle gets triaged.
        var wide = HeroProbe.Tolerance()
        wide.position = 5
        let r = record(landed: CGRect(x: 441, y: 300, width: 320, height: 320))
        #expect(HeroProbe.judge(record: r).isFailure)
        #expect(HeroProbe.judge(record: r, tolerance: wide) == .pass)
    }

    @Test func formatReportsEveryMeasurement() {
        let line = HeroProbe.format(record(viewport: nil, verdict: .pass))
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
    @Test(arguments: [false, true])
    func proxyVisibilityFollowsPhase(sourceHidden: Bool) {
        let probe = HeroProbe.shared
        let id = "unit-test-\(UUID().uuidString)"
        let source = CGRect(x: 20, y: 700, width: 38, height: 38)
        let target = CGRect(x: 438, y: 300, width: 320, height: 320)
        probe.begin(id)
        probe.recordSource(id: id, frame: source, hidden: sourceHidden)
        probe.recordTarget(id: id, frame: target, cornerRadius: 12)
        probe.recordViewport(CGRect(x: 0, y: 0, width: 800, height: 750), id: id)
        probe.recordProxyState(.unmeasured, id: id, frame: source)
        probe.recordProxyState(.initial, id: id, frame: source)
        probe.recordProxyState(.animating, id: id, frame: target)
        probe.recordProxyState(.landed, id: id, frame: target)
        probe.recordLanding(id: id, frame: target, cornerRadius: 12)

        let archived = probe.records.last { $0.id == id }
        #expect(archived?.samples.map(\.sourceVisible) == [!sourceHidden, false, false, false])
        #expect(archived?.samples.map(\.targetVisible) == [false, false, false, true])
        #expect(archived?.samples.map(\.proxyVisible) == [false, true, true, false])
        #expect(archived?.samples.map(\.presenceCount) == [sourceHidden ? 0 : 1, 1, 1, 1])
    }

    @MainActor
    @Test func recordLandingJudgesAndArchives() {
        let probe = HeroProbe.shared
        let id = "unit-test-\(UUID().uuidString)"
        probe.begin(id)
        probe.recordSource(id: id, frame: CGRect(x: 20, y: 700, width: 38, height: 38), scale: 1)
        probe.recordTarget(id: id, frame: CGRect(x: 438, y: 300, width: 320, height: 320), scale: 0.95, cornerRadius: 12)
        probe.recordProxyState(.initial, id: id, frame: CGRect(x: 20, y: 700, width: 38, height: 38))
        probe.recordProxyState(.landed, id: id, frame: CGRect(x: 438, y: 300, width: 320, height: 320))
        probe.recordViewport(CGRect(x: 0, y: 0, width: 800, height: 750), id: id)
        let verdict = probe.recordLanding(id: id, frame: CGRect(x: 438, y: 300, width: 320, height: 320), scale: 0.95, cornerRadius: 12)

        #expect(verdict == .pass)
        let archived = probe.records.last { $0.id == id }
        #expect(archived?.verdict == .pass)
        #expect(archived?.samples.map(\.presenceCount) == [1, 1])
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
        probe.recordSource(id: id, frame: CGRect(x: 20, y: 700, width: 38, height: 38), scale: 1)
        probe.recordTarget(id: id, frame: CGRect(x: 438, y: 300, width: 320, height: 320), scale: 0.95, cornerRadius: 12)
        probe.recordProxyState(.initial, id: id, frame: CGRect(x: 20, y: 700, width: 38, height: 38))
        probe.recordProxyState(.landed, id: id, frame: CGRect(x: 438, y: 300, width: 320, height: 320))
        let verdict = probe.recordLanding(id: id, frame: CGRect(x: 438, y: 300, width: 320, height: 320), scale: 0.95, cornerRadius: 12)

        #expect(verdict.isFailure)
        #expect(verdict.failureReason?.contains("viewport not recorded") ?? false)
    }

    @MainActor
    @Test func overlappingRecordsLandIndependently() {
        let probe = HeroProbe()
        let first = "first"
        let second = "second"
        let source = CGRect(x: 20, y: 20, width: 38, height: 38)
        let otherSource = CGRect(x: 80, y: 20, width: 38, height: 38)
        let target = CGRect(x: 100, y: 100, width: 200, height: 200)
        let otherTarget = CGRect(x: 400, y: 100, width: 200, height: 200)
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 750)
        probe.begin(first)
        probe.recordSource(id: first, frame: source, scale: 0.95, cornerRadius: 4)
        probe.begin(second)
        probe.recordSource(id: second, frame: otherSource, cornerRadius: 8, hidden: true)
        probe.recordTarget(id: second, frame: otherTarget, scale: 0.95, cornerRadius: 18)
        probe.recordTarget(id: first, frame: target, cornerRadius: 12)
        probe.recordViewport(viewport, id: first)
        probe.recordViewport(viewport.insetBy(dx: -10, dy: -10), id: second)
        probe.recordWindowScale(2, id: first)
        probe.recordWindowScale(1, id: second)
        probe.recordProxyState(.initial, id: first, frame: source)
        probe.recordProxyState(.initial, id: second, frame: otherSource)
        #expect(probe.sourceID(for: first) == first)
        #expect(probe.sourceID(for: second) == second)
        #expect(probe.sourceID(for: "missing") == nil)
        #expect(probe.sourceScale(for: first) == 0.95)
        #expect(probe.sourceScale(for: second) == 1)

        probe.recordProxyState(.landed, id: second, frame: otherTarget)
        #expect(probe.recordLanding(id: second, frame: otherTarget, scale: 0.95, cornerRadius: 18) == .pass)
        #expect(probe.sourceFrame(for: second) == nil)
        #expect(probe.sourceID(for: second) == nil)
        #expect(probe.sourceFrame(for: first) == source)
        probe.recordProxyState(.landed, id: first, frame: target)
        #expect(probe.recordLanding(id: first, frame: target, cornerRadius: 12) == .pass)
        #expect(probe.records.map(\.id) == [second, first])
        #expect(probe.records.map(\.windowScale) == [1, 2])
        #expect(probe.records.map(\.sourceCornerRadius) == [8, 4])
        #expect(probe.records.map(\.sourceHidden) == [true, false])
        #expect(probe.records.map(\.viewportFrame) == [viewport.insetBy(dx: -10, dy: -10), viewport])
        #expect(probe.records.map { $0.samples.map(\.frame) } == [[otherSource, otherTarget], [source, target]])
        #expect(probe.sourceFrame(for: first) == nil)
        // Late callbacks cannot re-create or archive a completed record twice.
        probe.recordSource(id: second, frame: source)
        probe.recordProxyState(.animating, id: second, frame: source)
        #expect(probe.recordLanding(id: second, frame: otherTarget).isFailure)
        #expect(probe.records.count == 2)
        #expect(probe.sourceID(for: second) == nil)
    }

    @MainActor
    @Test func beginningAgainResetsOnlyItsOwnRecord() {
        let probe = HeroProbe()
        probe.begin("first")
        probe.begin("second")
        probe.recordSource(id: "first", frame: .zero, scale: 0.95)
        probe.recordSource(id: "second", frame: .zero, scale: 0.9)
        probe.begin("first")
        #expect(probe.sourceID(for: "first") == nil)
        #expect(probe.sourceScale(for: "first") == 1)
        #expect(probe.sourceID(for: "second") == "second")
        #expect(probe.sourceScale(for: "second") == 0.9)
    }

    @MainActor
    @Test func directorStartsAndEndsFlightsByID() {
        let probe = HeroProbe.shared
        let director = HeroFlightDirector()
        let first = UUID().uuidString
        let second = UUID().uuidString
        let missing = UUID().uuidString
        let source = CGRect(x: 20, y: 20, width: 38, height: 38)
        let otherSource = CGRect(x: 80, y: 20, width: 38, height: 38)
        let target = CGRect(x: 100, y: 100, width: 200, height: 200)
        let artwork = HeroContent.artwork(url: URL(string: "https://example.com/cover.jpg"), cornerRadius: 18)
        probe.begin(first)
        probe.recordSource(id: first, frame: source, scale: 0.95)
        probe.begin(second)
        probe.recordSource(id: second, frame: otherSource)
        defer {
            probe.recordLanding(id: first, frame: target)
            probe.recordLanding(id: second, frame: target)
        }
        director.start(id: first, content: artwork, targetFrame: target, targetScale: 1)
        let icon = HeroContent.icon(name: "pause.fill", tint: .black.opacity(0.85),
                                    background: .white, diameter: 58, fontSize: 21)
        director.start(id: second, content: icon, targetFrame: target, targetScale: 0.95)
        director.start(id: missing, content: artwork, targetFrame: target, targetScale: 1)
        #expect(director.active.count == 2)
        #expect(director.active[missing] == nil)
        #expect(director.miniHomeFrames[missing] == nil)
        #expect(director.recordedSourceFrame(for: missing) == nil)
        #expect(director.active[first]?.content == artwork)
        #expect(director.active[first]?.source == source)
        #expect(director.active[first]?.sourceScale == 0.95)
        #expect(director.active[second]?.source == otherSource)
        #expect(director.active[second]?.targetScale == 0.95)
        #expect(director.active[second]?.cornerRadius == 29)
        #expect(director.active[second]?.content == icon)
        #expect(director.miniHomeFrames[first] == source)
        #expect(director.miniHomeFrames[second] == otherSource)
        director.end(id: first)
        #expect(director.active[first] == nil)
        #expect(director.active[second] != nil)
        #expect(director.miniHomeFrames[first] == source)
        director.end(id: missing)
        #expect(director.active.count == 1)
        director.end(id: second)
        #expect(director.active.isEmpty)
    }
}
