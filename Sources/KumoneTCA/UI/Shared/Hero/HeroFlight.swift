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
        CachedAsyncImage(url: flight.artworkURL, animated: false) {
            RoundedRectangle(cornerRadius: flight.cornerRadius, style: .continuous)
                // Opaque: the stand-in has to be visible while the artwork
                // loads, or the flight is invisible against the page.
                .fill(.secondary)
        }
        // The frame interpolates size as well as position — a 38pt mini
        // artwork grows into the full Now Playing cover — so the landing
        // measurement matches the target instead of the source size.
        .frame(width: frame.width, height: frame.height)
        .clipShape(RoundedRectangle(cornerRadius: flight.cornerRadius, style: .continuous))
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
                HeroProbe.shared.recordProxyState(.initial, frame: global)
            } else {
                HeroProbe.shared.recordProxyState(.animating, frame: global)
            }
        }
        .position(
            x: frame.midX - containerFrame.origin.x,
            y: frame.midY - containerFrame.origin.y
        )
        .onAppear {
            HeroProbe.shared.recordViewport(containerFrame)
            #if os(macOS)
            HeroProbe.shared.recordWindowScale(NSApp.keyWindow?.backingScaleFactor ?? 1)
            #endif
            withAnimation(AppAnimation.heroSpring) {
                frame = flight.target
                scale = flight.targetScale
            } completion: {
                guard !finished else { return }
                finished = true
                if let measuredFrame {
                    HeroProbe.shared.recordProxyState(.landed, frame: measuredFrame)
                } else {
                    // Fail closed: no geometry ever arrived, so report the
                    // landing as unmeasured instead of papering over the gap
                    // with the target frame we asked for.
                    HeroProbe.shared.recordProxyState(.unmeasured, frame: flight.target)
                }
                HeroProbe.shared.recordLanding(
                    frame: measuredFrame ?? flight.target,
                    scale: flight.targetScale,
                    cornerRadius: flight.cornerRadius
                )
                HeroFlightDirector.shared.end()
            }
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

/// Reads the active flight from the director and renders it. Kept separate so
/// the overlay only redraws when a flight starts or ends, and so the flight can
/// translate global frames into the overlay's local coordinate space.
private struct HeroFlightHost: View {
    @ObservedObject private var director = HeroFlightDirector.shared

    var body: some View {
        GeometryReader { proxy in
            if let flight = director.active {
                HeroFlight(
                    flight: flight,
                    containerFrame: proxy.frame(in: .global)
                )
            }
        }
    }
}
