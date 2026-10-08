import KumoneCore
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
            startFlight(
                id: id, artworkURL: artworkURL, cornerRadius: cornerRadius,
                targetFrame: targetFrame, hasStarted: $hasStarted
            )
        }
        .onDisappear {
            HeroFrameStore.shared.clearTarget(id)
        }
        #else
        content
        #endif
    }

    /// The source can arrive after the header's first measurement — the card
    /// was tapped while its anchor was still being measured. The guard above
    /// would have missed it and the page would open without a flight, so the
    /// same window `HeroTrigger.arm` waits for is waited here: poll for the
    /// source, and start the moment it appears.
    ///
    /// The flight is handed `liveAnchorID` so it follows this header while the
    /// page's own push transition is still moving it: without that the stand-in
    /// flies to a frame the landing view has already left behind, and the two
    /// animations land at different places — the "cover doesn't line up with
    /// the page" symptom.
    private func startFlight(
        id: String,
        artworkURL: URL?,
        cornerRadius: CGFloat,
        targetFrame: CGRect,
        hasStarted: Binding<Bool>
    ) {
        // Mark before recording: a trigger still polling for its source must
        // not read the target's frame as its own.
        HeroFrameStore.shared.markTarget(id)
        HeroProbe.shared.recordTarget(id: id, frame: targetFrame, scale: 1, cornerRadius: cornerRadius)
        KumoneLogger.hero.notice("HERO TARGET measured \(id, privacy: .public)")
        if HeroProbe.shared.sourceFrame(for: id) != nil {
            launch(id: id, artworkURL: artworkURL, cornerRadius: cornerRadius,
                   targetFrame: targetFrame, hasStarted: hasStarted)
            return
        }
        KumoneLogger.hero.notice("HERO TARGET pending-source \(id, privacy: .public)")
        Task { @MainActor in
            let limit = Date().addingTimeInterval(HeroTrigger.sourceWait)
            while Date() < limit {
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard !hasStarted.wrappedValue else { return }
                if HeroProbe.shared.sourceFrame(for: id) != nil {
                    launch(id: id, artworkURL: artworkURL, cornerRadius: cornerRadius,
                           targetFrame: targetFrame, hasStarted: hasStarted)
                    return
                }
            }
        }
    }

    private func launch(
        id: String,
        artworkURL: URL?,
        cornerRadius: CGFloat,
        targetFrame: CGRect,
        hasStarted: Binding<Bool>
    ) {
        guard !hasStarted.wrappedValue else { return }
        HeroFlightDirector.shared.start(
            id: id,
            content: .artwork(url: artworkURL, cornerRadius: cornerRadius),
            targetFrame: targetFrame,
            targetScale: 1,
            liveAnchorID: id
        )
        hasStarted.wrappedValue = true
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
