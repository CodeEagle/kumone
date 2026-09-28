import SwiftUI

/// Caches the most recent global frame of every hero-anchored view.
///
/// A transition trigger needs the source frame at the instant of the tap, but
/// the tap may come before the next layout pass. Anchor views report their
/// frame through `.heroAnchor(_:)` on every geometry change, so the store
/// always holds the last measured frame and the trigger reads it synchronously.
@MainActor
final class HeroFrameStore: ObservableObject {
    static let shared = HeroFrameStore()

    @Published private(set) var frames: [String: CGRect] = [:]
    @Published private(set) var scales: [String: CGFloat] = [:]

    func set(_ id: String, frame: CGRect, scale: CGFloat) {
        frames[id] = frame
        scales[id] = scale
    }

    func frame(for id: String) -> CGRect? {
        frames[id]
    }

    func scale(for id: String) -> CGFloat? {
        scales[id]
    }

    func clear(_ id: String) {
        frames.removeValue(forKey: id)
        scales.removeValue(forKey: id)
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
        }
    }
}
