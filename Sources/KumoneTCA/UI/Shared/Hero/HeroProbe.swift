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

    nonisolated static let tolerance = Tolerance()

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
        /// The URL the card's image actually displayed — the flight's stand-in
        /// reuses it so the flying artwork is the bitmap the user was looking
        /// at, cached, instead of the detail page's own (differently-derived)
        /// URL that has not loaded yet and would paint the stand-in gray for
        /// the whole flight.
        var sourceImageURL: URL?
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

    /// How many finished flights the audit trail keeps before the oldest
    /// are dropped. The self-test suites read verdicts back; a long running
    /// session produces one record per flight otherwise.
    private static let maxRecords = 1000

    @Published private(set) var records: [Record] = []
    private var active: [String: Record] = [:]

    /// Read the armed source rather than the anchor store, whose entry may
    /// already have been overwritten by the target sharing this id.
    func sourceFrame(for id: String) -> CGRect? {
        active[id]?.sourceFrame
    }

    /// A target may launch only when its own source has been armed. Sources
    /// belonging to other simultaneous flights must not open this gate.
    func sourceID(for id: String) -> String? {
        sourceFrame(for: id) != nil ? id : nil
    }

    func isArmed(_ id: String) -> Bool { active[id] != nil }

    /// A destination that leaves before landing must not keep an old source
    /// armed for a later presentation of the same item.
    func cancel(_ id: String) { active.removeValue(forKey: id) }


    func sourceScale(for id: String) -> CGFloat {
        active[id]?.sourceScale ?? 1
    }

    /// The radius the source view clips to — used to interpolate the flying
    /// stand-in's radius so a small source is not clipped into a circle by a
    /// page-sized radius while it grows.
    func sourceCornerRadius(for id: String) -> CGFloat? {
        active[id]?.sourceCornerRadius
    }

    /// The URL the source card displayed, if the arm carried it. The flight
    /// preferentially renders this over the landing page's own artwork URL.
    func sourceImageURL(for id: String) -> URL? {
        active[id]?.sourceImageURL
    }

    /// The radius the landing view clips to.
    func targetCornerRadius(for id: String) -> CGFloat? {
        active[id]?.targetCornerRadius
    }

    func begin(_ id: String) {
        active[id] = Record(id: id)
    }

    func recordSource(id: String, frame: CGRect, scale: CGFloat = 1, cornerRadius: CGFloat? = nil, hidden: Bool = false, imageURL: URL? = nil) {
        active[id]?.sourceFrame = frame
        active[id]?.sourceScale = scale
        active[id]?.sourceCornerRadius = cornerRadius
        active[id]?.sourceHidden = hidden
        active[id]?.sourceImageURL = imageURL
    }

    func recordTarget(id: String, frame: CGRect, scale: CGFloat = 1, cornerRadius: CGFloat? = nil) {
        active[id]?.targetFrame = frame
        active[id]?.targetScale = scale
        active[id]?.targetCornerRadius = cornerRadius
    }

    /// Visibility follows the reported phase and source-hidden state; callers
    /// must report the phase when the corresponding views actually change.
    func recordProxyState(_ phase: Phase, id: String, frame: CGRect) {
        guard var current = active[id] else { return }
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
        active[id] = current
        let line = "HERO PROXY \(current.id) \(phase.rawValue) \(Self.frameDescription(frame))"
        KumoneLogger.hero.notice("\(line, privacy: .public)")
        Self.writeFile(line)
    }

    func recordWindowScale(_ scale: CGFloat, id: String) {
        active[id]?.windowScale = scale
    }

    /// The last frame the flying stand-in itself measured, for a settle that
    /// cannot read the view's `@State` — the director's settle watch lands a
    /// flight from this when its spring's completion never fired.
    func lastSampleFrame(for id: String) -> CGRect? {
        active[id]?.samples.last?.frame
    }

    /// Records the frame of the surface hosting the flight — the area the user
    /// can see — so the judgement can reject a transition whose target was
    /// measured off-screen.
    func recordViewport(_ frame: CGRect, id: String) {
        active[id]?.viewportFrame = frame
    }

    /// Called when the flying stand-in settles. Judges it against the target
    /// geometry, archives the record, and writes the verdict to the system log
    /// and the probe log file. Returns the verdict for in-app assertions.
    @discardableResult
    func recordLanding(id: String, frame: CGRect, scale: CGFloat = 1, cornerRadius: CGFloat? = nil) -> Verdict {
        guard var current = active.removeValue(forKey: id) else {
            return .fail("no active record for \(id)")
        }
        current.landedFrame = frame
        current.landedScale = scale
        current.landedCornerRadius = cornerRadius
        let verdict = Self.judge(record: current, tolerance: Self.tolerance)
        current.verdict = verdict
        records.append(current)
        // The archive is a flight audit trail, consumed by the self-test
        // suites; a long session would otherwise grow it without end.
        if records.count > Self.maxRecords { records.removeFirst(records.count - Self.maxRecords) }
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
    /// sandbox that forbids it only loses the copy, not the verdict. Every
    /// write runs on one serial queue: concurrent writers that each seek to
    /// the end and write leave overlapping tails in the file — a corrupted
    /// audit trail that is indistinguishable from lost verdicts. The append
    /// itself is bounded, so a long test run cannot fill the disk.
    static func writeFile(_ line: String) {
        let url = URL(fileURLWithPath: logFilePath)
        writeQueue.async {
            BoundedLogFile.append(line, to: url)
        }
    }

    /// One writer at a time, in call order, so a flight's phases and verdict
    /// stay whole lines even when ten flights report in the same frame.
    private static let writeQueue = DispatchQueue(
        label: "im.missuo.Kumone.hero-probe-log", qos: .utility
    )
}
