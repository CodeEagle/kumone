import Foundation
import KumoneCore
import os

/// Records hero-transition geometry and judges whether the flying stand-in
/// landed on the target control.
///
/// The judgement is pure data — `judge(record:tolerance:)` has no UI or timing
/// dependency — so the correctness of a transition can be asserted in a unit
/// test. At runtime each completed record also writes one PASS/FAIL line to
/// `KumoneLogger.hero` and to `/tmp/kumone-hero.log`, which means a transition
/// verifies itself while the app runs: no GUI automation, no manual inspection.
@MainActor
final class HeroProbe: ObservableObject {
    static let shared = HeroProbe()

    /// A transition passes when the landed geometry matches the target within
    /// these tolerances. Position and size allow at most 0.5pt per component;
    /// scale allows a difference of 0.01 during a settle.
    struct Tolerance: Equatable, Sendable {
        var position: CGFloat = 0.5
        var size: CGFloat = 0.5
        var scale: CGFloat = 0.01
    }

    static let tolerance = Tolerance()

    /// A frame may sit flush against the edge of the hosting surface (a header
    /// pinned to the top, a mini player to the bottom) and still be visible, so
    /// the visibility check expands the viewport by this much before it asks
    /// whether both ends of the flight are on screen.
    nonisolated static let viewportMargin: CGFloat = 2

    /// One transition's worth of measurements, in the `.global` coordinate
    /// space (window coordinates, shared by the source, the flying stand-in
    /// and the target on every platform this app ships).
    struct Record: Identifiable, Equatable {
        let id: String
        var sourceFrame: CGRect?
        var targetFrame: CGRect?
        var landedFrame: CGRect?
        /// The frame of the surface that hosts the flight, i.e. the on-screen
        /// area the user can actually see. `nil` fails the visibility check.
        var viewportFrame: CGRect?
        /// The proxy's first measured initial frame, independent of the source.
        var proxyInitialFrame: CGRect?
        var sourceCornerRadius: CGFloat?
        var targetCornerRadius: CGFloat?
        var landedCornerRadius: CGFloat?
        var sourceHidden: Bool = false
        var windowScale: CGFloat?
        var samples: [Sample] = []
        var sourceScale: CGFloat = 1
        var targetScale: CGFloat = 1
        var landedScale: CGFloat = 1
        var verdict: Verdict?
    }

    enum Phase: String, Sendable {
        case initial, animating, landed, unmeasured
    }

    struct Sample: Equatable, Sendable {
        let timestamp: Date
        let phase: Phase
        let frame: CGRect
        let sourceVisible: Bool
        let targetVisible: Bool
        let proxyVisible: Bool

        var presenceCount: Int {
            (sourceVisible ? 1 : 0) + (targetVisible ? 1 : 0) + (proxyVisible ? 1 : 0)
        }
    }

    enum Verdict: Equatable, Sendable {
        case pass
        case fail(String)

        var isFailure: Bool {
            if case .fail = self { return true }
            return false
        }

        var failureReason: String? {
            if case let .fail(reason) = self { return reason }
            return nil
        }
    }

    static let logFilePath = "/tmp/kumone-hero.log"

    @Published private(set) var records: [Record] = []
    private var current = Record(id: "none")

    /// The source geometry the current transition recorded, for
    /// `HeroFlightDirector` to pair against the target. Read here rather than
    /// from `HeroFrameStore` because source and target share one anchor id and
    /// the store's entry gets overwritten by the target.
    var currentSourceFrame: CGRect? {
        current.sourceFrame
    }

    /// The id of the transition whose source is currently armed. A detail page
    /// reached without an armed card (a track's context menu, a sidebar item)
    /// has no source to fly from and must not borrow one an earlier card left
    /// behind, so the target gate compares this against its own hero id.
    var currentSourceID: String? {
        current.sourceFrame != nil ? current.id : nil
    }

    var currentSourceScale: CGFloat {
        current.sourceScale
    }

    func begin(_ id: String) {
        current = Record(id: id)
    }

    func recordSource(frame: CGRect, scale: CGFloat = 1, cornerRadius: CGFloat? = nil, hidden: Bool = false) {
        current.sourceFrame = frame
        current.sourceScale = scale
        current.sourceCornerRadius = cornerRadius
        current.sourceHidden = hidden
    }

    func recordTarget(frame: CGRect, scale: CGFloat = 1, cornerRadius: CGFloat? = nil) {
        current.targetFrame = frame
        current.targetScale = scale
        current.targetCornerRadius = cornerRadius
    }

    /// Visibility follows the reported phase and source-hidden state; callers
    /// must report the phase when the corresponding views actually change.
    func recordProxyState(_ phase: Phase, frame: CGRect) {
        if phase == .initial, current.proxyInitialFrame == nil {
            current.proxyInitialFrame = frame
        }
        let proxyVisible = phase == .initial || phase == .animating
        let targetVisible = phase == .landed
        current.samples.append(Sample(
            timestamp: Date(),
            phase: phase,
            frame: frame,
            sourceVisible: !proxyVisible && !targetVisible && !current.sourceHidden,
            targetVisible: targetVisible,
            proxyVisible: proxyVisible
        ))
        let line = "HERO PROXY \(current.id) \(phase.rawValue) \(Self.frameDescription(frame))"
        KumoneLogger.hero.notice("\(line, privacy: .public)")
        Self.writeFile(line)
    }

    func recordWindowScale(_ scale: CGFloat) {
        current.windowScale = scale
    }

    /// Records the frame of the surface hosting the flight — the area the user
    /// can see — so the judgement can reject a transition whose target was
    /// measured off-screen.
    func recordViewport(_ frame: CGRect) {
        current.viewportFrame = frame
    }

    /// Called when the flying stand-in settles. Judges it against the target
    /// geometry, archives the record, and writes the verdict to the system log
    /// and the probe log file. Returns the verdict for in-app assertions.
    @discardableResult
    func recordLanding(frame: CGRect, scale: CGFloat = 1, cornerRadius: CGFloat? = nil) -> Verdict {
        current.landedFrame = frame
        current.landedScale = scale
        current.landedCornerRadius = cornerRadius
        let verdict = Self.judge(record: current, tolerance: Self.tolerance)
        current.verdict = verdict
        records.append(current)
        let line = Self.format(current)
        KumoneLogger.hero.notice("\(line, privacy: .public)")
        Self.writeFile(line)
        return verdict
    }

    /// Pure: judges a finished record without touching the UI. Unit tests call
    /// this directly; the runtime path goes through `recordLanding`.
    nonisolated static func judge(record: Record, tolerance: Tolerance = tolerance) -> Verdict {
        guard let target = record.targetFrame, let landed = record.landedFrame else {
            return .fail(
                "missing geometry: target=\(frameDescription(record.targetFrame)) "
                    + "landed=\(frameDescription(record.landedFrame))"
            )
        }
        // A flight the user cannot see is not a hero transition. The Now Playing
        // slide-in regression locked the target on the transition's first frame,
        // measured the off-screen slide start, and the stand-in flew below the
        // window — where it still matched its target exactly and passed every
        // other check. Both ends have to be on screen for the transition to count.
        // Fail closed before checking proxy samples: visibility must be verified.
        guard let viewport = record.viewportFrame else {
            return .fail("viewport not recorded: visibility unverified")
        }
        let visible = viewport.insetBy(dx: -Self.viewportMargin, dy: -Self.viewportMargin)
        guard visible.contains(target) else {
            return .fail(
                "target off-screen: \(frameDescription(target)) outside viewport \(frameDescription(viewport))"
            )
        }
        if let source = record.sourceFrame, !visible.contains(source) {
            return .fail(
                "source off-screen: \(frameDescription(source)) outside viewport \(frameDescription(viewport))"
            )
        }
        guard let initial = record.proxyInitialFrame else {
            return .fail("proxy initial frame never recorded")
        }
        guard let source = record.sourceFrame else {
            return .fail("missing geometry: source never recorded")
        }
        let initialDX = abs(initial.origin.x - source.origin.x)
        let initialDY = abs(initial.origin.y - source.origin.y)
        let initialDW = abs(initial.width - source.width)
        let initialDH = abs(initial.height - source.height)
        guard initialDX <= tolerance.position, initialDY <= tolerance.position,
              initialDW <= tolerance.size, initialDH <= tolerance.size else {
            return .fail(
                "initial frame off vs source: initial=\(frameDescription(initial)) source=\(frameDescription(source))"
            )
        }
        guard let targetCornerRadius = record.targetCornerRadius,
              let landedCornerRadius = record.landedCornerRadius else {
            return .fail("cornerRadius not recorded")
        }
        guard abs(landedCornerRadius - targetCornerRadius) <= 0.5 else {
            return .fail("cornerRadius off")
        }
        guard !record.samples.isEmpty else {
            return .fail("no proxy samples recorded")
        }
        for sample in record.samples where sample.presenceCount != 1 {
            return .fail("presence count \(sample.presenceCount) at phase \(sample.phase.rawValue)")
        }
        let flippedY = viewport.origin.y + viewport.height - target.origin.y
        if abs(landed.origin.y - flippedY) <= 0.5,
           abs(landed.origin.y - target.origin.y) > 0.5 {
            return .fail("unflipped coordinate space")
        }
        let dx = abs(landed.origin.x - target.origin.x)
        let dy = abs(landed.origin.y - target.origin.y)
        guard dx <= tolerance.position, dy <= tolerance.position else {
            return .fail("origin off by (\(String(format: "%.2f", dx)), \(String(format: "%.2f", dy))) vs target")
        }
        let dw = abs(landed.width - target.width)
        let dh = abs(landed.height - target.height)
        guard dw <= tolerance.size, dh <= tolerance.size else {
            return .fail("size off by (\(String(format: "%.2f", dw)), \(String(format: "%.2f", dh))) vs target")
        }
        let ds = abs(record.landedScale - record.targetScale)
        guard ds <= tolerance.scale else {
            return .fail(
                "scale off by \(String(format: "%.4f", ds)): landed=\(record.landedScale) target=\(record.targetScale)"
            )
        }
        return .pass
    }

    // MARK: - Formatting

    /// `HERO PASS nowPlayingArtwork src=(255,718,38,38) tgt=(438,300,320,320) landed=(438,300,320,320) viewport=(0,0,1289,703) scale=0.95`
    nonisolated static func format(_ record: Record) -> String {
        let verdictText: String
        switch record.verdict {
        case nil: verdictText = "MEASURED"
        case .pass?: verdictText = "PASS"
        case .fail?: verdictText = "FAIL"
        }
        var line = "HERO \(verdictText) \(record.id) "
            + "src=\(frameDescription(record.sourceFrame)) "
            + "tgt=\(frameDescription(record.targetFrame)) "
            + "landed=\(frameDescription(record.landedFrame)) "
            + "viewport=\(frameDescription(record.viewportFrame)) "
            + "scale src=\(String(format: "%.3f", record.sourceScale)) "
            + "tgt=\(String(format: "%.3f", record.targetScale)) "
            + "landed=\(String(format: "%.3f", record.landedScale))"
        if let reason = record.verdict?.failureReason {
            line += " | \(reason)"
        }
        return line
    }

    nonisolated static func frameDescription(_ frame: CGRect?) -> String {
        guard let frame else { return "—" }
        return "(\(String(format: "%.1f", frame.origin.x)),"
            + "\(String(format: "%.1f", frame.origin.y)),"
            + "\(String(format: "%.1f", frame.size.width)),"
            + "\(String(format: "%.1f", frame.size.height)))"
    }

    // MARK: - Log file

    /// Appends one line to the probe file on a background priority. The system
    /// log is authoritative; this file is for tooling that tails a file, and a
    /// sandbox that forbids it only loses the copy, not the verdict.
    static func writeFile(_ line: String) {
        let url = URL(fileURLWithPath: logFilePath)
        let payload = (line + "\n").data(using: .utf8) ?? Data()
        Task.detached(priority: .utility) {
            do {
                if let handle = try? FileHandle(forWritingTo: url) {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: payload)
                    try handle.close()
                } else {
                    try payload.write(to: url)
                }
            } catch {
                KumoneLogger.hero.debug(
                    "probe log file unwritable: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
