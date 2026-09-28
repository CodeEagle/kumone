import SwiftUI

/// The landing end of a card→detail hero flight. Attach it to a detail
/// header's artwork, right after `.heroAnchor(_:)`: once the source a card
/// armed belongs to this view's hero id it records the target geometry and
/// hands the pair to `HeroFlightDirector`, which mounts the flying stand-in.
/// A detail page reached without an armed card sees a source id that does not
/// match and never starts a flight.
struct HeroTargetModifier: ViewModifier {
    let id: String
    let artworkURL: URL?
    let cornerRadius: CGFloat
    @Binding var hasStarted: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        content.onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { targetFrame in
            guard !hasStarted,
                  HeroProbe.shared.currentSourceID == id
            else { return }
            HeroProbe.shared.recordTarget(frame: targetFrame, scale: 1)
            HeroFlightDirector.shared.start(
                id: id,
                artworkURL: artworkURL,
                cornerRadius: cornerRadius,
                targetFrame: targetFrame,
                targetScale: 1
            )
            hasStarted = true
        }
        #else
        content
        #endif
    }
}

extension View {
    /// Marks this view as a hero flight's landing anchor and launches the
    /// flight once the armed source matches `id`. `hasStarted` belongs to
    /// the hosting view so the flight fires once per presentation.
    func heroTarget(
        id: String,
        artworkURL: URL?,
        cornerRadius: CGFloat,
        hasStarted: Binding<Bool>
    ) -> some View {
        modifier(HeroTargetModifier(
            id: id,
            artworkURL: artworkURL,
            cornerRadius: cornerRadius,
            hasStarted: hasStarted
        ))
    }
}
