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
    /// these tolerances. 1pt covers the rounding SwiftUI applies when a view
    /// lands on a half-pixel; 0.01 scale is the smallest difference the eye
    /// can register during a settle.
    struct Tolerance: Equatable, Sendable {
        var position: CGFloat = 1
        var size: CGFloat = 1
        var scale: CGFloat = 0.01
    }

    static let tolerance = Tolerance()

    /// One transition's worth of measurements, in the `.global` coordinate
    /// space (window coordinates, shared by the source, the flying stand-in
    /// and the target on every platform this app ships).
    struct Record: Identifiable, Equatable {
        let id: String
        var sourceFrame: CGRect?
        var targetFrame: CGRect?
        var landedFrame: CGRect?
        var sourceScale: CGFloat = 1
        var targetScale: CGFloat = 1
        var landedScale: CGFloat = 1
        var verdict: Verdict?
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

    func recordSource(frame: CGRect, scale: CGFloat = 1) {
        current.sourceFrame = frame
        current.sourceScale = scale
    }

    func recordTarget(frame: CGRect, scale: CGFloat = 1) {
        current.targetFrame = frame
        current.targetScale = scale
    }

    /// Called when the flying stand-in settles. Judges it against the target
    /// geometry, archives the record, and writes the verdict to the system log
    /// and the probe log file. Returns the verdict for in-app assertions.
    @discardableResult
    func recordLanding(frame: CGRect, scale: CGFloat = 1) -> Verdict {
        current.landedFrame = frame
        current.landedScale = scale
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

    /// `HERO PASS nowPlayingArtwork src=(255,718,38,38) tgt=(438,300,320,320) landed=(438,300,320,320) scale=0.95`
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
