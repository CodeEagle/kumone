#if os(macOS)
import AppKit
import SwiftUI
import Testing

/// TEMPORARY repro (layer-level): reads the CALayer *presentation* frame
/// every 50ms while the stand-in animates from its source frame to the
/// target frame. The hero probe's onGeometryChange reports only two
/// frames (source, target) — this settles whether the animation is really
/// not running (no intermediate presentation values) or merely not
/// observable through SwiftUI's geometry callbacks.
@Suite("Stand-in layer presentation repro")
@MainActor
struct StandinLayerReproTests {
    @Test func presentationFrameInterpolates() async throws {
        let model = ReproModel()
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ReproView(model: model))
        window.orderFront(nil)
        defer { window.close() }

        model.showStandin = true

        var trace: [CGRect] = []
        for _ in 0..<14 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if let frame = ReproProbe.layer?.presentation()?.frame {
                trace.append(frame)
            }
            if trace.count >= 12 { break }
        }
        Issue.record("trace=\(trace.map { "(\(Int($0.origin.x)),\(Int($0.origin.y)),\(Int($0.width)))" })")

        let hasIntermediate = trace.contains { $0.origin.x != 597 && $0.origin.x != 245 && $0.width != 160 && $0.width != 200 }
        #expect(hasIntermediate, "expected mid-flight frames, trace has only endpoints")
    }
}

private final class ReproModel: ObservableObject {
    @Published var showStandin = false
    var reports: [CGSize] = []
}

private struct ReproView: View {
    @ObservedObject var model: ReproModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if model.showStandin {
                ReproStandin(model: model)
            }
        }
        .frame(width: 800, height: 600)
    }
}

private enum ReproProbe {
    static weak var layer: CALayer?
}

private struct ReproStandin: View {
    let model: ReproModel
    @State private var frame = CGRect(x: 597, y: 587, width: 160, height: 160)

    var body: some View {
        LayerProbeView()
            .frame(width: frame.width, height: frame.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .position(x: frame.midX, y: frame.midY)
            .onAppear {
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        frame = CGRect(x: 245, y: 64, width: 200, height: 200)
                    }
                }
            }
    }
}

private struct LayerProbeView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.red.cgColor
        ReproProbe.layer = view.layer
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
