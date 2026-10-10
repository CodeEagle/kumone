import Foundation
import KumoneCore

/// The source end of a card→detail hero flight. A card's button calls
/// `arm(_:)` with its hero id before it opens the destination; the anchor's
/// last measured frame becomes the flight's origin, exactly as the PlayerBar
/// artwork button arms the Now Playing flight.
///
/// A tap can land in the same instant a card's anchor is still being measured
/// — a lazy stack that just materialised the card, or a scroll that stopped
/// mid-pass. The immediate read is therefore allowed to miss, and `arm` waits
/// briefly for the measurement instead of giving up: giving up is the
/// "clicked and nothing flew" bug, and a card that is genuinely off-screen
/// never measures at all, so the wait costs one line in the log and nothing
/// in the flight, because no flight was possible.
@MainActor
enum HeroTrigger {
    /// How long a missing source frame is waited for. A card anchored
    /// on-screen measures within a couple of layout passes; anything still
    /// absent after this was never visible, and an invisible source has no
    /// flight to fly.
    static let sourceWait: TimeInterval = 0.3

    /// Begins the transition and records the geometry the card's
    /// `.heroAnchor` cached. Nil is a no-op, so a card without a hero id
    /// opens the destination unchanged. `sourceImageURL` is the URL the
    /// card's image was displaying: the flight's stand-in renders it so the
    /// flying cover is the cached bitmap the user was looking at — the
    /// detail page's own artwork URL can be a different URL for the same
    /// cover (feed cards expose `picUrl`, detail `coverImgUrl`), and loading
    /// it mid-flight paints the stand-in gray for its entire run.
    static func arm(_ heroID: String?, sourceImageURL: URL? = nil) {
        guard let heroID else { return }
        HeroProbe.shared.begin(heroID)
        // A target-owned entry is the landing view's frame under this id —
        // reading it immediately would start the flight at its landing
        // frame. The polling path knows to give up on it; the immediate read
        // has to check too, or a tap while the detail page is settling in
        // looks up its own destination as the source.
        if !HeroFrameStore.shared.targetOwned.contains(heroID),
           let frame = HeroFrameStore.shared.frame(for: heroID) {
            recordSource(heroID, frame: frame, waited: nil, imageURL: sourceImageURL)
            return
        }
        KumoneLogger.hero.notice("HERO ARM \(heroID, privacy: .public) pending-source")
        Task { await waitForSource(heroID, sourceImageURL: sourceImageURL) }
    }

    /// Polls the anchor store until the card's measurement lands, then arms
    /// from it. The destination's hero target retries its own gate for the
    /// same window, so a measurement that arrives late on either end still
    /// pairs them.
    private static func waitForSource(_ heroID: String, sourceImageURL: URL?) async {
        let step = UInt64(16_000_000)
        let limit = Date().addingTimeInterval(sourceWait)
        var waited: TimeInterval = 0
        while Date() < limit {
            try? await Task.sleep(nanoseconds: step)
            waited += Double(step) / 1_000_000_000
            // A target-owned entry is the landing view's frame under this id —
            // not a source. Reading it would start the flight at the target.
            if HeroFrameStore.shared.targetOwned.contains(heroID) {
                KumoneLogger.hero.notice(
                    "HERO ARM \(heroID, privacy: .public) no-source target-owned"
                )
                HeroProbe.shared.cancel(heroID)
                return
            }
            if let frame = HeroFrameStore.shared.frame(for: heroID) {
                recordSource(heroID, frame: frame, waited: waited, imageURL: sourceImageURL)
                return
            }
        }
        KumoneLogger.hero.notice(
            "HERO ARM \(heroID, privacy: .public) no-source waited=\(1000 * sourceWait, privacy: .public)ms"
        )
        // No flight will launch: clear the armed id so a detail page gating
        // its reveal on the arm is not left hidden forever.
        HeroProbe.shared.cancel(heroID)
    }

    private static func recordSource(_ heroID: String, frame: CGRect, waited: TimeInterval?, imageURL: URL? = nil) {
        HeroProbe.shared.recordSource(
            id: heroID,
            frame: frame,
            scale: HeroFrameStore.shared.scale(for: heroID) ?? 1,
            imageURL: imageURL
        )
        let tail = waited.map { " waited=\(Int(1000 * $0))ms" } ?? ""
        KumoneLogger.hero.notice("HERO ARM \(heroID, privacy: .public) source\(tail, privacy: .public)")
    }
}
