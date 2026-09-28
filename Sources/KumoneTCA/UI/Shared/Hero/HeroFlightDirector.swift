import KumoneCore
import SwiftUI

/// Directs independently identified hero flights. A trigger records the source geometry in
/// `HeroProbe`, the presentation machinery shows the target, the target's
/// `.heroAnchor` reports its frame, and then `start(_:)` mounts the flying
/// stand-in. When the stand-in settles it reports its landing to `HeroProbe`
/// and the director dismisses it.
@MainActor
final class HeroFlightDirector: ObservableObject {
    static let shared = HeroFlightDirector()

    struct Flight: Identifiable, Equatable {
        let id: String
        let content: HeroContent
        let source: CGRect
        let target: CGRect
        /// The resting scale the target view applies, which the flight has to
        /// reproduce so the hand-off is invisible.
        let targetScale: CGFloat
        /// The resting scale the source view applies, so the stand-in starts at
        /// the source's visual size and ends at the target's.
        let sourceScale: CGFloat
        var cornerRadius: CGFloat { content.cornerRadius }

        static func == (lhs: Flight, rhs: Flight) -> Bool {
            lhs.id == rhs.id
                && lhs.content == rhs.content
                && lhs.source.approximately(rhs.source)
                && lhs.target.approximately(rhs.target)
                && lhs.targetScale == rhs.targetScale
                && lhs.sourceScale == rhs.sourceScale
                && lhs.cornerRadius == rhs.cornerRadius
        }
    }

    @Published var active: [String: Flight] = [:]

    /// The frame the mini artwork occupied when the present flight launched —
    /// its home. The sidebar hides while the Now Playing page is up and the
    /// mini artwork drifts left, so the store's live value at dismiss time is
    /// the wrong target; the return flight flies back to this snapshot.
    var miniHomeFrames: [String: CGRect] = [:]

    /// The source geometry recorded by the trigger (`HeroProbe.recordSource`),
    /// read back here rather than from `HeroFrameStore`: source and target
    /// share one anchor id, so by the time the target reports its frame the
    /// store's entry for that id already holds the *target* geometry.
    func recordedSourceFrame(for id: String) -> CGRect? {
        HeroProbe.shared.sourceFrame(for: id)
    }

    /// Pairs an already-recorded source with a freshly measured target and
    /// launches the flight. Does nothing when the source has not been recorded
    /// yet — the caller retries from `.onGeometryChange` until it appears.
    func start(
        id: String,
        content: HeroContent,
        targetFrame: CGRect,
        targetScale: CGFloat
    ) {
        guard let source = recordedSourceFrame(for: id) else { return }
        miniHomeFrames[id] = source
        active[id] = Flight(
            id: id,
            content: content,
            source: source,
            target: targetFrame,
            targetScale: targetScale,
            sourceScale: HeroProbe.shared.sourceScale(for: id)
        )
    }

    func end(id: String) {
        active.removeValue(forKey: id)
    }
}

extension CGRect {
    /// Same frame within half a point; used only to keep `Flight` equatable
    /// against the tiny geometry jitter a layout pass can introduce.
    func approximately(_ other: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(origin.x - other.origin.x) <= tolerance
            && abs(origin.y - other.origin.y) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
