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
        /// Return flights follow the mini anchor as the sidebar/window settles.
        var targetAnchorID: String? = nil
        /// A fresh value every time `start` builds a flight. `active` is keyed by
        /// the hero id, so a present flight and the return flight for the same
        /// id would share one `ForEach` identity and SwiftUI would hand the new
        /// flight the old `HeroFlight` view — with its "already finished" state
        /// intact, so `onAppear` never re-fired and the landing was never
        /// recorded. Keying the view on the nonce instead makes each flight its
        /// own view, with fresh state.
        let nonce = UUID()
        var cornerRadius: CGFloat { content.cornerRadius }

        static func == (lhs: Flight, rhs: Flight) -> Bool {
            lhs.id == rhs.id
                && lhs.content == rhs.content
                && lhs.source.approximately(rhs.source)
                && lhs.target.approximately(rhs.target)
                && lhs.targetScale == rhs.targetScale
                && lhs.sourceScale == rhs.sourceScale
                && lhs.targetAnchorID == rhs.targetAnchorID
                && lhs.cornerRadius == rhs.cornerRadius
                && lhs.nonce == rhs.nonce
        }
    }

    @Published var active: [String: Flight] = [:]

    /// Initial return-flight fallback only. A restored sidebar or resized window
    /// can move the mini player; return flights follow its live anchor until landing.
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
        targetScale: CGFloat,
        targetAnchorID: String? = nil
    ) {
        guard let source = recordedSourceFrame(for: id) else {
            KumoneLogger.hero.notice("HERO DIR start-nil \(id, privacy: .public)")
            return
        }
        if targetAnchorID == nil { miniHomeFrames[id] = source }
        active[id] = Flight(
            id: id,
            content: content,
            source: source,
            target: targetFrame,
            targetScale: targetScale,
            sourceScale: HeroProbe.shared.sourceScale(for: id),
            targetAnchorID: targetAnchorID
        )
        KumoneLogger.hero.info("HERO DIR start \(id, privacy: .public) count=\(self.active.count, privacy: .public)")
    }

    func end(id: String) {
        active.removeValue(forKey: id)
        KumoneLogger.hero.info("HERO DIR end \(id, privacy: .public) count=\(self.active.count, privacy: .public)")
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
