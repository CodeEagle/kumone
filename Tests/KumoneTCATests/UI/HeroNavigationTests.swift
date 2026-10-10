import CoreGraphics
import Foundation
import Testing
import SwiftUI
#if os(macOS)
import AppKit
#endif
@testable import KumoneTCA

@Suite("Card detail hero navigation")
@MainActor
struct HeroNavigationTests {
    #if os(macOS)
    @Test func realHostingWindowRepeatsThreeCardFlights() async throws {
        let id = "hero-playlist-window-" + UUID().uuidString
        let model = NavigationFixtureModel()
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: NavigationFixture(id: id, model: model))
        window.orderFront(nil)
        defer {
            window.close()
            HeroFlightDirector.shared.end(id: id)
            HeroProbe.shared.cancel(id)
            HeroFrameStore.shared.clear(id)
            HeroFrameStore.shared.clear(HeroID.detailTarget(id))
        }
        try await waitUntil { HeroFrameStore.shared.frame(for: id) != nil }
        let source = try #require(HeroFrameStore.shared.frame(for: id))
        for round in 1...3 {
            HeroTrigger.arm(id)
            model.showDetail = true
            window.contentView?.layoutSubtreeIfNeeded()
            try await waitUntil {
                HeroProbe.shared.records.filter { $0.id == id }.count >= round
            }
            let record = try #require(HeroProbe.shared.records.last { $0.id == id })
            #expect(record.sourceFrame == source)
            #expect(record.verdict == .pass)
            model.showDetail = false
            window.contentView?.layoutSubtreeIfNeeded()
            try await waitUntil {
                HeroFrameStore.shared.frame(for: HeroID.detailTarget(id)) == nil
            }
            #expect(HeroFrameStore.shared.frame(for: id) == source)
        }
        // Leave while the destination is waiting for a source. A late
        // source measurement must not launch a flight on an absent page.
        HeroFrameStore.shared.clear(id)
        HeroProbe.shared.begin(id)
        model.showDetail = true
        try await waitUntil {
            HeroFrameStore.shared.frame(for: HeroID.detailTarget(id)) != nil
        }
        model.showDetail = false
        try await waitUntil { !HeroProbe.shared.isArmed(id) }
        HeroFrameStore.shared.set(id, frame: source, scale: 1)
        try await Task.sleep(nanoseconds: 350_000_000)
        #expect(HeroFlightDirector.shared.active[id] == nil)
        #expect(HeroProbe.shared.records.filter { $0.id == id }.count == 3)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Timed out waiting for the hosting window's hero transition")
        throw CancellationError()
    }
    #endif
    @Test func returningDestinationCannotOverwriteCardOnThirdEntry() {
        let store = HeroFrameStore()
        let id = HeroID.playlist(14341092621)
        let targetID = HeroID.detailTarget(id)
        let source = CGRect(x: 421, y: 280.5, width: 160, height: 160)
        let target = CGRect(x: 245, y: 64, width: 200, height: 200)
        store.set(id, frame: source, scale: 1)
        for _ in 0..<3 {
            store.markTarget(targetID)
            store.set(targetID, frame: target, scale: 1)
            #expect(store.frame(for: id) == source)
            #expect(!store.targetOwned.contains(id))
            store.clearTarget(targetID)
            // SwiftUI can report the retained destination's off-screen frame
            // after onDisappear. This reproduced the third-entry regression.
            store.set(targetID, frame: CGRect(x: 1313, y: 64, width: 200, height: 200), scale: 1)
            #expect(store.frame(for: id) == source)
            #expect(store.scale(for: id) == 1)
        }
    }

    @Test func lateTargetDoesNotMasqueradeAsMissingSource() {
        let store = HeroFrameStore()
        let id = HeroID.album(42)
        store.set(HeroID.detailTarget(id), frame: CGRect(x: 245, y: 64, width: 200, height: 200), scale: 1)
        #expect(store.frame(for: id) == nil)
    }

    @Test func armedGateSupportsSourceArrivingAfterTarget() {
        let probe = HeroProbe()
        let id = HeroID.playlist(42)
        #expect(!probe.isArmed(id))
        probe.begin(id)
        #expect(probe.isArmed(id))
        #expect(probe.sourceID(for: id) == nil)
        let source = CGRect(x: 421, y: 280.5, width: 160, height: 160)
        probe.recordSource(id: id, frame: source)
        #expect(probe.sourceFrame(for: id) == source)
        probe.cancel(id)
        #expect(!probe.isArmed(id))
        #expect(probe.sourceFrame(for: id) == nil)
    }

    @Test func sourceUpdatesCannotRetargetTheDetailFlight() {
        let probe = HeroProbe.shared
        let director = HeroFlightDirector()
        let id = "hero-playlist-unit-" + UUID().uuidString
        let targetID = HeroID.detailTarget(id)
        let source = CGRect(x: 421, y: 280.5, width: 160, height: 160)
        let target = CGRect(x: 245, y: 64, width: 200, height: 200)
        probe.begin(id)
        probe.recordSource(id: id, frame: source)
        defer {
            director.end(id: id)
            probe.cancel(id)
        }
        director.start(id: id, content: .artwork(url: nil, cornerRadius: 12),
                       targetFrame: target, targetScale: 1, liveAnchorID: targetID)
        director.retargetLiveAnchor(CGRect(x: -1000, y: 0, width: 160, height: 160), for: id)
        #expect(director.active[id]?.target == target)
        #expect(director.active[id]?.source == source)
        let settled = CGRect(x: 250, y: 64, width: 200, height: 200)
        director.retargetLiveAnchor(settled, for: targetID)
        #expect(director.active[id]?.target == settled)
    }
}

#if os(macOS)
@MainActor
private final class NavigationFixtureModel: ObservableObject {
    @Published var showDetail = false
}

private struct NavigationFixture: View {
    let id: String
    @ObservedObject var model: NavigationFixtureModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            Color.blue.frame(width: 160, height: 160)
                .heroAnchor(id)
                .offset(x: 420, y: 280)
            if model.showDetail {
                FixtureTarget(id: id).offset(x: 40, y: 40)
            }
        }
        .frame(width: 800, height: 600)
        .heroFlightOverlay()
    }
}

private struct FixtureTarget: View {
    let id: String
    @State private var started = false
    var body: some View {
        Color.blue.frame(width: 200, height: 200)
            .heroTarget(id: id, artworkURL: nil, cornerRadius: 12, hasStarted: $started)
    }
}
#endif
