#if os(macOS)
import AppKit
#endif
import KumoneCore
import SwiftUI

/// The flying stand-in for a hero transition. Mount it in the app's top-most
/// overlay via `.heroFlightOverlay()`; it springs from the source frame to the
/// target frame, then reports its settled geometry to `HeroProbe`, which judges
/// the transition and writes the PASS/FAIL verdict.
struct HeroFlight: View {
    let flight: HeroFlightDirector.Flight

    /// The frame of the overlay that hosts this view, in `.global`. `.position`
    /// takes coordinates in that overlay's local space, while the source and
    /// target frames are measured in `.global`, so the flight translates between
    /// them. It is also the on-screen area the user can see, so it is handed to
    /// the probe for the visibility check.
    let containerFrame: CGRect

    @ObservedObject private var frameStore = HeroFrameStore.shared
    @State private var animationGeneration = UUID()
    @State private var shadowProgress: CGFloat = 0
    @State private var frame: CGRect
    @State private var scale: CGFloat
    @State private var measuredFrame: CGRect?
    @State private var recordedInitialFrame = false
    @State private var finished = false

    init(flight: HeroFlightDirector.Flight, containerFrame: CGRect) {
        self.flight = flight
        self.containerFrame = containerFrame
        _frame = State(initialValue: flight.source)
        _scale = State(initialValue: flight.sourceScale)
    }

    var body: some View {
        flightContent
        // The frame interpolates size as well as position — a 38pt mini
        // artwork grows into the full Now Playing cover — so the landing
        // measurement matches the target instead of the source size.
        .frame(width: frame.width, height: frame.height)
        .clipShape(RoundedRectangle(cornerRadius: flight.cornerRadius, style: .continuous))
        // The hidden endpoint views cannot supply the flying cover's shadow.
        // Keep it outside the clip and inside the resting-scale transform,
        // matching both endpoint views without changing their static styling.
        .shadow(
            color: .black.opacity(artworkShadow.opacity),
            radius: artworkShadow.radius, y: artworkShadow.offset
        )
        .scaleEffect(scale)
        // Measure the artwork as the target anchor measures it: outside its own
        // resting `scaleEffect`, so the reading is the layout frame and matches
        // the target's. `onGeometryChange` bakes outer transforms into the
        // `.global` report, so this must come after the scale and before
        // `.position` (which places the box, not its scaled rendering).
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { global in
            // The rendered frame, not the animated one, is what gets verified.
            measuredFrame = global
            // The first geometry pass is the only honest reading of where the
            // proxy starts: every later pass is already mid-flight, and the
            // pre-animation `flight.source` value would merely re-assert the
            // frame we assigned ourselves instead of measuring it.
            if !recordedInitialFrame {
                recordedInitialFrame = true
                HeroProbe.shared.recordProxyState(.initial, id: flight.id, frame: global)
            } else {
                HeroProbe.shared.recordProxyState(.animating, id: flight.id, frame: global)
            }
        }
        .position(
            x: frame.midX - containerFrame.origin.x,
            y: frame.midY - containerFrame.origin.y
        )
        .onAppear {
            HeroProbe.shared.recordViewport(containerFrame, id: flight.id)
            #if os(macOS)
            HeroProbe.shared.recordWindowScale(NSApp.keyWindow?.backingScaleFactor ?? 1, id: flight.id)
            #endif
            animate(to: liveTarget ?? flight.target)
        }
        .onChange(of: liveTarget) { _, target in
            guard let target, !finished, !frame.approximately(target) else { return }
            animate(to: target)
        }
        .onChange(of: flight.target) { _, target in
            guard !finished, !frame.approximately(target) else { return }
            animate(to: target)
        }
    }

    private var liveTarget: CGRect? {
        guard let id = flight.targetAnchorID else { return nil }
        return frameStore.frame(for: id)
    }

    private var artworkShadow: (opacity: Double, radius: CGFloat, offset: CGFloat) {
        guard flight.id == HeroID.nowPlayingArtwork else { return (0, 0, 0) }
        let amount = flight.targetAnchorID == nil ? shadowProgress : 1 - shadowProgress
        return (0.2 + 0.25 * Double(amount), 4 + 32 * amount, 2 + 16 * amount)
    }

    private func animate(to target: CGRect) {
        let generation = UUID()
        animationGeneration = generation
        if flight.targetAnchorID != nil || flight.liveAnchorID != nil {
            HeroProbe.shared.recordTarget(
                id: flight.id, frame: target, scale: flight.targetScale,
                cornerRadius: flight.cornerRadius
            )
        }
        withAnimation(AppAnimation.heroSpring, completionCriteria: .removed) {
            frame = target
            scale = flight.targetScale
            shadowProgress = 1
        } completion: {
            // A resize may retarget the flight while its previous spring is
            // completing. Only the latest spring can hand back to the mini bar.
            guard !finished, animationGeneration == generation,
                  HeroFlightDirector.shared.active[flight.id]?.nonce == flight.nonce
            else { return }
            finished = true
            if let measuredFrame {
                HeroProbe.shared.recordProxyState(.landed, id: flight.id, frame: measuredFrame)
            } else {
                HeroProbe.shared.recordProxyState(.unmeasured, id: flight.id, frame: target)
            }
            HeroProbe.shared.recordLanding(
                id: flight.id, frame: measuredFrame ?? target,
                scale: flight.targetScale, cornerRadius: flight.cornerRadius
            )
            HeroFlightDirector.shared.end(id: flight.id)
        }
    }

    @ViewBuilder
    private var flightContent: some View {
        switch flight.content {
        case let .artwork(url, cornerRadius):
            CachedAsyncImage(url: url, animated: false) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    // Opaque while the artwork loads, as in the original flight.
                    .fill(.secondary)
            }
        case let .playerTitle(text):
            HeroTitleStandIn(
                text: text,
                pageProgress: flight.targetAnchorID == nil ? shadowProgress : 1 - shadowProgress
            )
        case .vipBadge:
            VIPBadge()
        case let .text(text, color, fontSize, weight):
            Text(text)
                .font(.system(size: fontSize, weight: weight))
                .foregroundStyle(color)
                .lineLimit(1)
                // The mini marquee starts at its leading edge and clips long
                // titles. Centering/shrinking inside its flexible anchor moves
                // the visible text even when the anchor itself lands correctly.
                .fixedSize(horizontal: flight.targetAnchorID == HeroID.nowPlayingTitle, vertical: false)
                .minimumScaleFactor(flight.targetAnchorID == HeroID.nowPlayingTitle ? 1 : 0.01)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: flight.targetAnchorID == HeroID.nowPlayingTitle ? .leading : .center)
        case let .icon(name, tint, background, diameter, fontSize, weight):
            GeometryReader { proxy in
                ZStack {
                    Circle().fill(background.style)
                    Image(systemName: name)
                        .font(.system(
                            size: fontSize * min(proxy.size.width, proxy.size.height) / diameter,
                            weight: weight
                        ))
                        .foregroundStyle(tint)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }
}

/// Keep both endpoint renderers in a finite viewport. In particular, the mini
/// endpoint must use the marquee's CATextLayer metrics and edge fade, without
/// inheriting its scrolling phase. Crossfade weight/color during the flight;
/// neither renderer changes identity or switches truncation rules at landing.
private struct HeroTitleStandIn: View, Animatable {
    let text: String
    var pageProgress: CGFloat

    var animatableData: CGFloat {
        get { pageProgress }
        set { pageProgress = newValue }
    }

    var body: some View {
        let progress = min(max(pageProgress, 0), 1)
        let size = 13 + 8 * progress
        GeometryReader { proxy in
            ZStack {
                MarqueeText(text: text, fontSize: size, isPaused: true)
                    .opacity(1 - Double(progress))
                Text(text)
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .opacity(Double(progress))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }
}

extension View {
    /// Mounts the hero flight at the top of the view hierarchy so it can fly
    /// over every other surface.
    func heroFlightOverlay() -> some View {
        overlay(alignment: .topLeading) {
            HeroFlightHost()
        }
    }
}

/// Reads the active flights from the director and renders them. Kept separate so
/// the overlay only redraws when a flight starts or ends, and so the flight can
/// translate global frames into the overlay's local coordinate space.
private struct HeroFlightHost: View {
    @ObservedObject private var director = HeroFlightDirector.shared

    var body: some View {
        GeometryReader { proxy in
            ForEach(director.active.values.sorted { $0.id < $1.id }, id: \.nonce) { flight in
                HeroFlight(
                    flight: flight,
                    containerFrame: proxy.frame(in: .global)
                )
            }
        }
    }
}
