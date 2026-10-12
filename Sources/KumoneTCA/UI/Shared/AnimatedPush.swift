import ComposableArchitecture
import SwiftUI

extension StoreOf<AppFeature> {
    /// Pushes a destination onto the detail stack inside an animation
    /// transaction.
    ///
    /// A bare `send(.openDestination(...))` is a plain state mutation: the
    /// detail overlay's insertion (and its removal on pop) has no animation
    /// transaction to ride, so the page snaps in and out instead of fading.
    /// Every push entry point — the feed's cards, the search results, the
    /// detail pages' "see artist / see album" links, the shell's search
    /// field, the debug push hook — routes through here for that reason.
    public func animateOpen(_ destination: Destination) {
        withAnimation(AppAnimation.smooth) {
            send(.openDestination(destination))
        }
    }
}
