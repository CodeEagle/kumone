import SwiftUI

/// Caches the most recent global frame of every hero-anchored view.
///
/// A transition trigger needs the source frame at the instant of the tap, but
/// the tap may come before the next layout pass. Anchor views report their
/// frame through `.heroAnchor(_:)` on every geometry change, so the store
/// always holds the last measured frame and the trigger reads it synchronously.
///
/// Anchor ids are not all fixed constants: detail pages register one id per
/// album, artist and playlist seen (`HeroID.album(track.album.id)` and co.),
/// so an unbounded cache would grow with everything the user ever opened.
/// The store is therefore LRU-bounded: a re-appearing view re-measures into
/// it, so evicting an idle entry costs one geometry pass, not a flight.
@MainActor
final class HeroFrameStore: ObservableObject {
    static let shared = HeroFrameStore()

    /// Frame + scale plus the insertion stamp the LRU evicts on.
    struct Entry {
        var frame: CGRect
        var scale: CGFloat
        var stamp: UInt64
    }

    @Published private(set) var frames: [String: Entry] = [:]
    /// Ids whose frame store entry now belongs to the *target* end of a
    /// flight. A trigger waiting for its source must not read one of these:
    /// the target registers under the same id, and the waiting arm would
    /// snap the source to the destination geometry — a flight that starts
    //  where it lands, which is no flight at all.
    @Published private(set) var targetOwned: Set<String> = []

    /// How many anchors the store keeps. Fixed hero ids number in the tens;
    /// the rest are per-content ids, and an evicted one is re-measured on
    /// demand.
    private let maxEntries = 512
    private var stamp: UInt64 = 0

    func set(_ id: String, frame: CGRect, scale: CGFloat) {
        stamp &+= 1
        frames[id] = Entry(frame: frame, scale: scale, stamp: stamp)
        while frames.count > maxEntries,
              let oldest = frames.min(by: { $0.value.stamp < $1.value.stamp }) {
            frames.removeValue(forKey: oldest.key)
        }
    }

    func frame(for id: String) -> CGRect? {
        frames[id]?.frame
    }

    func scale(for id: String) -> CGFloat? {
        frames[id]?.scale
    }

    /// Marks this id as target-owned, so a source that has not measured yet
    /// knows the next frame to appear is the landing view's, not the card's.
    func markTarget(_ id: String) {
        targetOwned.insert(id)
    }

    /// Lifts the target-owned mark when the detail page leaves, so the next
    /// card tap watches the store in a clean state again. The cached frame
    /// goes with it: that frame was the detail header's, and a card whose
    /// geometry never changed while the page was open does not re-measure
    /// when the home page returns — the header's landing frame would sit in
    /// the store until the next `arm` read it as a source and started the
    /// flight where it ends: no flight at all.
    func clearTarget(_ id: String) {
        targetOwned.remove(id)
        frames.removeValue(forKey: id)
    }

    func clear(_ id: String) {
        frames.removeValue(forKey: id)
        targetOwned.remove(id)
    }
}

/// Marks a view as one end of a hero transition. The view's global frame is
/// reported to `HeroFrameStore` on every geometry change; `scale` is the
/// resting `scaleEffect` the view applies (for example the Now Playing
/// artwork's 0.95), which the flight has to match when it lands.
extension View {
    func heroAnchor(_ id: String, scale: CGFloat = 1) -> some View {
        modifier(HeroAnchorModifier(id: id, scale: scale))
    }
}

private struct HeroAnchorModifier: ViewModifier {
    let id: String
    let scale: CGFloat

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            HeroFrameStore.shared.set(id, frame: frame, scale: scale)
            // A landing view that moves while its present flight is still
            // flying retargets it, so the stand-in lands where the view is
            // now rather than where it was at launch. Return flights read
            // their own anchor and are untouched here.
            HeroFlightDirector.shared.retargetLiveAnchor(frame, for: id)
        }
    }
}
