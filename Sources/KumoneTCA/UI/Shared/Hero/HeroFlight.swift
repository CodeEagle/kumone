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
    /// Interpolates alongside `frame`: a fixed landing-page radius clips a
    /// 38pt mini artwork into a circle while the stand-in is still small, so
    /// the radius rides the same spring as the frame and scale.
    @State private var cornerRadius: CGFloat
    /// A landing view's frame can flap by half a point while its page's
    /// entrance spring rings down — every flap re-armed the flight's spring,
    /// and a completion that never fires (see `watchSettle`) meant the
    /// stand-in never landed at all. A target within a point of the one this
    /// spring is already flying to is the same place to the eye: keep the
    /// flight armed where it is and let the watch land it.
    @State private var armedTarget: CGRect?
    @State private var measuredFrame: CGRect?
    @State private var recordedInitialFrame = false
    @State private var finished = false

    init(flight: HeroFlightDirector.Flight, containerFrame: CGRect) {
        self.flight = flight
        self.containerFrame = containerFrame
        _frame = State(initialValue: flight.source)
        _scale = State(initialValue: flight.sourceScale)
        _cornerRadius = State(initialValue: flight.sourceCornerRadius)
    }

    var body: some View {
        flightContent
        // The frame interpolates size as well as position — a 38pt mini
        // artwork grows into the full Now Playing cover — so the landing
        // measurement matches the target instead of the source size.
        .frame(width: frame.width, height: frame.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
            animate(to: liveTarget ?? flight.target, reason: "appear")
        }
        .onChange(of: liveTarget) { _, target in
            guard let target, !finished, !frame.approximately(target) else { return }
            animate(to: target, reason: "liveAnchor")
        }
        .onChange(of: flight.target) { _, target in
            guard !finished, !frame.approximately(target) else { return }
            animate(to: target, reason: "director")
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

    private func animate(to target: CGRect, reason: String) {
        if let armed = armedTarget, armed.approximately(target, tolerance: 1.0) {
            return
        }
        armedTarget = target
        let generation = UUID()
        animationGeneration = generation
        if flight.targetAnchorID != nil || flight.liveAnchorID != nil {
            HeroProbe.shared.recordTarget(
                id: flight.id, frame: target, scale: flight.targetScale,
                cornerRadius: flight.cornerRadius
            )
        }
        let startLine = "HERO SPRING start \(flight.id)"
            + " gen=\(String(generation.uuidString.prefix(8)))"
            + " reason=\(reason)"
            + " tgt=\(HeroProbe.frameDescription(target))"
        KumoneLogger.hero.notice("\(startLine, privacy: .public)")
        HeroProbe.writeFile(startLine)
        HeroFlightDirector.shared.watchSettle(flight.id)
        withAnimation(AppAnimation.heroSpring, completionCriteria: .removed) {
            frame = target
            scale = flight.targetScale
            shadowProgress = 1
            cornerRadius = flight.targetCornerRadius
        } completion: {
            // A resize may retarget the flight while its previous spring is
            // completing. Only the latest spring can hand back to the mini bar.
            // A superseded spring still fires this completion when its animation
            // is removed; say which clause dropped it so a flight that never
            // settled is distinguishable from one that was merely interrupted.
            if finished {
                springBail("already-finished", generation: generation)
                return
            }
            guard animationGeneration == generation else {
                springBail("superseded", generation: generation)
                return
            }
            guard HeroFlightDirector.shared.active[flight.id]?.nonce == flight.nonce else {
                springBail("replaced-in-director", generation: generation)
                return
            }
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

    /// A spring whose landing was dropped by the completion guard — superseded
    /// by a retarget, replaced in the director, or fired after the flight had
    /// already settled. The verdict is deliberately skipped; the line is not.
    private func springBail(_ reason: String, generation: UUID) {
        let line = "HERO SPRING bail \(flight.id)"
            + " gen=\(String(generation.uuidString.prefix(8)))"
            + " reason=\(reason)"
        KumoneLogger.hero.notice("\(line, privacy: .public)")
        HeroProbe.writeFile(line)
    }

    @ViewBuilder
    private var flightContent: some View {
        switch flight.content {
        case let .artwork(url, cornerRadius):
            CachedAsyncImage(url: url, animated: false,
                             rendition: flight.id == HeroID.nowPlayingArtwork ? .playback : nil) {
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
            HeroIconStandIn(
                name: name, tint: tint, background: background,
                diameter: diameter, fontSize: fontSize, weight: weight,
                isNowPlaying: HeroID.nowPlayingPairs.contains { $0.source == flight.id },
                isPlayPause: flight.id == HeroID.nowPlayingPlayPause,
                isReturning: flight.targetAnchorID != nil,
                progress: shadowProgress
            )
        }
    }
}

/// The moving button carries its own background for the entire flight. Both
/// endpoints hide together, so there is no second stationary circle or blank
/// hand-off frame. The endpoint fills crossfade at the same spatial progress.
private struct HeroIconStandIn: View, Animatable {
    let name: String
    let tint: Color
    let background: HeroFill
    let diameter: CGFloat
    let fontSize: CGFloat
    let weight: Font.Weight
    let isNowPlaying: Bool
    let isPlayPause: Bool
    let isReturning: Bool
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let amount = min(max(progress, 0), 1)
        let sourceFill: HeroFill = isNowPlaying
            ? (isReturning
                ? (isPlayPause ? .white : .translucentWhite)
                : (isPlayPause ? .accent : .none))
            : background
        let sourceTint: Color = isNowPlaying && isPlayPause
            ? (isReturning ? .black.opacity(0.85) : .white)
            : tint
        GeometryReader { proxy in
            ZStack {
                Circle().fill(sourceFill.style).opacity(1 - Double(amount))
                Circle().fill(background.style).opacity(Double(amount))
                Image(systemName: name)
                    .foregroundStyle(sourceTint)
                    .opacity(1 - Double(amount))
                Image(systemName: name)
                    .foregroundStyle(tint)
                    .opacity(Double(amount))
            }
            .font(.system(
                size: fontSize * min(proxy.size.width, proxy.size.height) / diameter,
                weight: weight
            ))
            .frame(width: proxy.size.width, height: proxy.size.height)
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
                // Flights are visual stand-ins only. They must never sit in
                // front of the now-playing chrome and steal clicks from the
                // dismiss button while a flight is settling.
                .allowsHitTesting(false)
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
