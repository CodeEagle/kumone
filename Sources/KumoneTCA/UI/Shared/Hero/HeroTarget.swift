import KumoneCore
import SwiftUI

/// The landing end of a card→detail hero flight. Attach it to a detail
/// header's artwork: it owns a separate destination anchor. Once the source a card
/// armed belongs to this view's hero id it records the target geometry and
/// hands the pair to `HeroFlightDirector`, which mounts the flying stand-in.
/// A detail page reached without an armed card sees a source id that does not
/// match and never starts a flight.
struct HeroTargetModifier: ViewModifier {
    let id: String
    let artworkURL: URL?
    let cornerRadius: CGFloat
    @Binding var hasStarted: Bool
    @State private var measuredTarget: CGRect?

    private var anchorID: String { HeroID.detailTarget(id) }

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .heroAnchor(anchorID)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                measuredTarget = frame
            }
            // Owned by the destination's lifetime: leaving or retargeting
            // cancels the pending wait, so an old page cannot launch later.
            .task(id: measuredTarget) {
                guard let target = measuredTarget, !hasStarted,
                      HeroProbe.shared.isArmed(id) else { return }
                let deadline = Date().addingTimeInterval(HeroTrigger.sourceWait)
                while HeroProbe.shared.sourceFrame(for: id) == nil {
                    guard !Task.isCancelled, Date() < deadline else { return }
                    do { try await Task.sleep(nanoseconds: 16_000_000) }
                    catch { return }
                }
                guard !Task.isCancelled, !hasStarted else { return }
                HeroFrameStore.shared.markTarget(anchorID)
                HeroProbe.shared.recordTarget(id: id, frame: target, scale: 1, cornerRadius: cornerRadius)
                HeroFlightDirector.shared.start(
                    id: id,
                    // The source card's URL, when the arm carried it, is the
                    // bitmap the user was looking at and the cache already
                    // holds; the detail page's own URL can be a different URL
                    // for the same cover and would load too late for the
                    // flight, painting the stand-in gray for its whole run.
                    content: .artwork(
                        url: HeroProbe.shared.sourceImageURL(for: id) ?? artworkURL,
                        cornerRadius: cornerRadius
                    ),
                    targetFrame: target,
                    targetScale: 1,
                    liveAnchorID: anchorID
                )
                hasStarted = true
                KumoneLogger.hero.notice("HERO TARGET launched \(id, privacy: .public)")
            }
            .onDisappear {
                HeroFrameStore.shared.clearTarget(anchorID)
                HeroProbe.shared.cancel(id)
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
                id: id, content: payload, targetFrame: frame, targetScale: scale
                // The now-playing page is already laid out when its controls
                // report this frame. Following the anchor during the flight
                // makes any titlebar/toolbar re-measure retarget the stand-in
                // and produces a visible one-frame snap. Lock this landing
                // frame; card-detail targets still use the live anchor path.
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
