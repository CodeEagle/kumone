import KumoneCore
import SwiftUI

/// The flying stand-in for a hero transition. Mount it in the app's top-most
/// overlay via `.heroFlightOverlay()`; it springs from the source frame to the
/// target frame, then reports its settled geometry to `HeroProbe`, which judges
/// the transition and writes the PASS/FAIL verdict.
struct HeroFlight: View {
    let flight: HeroFlightDirector.Flight

    /// The global origin of the overlay that hosts this view. `.position` takes
    /// coordinates in that overlay's local space, while the source and target
    /// frames are measured in `.global`, so the flight translates between them.
    let containerOrigin: CGPoint

    @State private var frame: CGRect
    @State private var scale: CGFloat = 1
    @State private var measuredFrame: CGRect?
    @State private var finished = false

    init(flight: HeroFlightDirector.Flight, containerOrigin: CGPoint) {
        self.flight = flight
        self.containerOrigin = containerOrigin
        _frame = State(initialValue: flight.source)
    }

    var body: some View {
        CachedAsyncImage(url: flight.artworkURL, animated: false) {
            RoundedRectangle(cornerRadius: flight.cornerRadius, style: .continuous)
                .fill(.secondary.opacity(0.15))
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
        }
        .position(
            x: frame.midX - containerOrigin.x,
            y: frame.midY - containerOrigin.y
        )
        .onAppear {
            withAnimation(AppAnimation.spring) {
                frame = flight.target
                scale = flight.targetScale
            } completion: {
                guard !finished else { return }
                finished = true
                HeroProbe.shared.recordLanding(
                    frame: measuredFrame ?? flight.target,
                    scale: flight.targetScale
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
                    containerOrigin: proxy.frame(in: .global).origin
                )
            }
        }
    }
}
