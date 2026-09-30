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
                  HeroProbe.shared.sourceID(for: id) == id
            else { return }
            HeroProbe.shared.recordTarget(id: id, frame: targetFrame, scale: 1)
            HeroFlightDirector.shared.start(
                id: id,
                content: .artwork(url: artworkURL, cornerRadius: cornerRadius),
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

/// Reusable landing gate for independently armed Now Playing elements.
private struct NowPlayingHeroTargetModifier: ViewModifier {
    let id: String
    let payload: HeroContent
    let scale: CGFloat
    /// The anchor id the landing view reports its live frame under. A flight
    /// follows this anchor after launch, so a layout change mid-flight (the
    /// lyrics column collapsing and re-centring the artwork) retargets the
    /// stand-in instead of landing it at a frame that no longer exists.
    let anchorID: String
    let isPresented: Bool
    @Binding var hasStarted: Bool

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            guard isPresented, !hasStarted,
                  HeroProbe.shared.sourceFrame(for: id) != nil else { return }
            HeroProbe.shared.recordTarget(id: id, frame: frame, scale: scale, cornerRadius: payload.cornerRadius)
            HeroFlightDirector.shared.start(
                id: id, content: payload, targetFrame: frame, targetScale: scale,
                liveAnchorID: anchorID
            )
            hasStarted = true
        }
    }
}

extension View {
    func nowPlayingHeroTarget(
        id: String, content: HeroContent, scale: CGFloat = 1,
        anchorID: String,
        isPresented: Bool, hasStarted: Binding<Bool>
    ) -> some View {
        modifier(NowPlayingHeroTargetModifier(
            id: id, payload: content, scale: scale,
            anchorID: anchorID,
            isPresented: isPresented, hasStarted: hasStarted
        ))
    }
}
