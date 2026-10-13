#if os(macOS)
import AppKit
import SwiftUI
import Testing

/// The detail stack's insertion transition must be identity, and the pages
/// gate their arrival on `hasAppeared` (opacity 0 until the hero flight
/// launches). This locks the invariant: while that gate is closed, the page
/// stays invisible through the push — an insertion transition that animates
/// opacity (plain `.transition(.opacity)`) drives the inserting view's
/// opacity directly for the animation's duration and bypasses the gate,
/// flashing the page's background over the feed before snapping back to
/// invisible ("背景挡一下").
@Suite("Transition vs opacity gate")
@MainActor
struct TransitionGateTests {
    @Test func identityInsertionKeepsGatedPageInvisible() async throws {
        let model = GateModel()
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: GateFixture(model: model))
        window.orderFront(nil)
        defer { window.close() }

        withAnimation(.easeInOut(duration: 0.35)) {
            model.showDetail = true
        }

        // The page mounts asynchronously; poll for its layer, then sample
        // mid-push and after the push animation commits.
        for _ in 0..<40 {
            if GateProbe.view?.superview?.layer != nil { break }
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        let midOpacity = effectiveOpacity()
        try await Task.sleep(nanoseconds: 600_000_000)
        let endOpacity = effectiveOpacity()

        #expect(midOpacity != nil, "probe view mounted")
        #expect((midOpacity ?? 1) < 0.05, "gate holds during the push: \(midOpacity ?? -1)")
        #expect((endOpacity ?? 1) < 0.05, "gate holds after the push: \(endOpacity ?? -1)")
    }

    /// The minimum presented opacity along the probe's ancestor chain —
    /// SwiftUI applies page-level opacity on an ancestor layer.
    private func effectiveOpacity() -> Float? {
        guard let layer = GateProbe.view?.superview?.layer ?? GateProbe.view?.layer else { return nil }
        var node: CALayer? = layer
        var minOpacity: Float = 1
        while let current = node {
            let opacity = current.presentation()?.opacity ?? current.opacity
            if opacity < minOpacity { minOpacity = opacity }
            node = current.superlayer
        }
        return minOpacity
    }
}

private final class GateModel: ObservableObject {
    @Published var showDetail = false
    /// Mirrors the detail pages' `hasAppeared`: stays closed the whole run.
    @Published var pageVisible = false
}

private enum GateProbe {
    static weak var view: NSView?
}

private struct LayerProbeView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.red.cgColor
        GateProbe.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct GateFixture: View {
    @ObservedObject var model: GateModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            Color.gray.frame(width: 300, height: 300)
            if model.showDetail {
                LayerProbeView()
                    .frame(width: 400, height: 400)
                    .opacity(model.pageVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.35), value: model.pageVisible)
                    // Same shape as the detail stack: identity insertion so
                    // the gated opacity is the only thing that can reveal
                    // the page; opacity fade on removal.
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
        }
        .frame(width: 800, height: 600)
    }
}
#endif
