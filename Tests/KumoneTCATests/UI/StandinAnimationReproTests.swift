#if os(macOS)
import AppKit
import SwiftUI
import Testing

/// TEMPORARY repro: the hero stand-in's spring produces no intermediate
/// frames (PROXY jumps initial→target). This fixture mirrors the stand-in's
/// own pattern — @State frame, .frame(width:height:), .position, animate
/// from onAppear inside withAnimation — and counts how many distinct
/// geometry reports arrive between the source frame and the target frame.
@Suite("Stand-in animation repro")
@MainActor
struct StandinAnimationReproTests {
    @Test func springProducesIntermediateFrames() async throws {
        let model = ReproModel()
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ReproView(model: model))
        window.orderFront(nil)
        defer { window.close() }

        // Mount the stand-in, which animates from its source frame to the
        // target frame in onAppear — exactly as HeroFlight does.
        model.showStandin = true

        try await Task.sleep(nanoseconds: 700_000_000)
        Issue.record("reports=\(model.reports)")
        #expect(model.reports.count >= 3, "expected intermediate frames, got \(model.reports)")
        #expect(model.reports.contains { $0.width > 160 && $0.width < 200 }, "expected a mid-flight size")
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

private struct ReproStandin: View {
    let model: ReproModel
    @State private var scale: CGFloat = 1
    @State private var offset = CGSize(width: 0, height: 0)

    var body: some View {
        Color.red
            .frame(width: 160, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(scale)
            .offset(x: offset.width, y: offset.height)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { global in
                model.reports.append(global.size)
            }
            .onAppear {
                // Variant: defer one run loop so the animation starts from
                // the next render pass, not the insertion pass.
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.5), completionCriteria: .removed) {
                        scale = 1.25
                        offset = CGSize(width: -352, height: -523)
                    } completion: {
                        // unused
                    }
                }
            }
    }
}
#endif
