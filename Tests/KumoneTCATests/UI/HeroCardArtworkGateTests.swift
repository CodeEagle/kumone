#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import KumoneTCA

@Suite("Hero card artwork visibility")
@MainActor
struct HeroCardArtworkGateTests {
    @Test func sourceHidesOnlyWhileStandInOwnsArtwork() async throws {
        let id = "hero-card-gate-" + UUID().uuidString
        let director = HeroFlightDirector.shared
        let probe = HeroProbe.shared
        let source = CGRect(x: 40, y: 40, width: 160, height: 160)
        let target = CGRect(x: 300, y: 40, width: 200, height: 200)
        let layerProbe = CardLayerProbe()
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:
            CardProbeView(probe: layerProbe)
                .frame(width: source.width, height: source.height)
                .heroAnchor(id)
                .heroCardArtworkGate(heroID: id)
        )
        window.orderFront(nil)
        defer {
            window.close()
            for flightID in [id, "\(id)-back"] {
                director.end(id: flightID)
                probe.cancel(flightID)
            }
            HeroFrameStore.shared.clear(id)
        }
        try await expectOpacity(1, probe: layerProbe)
        let anchor = try #require(HeroFrameStore.shared.frame(for: id))

        // Waiting for network/target layout must not leave a blank source.
        probe.begin(id)
        probe.recordSource(id: id, frame: source)
        try await expectOpacity(1, probe: layerProbe)

        // Use the page's animated transaction: the gate must still snap shut.
        withAnimation(.easeInOut(duration: 0.35)) {
            director.start(id: id, content: .artwork(url: nil, cornerRadius: 12),
                           targetFrame: target, targetScale: 1)
        }
        try await expectOpacity(0, probe: layerProbe)
        #expect(HeroFrameStore.shared.frame(for: id) == anchor)

        // Releasing the header target must not reveal the feed source.
        director.release(id: id)
        try await expectOpacity(0, probe: layerProbe)
        director.end(id: id)
        probe.cancel(id)
        try await expectOpacity(1, probe: layerProbe)

        // Preserve the existing return-target gate through landing.
        let backID = "\(id)-back"
        probe.begin(backID)
        probe.recordSource(id: backID, frame: target)
        director.start(id: backID, content: .artwork(url: nil, cornerRadius: 12),
                       targetFrame: source, targetScale: 1)
        try await expectOpacity(0, probe: layerProbe)
        director.end(id: backID)
        probe.cancel(backID)
        try await expectOpacity(1, probe: layerProbe)

        // An arm cancelled before launch cannot leave the card hidden.
        probe.begin(id)
        probe.cancel(id)
        try await expectOpacity(1, probe: layerProbe)
    }

    private func expectOpacity(_ expected: Float, probe: CardLayerProbe) async throws {
        // Allow view updates to commit, then read rendered ancestor opacity.
        try await Task.sleep(nanoseconds: 50_000_000)
        let opacity = try #require(probe.effectiveOpacity)
        #expect(abs(opacity - expected) < 0.05)
    }
}

@MainActor
private final class CardLayerProbe {
    weak var view: NSView?

    var effectiveOpacity: Float? {
        guard let layer = view?.layer else { return nil }
        var node: CALayer? = layer
        var opacity: Float = 1
        while let current = node {
            opacity = min(opacity, current.presentation()?.opacity ?? current.opacity)
            node = current.superlayer
        }
        return opacity
    }
}

private struct CardProbeView: NSViewRepresentable {
    let probe: CardLayerProbe

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.blue.cgColor
        probe.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
