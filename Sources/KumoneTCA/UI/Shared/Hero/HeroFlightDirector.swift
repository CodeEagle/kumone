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
        /// The frame the flight was launched at. A present flight may later
        /// follow its live anchor (`liveAnchorID`) if the landing view moves
        /// before the stand-in settles; a return flight follows
        /// `targetAnchorID`.
        var target: CGRect
        /// The resting scale the target view applies, which the flight has to
        /// reproduce so the hand-off is invisible.
        let targetScale: CGFloat
        /// The resting scale the source view applies, so the stand-in starts at
        /// the source's visual size and ends at the target's.
        let sourceScale: CGFloat
        /// Return flights follow the mini anchor as the sidebar/window settles.
        var targetAnchorID: String? = nil
        /// Present flights follow the landing view's anchor as the page's layout
        /// settles (e.g. the lyrics column collapsing re-centres the artwork
        /// while the stand-in is still flying). `nil` means the recorded target
        /// is final.
        var liveAnchorID: String? = nil
        /// A fresh value every time `start` builds a flight. `active` is keyed by
        /// the hero id, so a present flight and the return flight for the same
        /// id would share one `ForEach` identity and SwiftUI would hand the new
        /// flight the old `HeroFlight` view — with its "already finished" state
        /// intact, so `onAppear` never re-fired and the landing was never
        /// recorded. Keying the view on the nonce instead makes each flight its
        /// own view, with fresh state.
        let nonce = UUID()
        /// The clip radii of the two endpoints, so the stand-in's corner
        /// radius interpolates with its frame instead of staying pinned to
        /// the landing page's radius (which clips a 38pt mini artwork into a
        /// circle while it is still small).
        let sourceCornerRadius: CGFloat
        let targetCornerRadius: CGFloat
        var cornerRadius: CGFloat { content.cornerRadius }

        static func == (lhs: Flight, rhs: Flight) -> Bool {
            lhs.id == rhs.id
                && lhs.content == rhs.content
                && lhs.source.approximately(rhs.source)
                && lhs.target.approximately(rhs.target)
                && lhs.targetScale == rhs.targetScale
                && lhs.sourceScale == rhs.sourceScale
                && lhs.targetAnchorID == rhs.targetAnchorID
                && lhs.liveAnchorID == rhs.liveAnchorID
                && lhs.cornerRadius == rhs.cornerRadius
                && lhs.sourceCornerRadius == rhs.sourceCornerRadius
                && lhs.targetCornerRadius == rhs.targetCornerRadius
                && lhs.nonce == rhs.nonce
        }
    }

    @Published var active: [String: Flight] = [:]

    /// Ids whose flight has arrived within a hair of the target but is
    /// still settling. Views gating on the armed/active pair (a detail
    /// page's header target) use this to reveal the real cover the moment
    /// the stand-in sits on top of it, instead of waiting for the spring's
    /// full settle — which trails the page fade by ~150ms and leaves the
    /// header empty under a fully-opaque page ("the cover pops in late").
    @Published var released: Set<String> = []

    /// Idempotent: marks the flight as visually landed. The spring keeps
    /// running untouched; only the reveal gate flips.
    func release(id: String) {
        guard active[id] != nil, !released.contains(id) else { return }
        released.insert(id)
        HeroProbe.writeTimed("DIR release", id)
        KumoneLogger.hero.notice("HERO DIR release \(id, privacy: .public)")
    }

    /// Retargets in-flight present flights to their live anchor frames. Keyed
    /// by the anchor ids the landing views report; only flights carrying that
    /// anchor move.
    func retargetLiveAnchor(_ frame: CGRect, for anchorID: String) {
        for (id, flight) in active where flight.liveAnchorID == anchorID {
            retarget(id: id, frame: frame)
        }
    }

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
        targetAnchorID: String? = nil,
        liveAnchorID: String? = nil
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
            targetAnchorID: targetAnchorID,
            liveAnchorID: liveAnchorID,
            sourceCornerRadius: HeroProbe.shared.sourceCornerRadius(for: id) ?? content.cornerRadius,
            targetCornerRadius: HeroProbe.shared.targetCornerRadius(for: id) ?? content.cornerRadius
        )
        KumoneLogger.hero.info("HERO DIR start \(id, privacy: .public) count=\(self.active.count, privacy: .public)")
    }

    /// Retargets an in-flight present flight to a new landing frame. The
    /// stand-in animates to the new frame; the probe's recorded target moves
    /// with it, so the landing verdict compares against the frame the landing
    /// view occupies at settle time rather than the one it happened to hold at
    /// launch. No-op when the flight is not following a live anchor.
    func retarget(id: String, frame: CGRect) {
        guard var flight = active[id], flight.liveAnchorID != nil else { return }
        guard !flight.target.approximately(frame) else { return }
        flight.target = frame
        active[id] = flight
        KumoneLogger.hero.info(
            "HERO DIR retarget \(id, privacy: .public) frame=\(frame.origin.x, privacy: .public),\(frame.origin.y, privacy: .public) \(frame.width, privacy: .public)x\(frame.height, privacy: .public)"
        )
    }

    func end(id: String) {
        active.removeValue(forKey: id)
        released.remove(id)
        settleWatchers.removeValue(forKey: id)?.invalidate()
        KumoneLogger.hero.info("HERO DIR end \(id, privacy: .public) count=\(self.active.count, privacy: .public)")
    }

    // MARK: - Settle watch

    /// `withAnimation(..., completionCriteria: .removed)` does not guarantee
    /// the completion handler: flights over the now-playing transport row ran
    /// every spring to its final frame without one ever firing — not even the
    /// superseded path — while the same flights in the return direction fired
    /// theirs. The stand-in then sits frozen a hair off the real control,
    /// its hand-off never happening, for as long as the page stays open.
    ///
    /// A run-loop timer does not depend on the render tree's cooperation, and
    /// a timer wakes a main thread parked in `nextEventMatchingMask`, which a
    /// superseded-spring callback does not. Each armed spring schedules one:
    /// if the spring's own completion lands the flight first, `end(id:)`
    /// cancels the watch; if the completion never comes, the watch lands the
    /// flight from the probe's last measured frame instead.
    private var settleWatchers: [String: Timer] = [:]

    /// The longest `AppAnimation.heroSpring` takes to settle, plus margin. A
    /// normal completion always wins the race; the watch is the floor, not
    /// the ceiling, of the flight's duration.
    private static let settleDeadline: TimeInterval = 1.5

    /// Arms the settle watch for one flight. Re-arming replaces the previous
    /// watch, so a flight that is retargeted mid-air is watched from its
    /// newest spring and a superseded spring's stale watch never fires.
    func watchSettle(_ id: String) {
        settleWatchers[id]?.invalidate()
        // A run-loop timer, not a dispatch timer: the main dispatch queue's
        // callback source is not what services this app's loop — a GCD timer
        // armed once per spring never fired across an entire run, while
        // Swift's own `Timer` on the main run loop wakes the main thread
        // directly out of its parked `mach_msg` wait.
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.settleDeadline, repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.settle(id)
            }
        }
        settleWatchers[id] = timer
        KumoneLogger.hero.notice("HERO WATCH arm \(id, privacy: .public)")
        HeroProbe.writeFile("HERO WATCH arm \(id)")
    }

    /// Lands a flight whose spring completion never fired. The probe's last
    /// sample is the stand-in's last measured frame — the same evidence the
    /// completion path's `measuredFrame` holds — and the judge compares it
    /// against the recorded target exactly as a normal landing would.
    private func settle(_ id: String) {
        settleWatchers.removeValue(forKey: id)
        KumoneLogger.hero.notice(
            "HERO WATCH fire \(id, privacy: .public) active=\(self.active[id] != nil, privacy: .public)"
        )
        HeroProbe.writeFile("HERO WATCH fire \(id) active=\(active[id] != nil)")
        guard let flight = active[id] else { return }
        let frame = HeroProbe.shared.lastSampleFrame(for: id) ?? flight.target
        HeroProbe.shared.recordProxyState(.landed, id: id, frame: frame)
        KumoneLogger.hero.notice(
            "HERO SETTLE \(id, privacy: .public) reason=watcher frame=\(HeroProbe.frameDescription(frame), privacy: .public)"
        )
        HeroProbe.writeFile("HERO SETTLE \(id) reason=watcher frame=\(HeroProbe.frameDescription(frame))")
        release(id: id)
        HeroProbe.shared.recordLanding(
            id: id, frame: frame,
            scale: flight.targetScale, cornerRadius: flight.cornerRadius
        )
        end(id: id)
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
