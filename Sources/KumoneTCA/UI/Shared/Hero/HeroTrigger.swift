import Foundation

/// The source end of a card→detail hero flight. A card's button calls
/// `arm(_:)` with its hero id before it opens the destination; the anchor's
/// last measured frame becomes the flight's origin, exactly as the PlayerBar
/// artwork button arms the Now Playing flight.
@MainActor
enum HeroTrigger {
    /// Begins the transition and records the geometry the card's
    /// `.heroAnchor` cached. Nil is a no-op, so a card without a hero id
    /// opens the destination unchanged.
    static func arm(_ heroID: String?) {
        guard let heroID else { return }
        HeroProbe.shared.begin(heroID)
        if let frame = HeroFrameStore.shared.frame(for: heroID) {
            HeroProbe.shared.recordSource(
                frame: frame,
                scale: HeroFrameStore.shared.scale(for: heroID) ?? 1
            )
        }
    }
}
