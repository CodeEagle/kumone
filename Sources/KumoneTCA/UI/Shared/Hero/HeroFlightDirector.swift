import KumoneCore
import SwiftUI

/// Directs one hero flight at a time. A trigger records the source geometry in
/// `HeroProbe`, the presentation machinery shows the target, the target's
/// `.heroAnchor` reports its frame, and then `start(_:)` mounts the flying
/// stand-in. When the stand-in settles it reports its landing to `HeroProbe`
/// and the director dismisses it.
@MainActor
final class HeroFlightDirector: ObservableObject {
    static let shared = HeroFlightDirector()

    struct Flight: Identifiable, Equatable {
        let id: String
        let artworkURL: URL?
        let source: CGRect
        let target: CGRect
        /// The resting scale the target view applies, which the flight has to
        /// reproduce so the hand-off is invisible.
        let targetScale: CGFloat
        let cornerRadius: CGFloat

        static func == (lhs: Flight, rhs: Flight) -> Bool {
            lhs.id == rhs.id
                && lhs.artworkURL == rhs.artworkURL
                && lhs.source.approximately(rhs.source)
                && lhs.target.approximately(rhs.target)
                && lhs.targetScale == rhs.targetScale
                && lhs.cornerRadius == rhs.cornerRadius
        }
    }

    @Published var active: Flight?

    /// The source geometry recorded by the trigger (`HeroProbe.recordSource`),
    /// read back here rather than from `HeroFrameStore`: source and target
    /// share one anchor id, so by the time the target reports its frame the
    /// store's entry for that id already holds the *target* geometry.
    var recordedSourceFrame: CGRect? {
        HeroProbe.shared.currentSourceFrame
    }

    /// Pairs an already-recorded source with a freshly measured target and
    /// launches the flight. Does nothing when the source has not been recorded
    /// yet — the caller retries from `.onGeometryChange` until it appears.
    func start(
        id: String,
        artworkURL: URL?,
        cornerRadius: CGFloat,
        targetFrame: CGRect,
        targetScale: CGFloat
    ) {
        guard let source = recordedSourceFrame else { return }
        active = Flight(
            id: id,
            artworkURL: artworkURL,
            source: source,
            target: targetFrame,
            targetScale: targetScale,
            cornerRadius: cornerRadius
        )
    }

    func end() {
        active = nil
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
