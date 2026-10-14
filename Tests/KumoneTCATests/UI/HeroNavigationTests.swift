import CoreGraphics
import Foundation
import KumoneCore
import Testing
import SwiftUI
import ComposableArchitecture
#if os(macOS)
import AppKit
#endif
@testable import KumoneTCA

@Suite("Card detail hero navigation")
@MainActor
struct HeroNavigationTests {
    @Test func allArtworkDetailRoutesHaveMatchingReturnFlights() throws {
        let playlistID = 9_876_543_221
        let radarID = 9_876_543_222
        let albumID = 9_876_543_223
        let artistID = 9_876_543_224
        let routes: [(AppFeature.Path.State, String, Bool)] = [
            (.playlist(.init(playlistID: playlistID)), HeroID.playlist(playlistID), false),
            (.radarPlaylist(.init(playlistID: radarID)), HeroID.playlist(radarID), false),
            (.album(.init(albumID: albumID)), HeroID.album(albumID), false),
            (.artist(.init(artistID: artistID)), HeroID.artist(artistID), true),
        ]
        let card = CGRect(x: 40, y: 300, width: 128, height: 128)
        let header = CGRect(x: 100, y: 40, width: 200, height: 200)
        for (route, id, circular) in routes {
            let targetID = HeroID.detailTarget(id)
            let backID = id + "-back"
            HeroFrameStore.shared.set(id, frame: card, scale: 1)
            HeroFrameStore.shared.set(targetID, frame: header, scale: 1)
            defer {
                HeroFlightDirector.shared.end(id: backID)
                HeroProbe.shared.cancel(backID)
                HeroFrameStore.shared.clear(id)
                HeroFrameStore.shared.clear(targetID)
            }
            HeroTrigger.flyBack(top: route)
            let flight = try #require(HeroFlightDirector.shared.active[backID],
                                      "every artwork route, including radar, launches a return")
            #expect(flight.source == header)
            #expect(flight.target == card)
            #expect(flight.targetCornerRadius == (circular ? 64 : Theme.Radius.standard))
        }
    }

    #if os(macOS)
    @Test func playlistFlightLaunchesWhileDetailRequestIsStillPending() async throws {
        let playlistID = 9_876_543_210
        let id = HeroID.playlist(playlistID)
        var state = PlaylistDetailFeature.State(playlistID: playlistID)
        state.loadState = .loading
        // No response is ever sent: the actual page must expose its target
        // and launch independently of the networking effect.
        let detailStore = Store(initialState: state) {
            Reduce<PlaylistDetailFeature.State, PlaylistDetailFeature.Action> { _, _ in .none }
        }
        let appStore = Store(initialState: AppFeature.State()) {
            Reduce<AppFeature.State, AppFeature.Action> { _, _ in .none }
        }
        HeroProbe.shared.begin(id)
        HeroProbe.shared.recordSource(id: id, frame: CGRect(x: 40, y: 300, width: 160, height: 160))
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:
            PlaylistDetailView(store: detailStore, appStore: appStore).frame(width: 800, height: 600))
        window.orderFront(nil)
        defer {
            window.close()
            HeroFlightDirector.shared.end(id: id)
            HeroProbe.shared.cancel(id)
            HeroFrameStore.shared.clear(HeroID.detailTarget(id))
        }
        for _ in 0..<15 {
            if HeroFlightDirector.shared.active[id] != nil { break }
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        #expect(detailStore.detail == nil)
        #expect(detailStore.loadState == .loading)
        #expect(HeroFlightDirector.shared.active[id] != nil,
                "the card starts flying without waiting for detail data")
        let flight = try #require(HeroFlightDirector.shared.active[id])
        #expect(flight.liveAnchorID == HeroID.detailTarget(id))
        #expect(flight.targetAnchorID == nil)
        #expect(flight.animation == .spring(response: 0.36, dampingFraction: 1),
                "the actual playlist entry must select the spring without overshoot")
    }

    @Test func loadedPlaylistDefersRowConstructionUntilCoverLands() async throws {
        let playlistID = 9_876_543_225
        let id = HeroID.playlist(playlistID)
        let albumID = 9_876_543_226
        let rowAnchor = HeroID.album(albumID)
        let tracksJSON = (0..<300).map { index in
            "{\"id\":\(100_000 + index),\"name\":\"Track \(index)\",\"ar\":[],\"al\":{\"id\":\(albumID + index),\"name\":\"Album\"},\"dt\":100000,\"fee\":0}"
        }.joined(separator: ",")
        let json = "{\"id\":\(playlistID),\"name\":\"Loaded playlist\",\"trackCount\":300,\"tracks\":[\(tracksJSON)],\"trackIds\":[]}"
        let detail = try JSONDecoder().decode(PlaylistDetail.self, from: Data(json.utf8))
        var state = PlaylistDetailFeature.State(playlistID: playlistID)
        state.loadState = .loading
        let detailStore = Store(initialState: state) {
            Reduce<PlaylistDetailFeature.State, PlaylistDetailFeature.Action> { state, action in
                if case let .detailResponse(playlist, _) = action {
                    state.detail = playlist
                    state.tracks = playlist.tracks
                    state.loadState = .loaded
                }
                return .none
            }
        }
        let appStore = Store(initialState: AppFeature.State()) {
            Reduce<AppFeature.State, AppFeature.Action> { _, _ in .none }
        }
        HeroProbe.shared.begin(id)
        HeroProbe.shared.recordSource(id: id, frame: CGRect(x: 40, y: 300, width: 160, height: 160))
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:
            PlaylistDetailView(store: detailStore, appStore: appStore).frame(width: 800, height: 600))
        window.orderFront(nil)
        defer {
            window.close()
            HeroFlightDirector.shared.end(id: id)
            HeroProbe.shared.cancel(id)
            HeroFrameStore.shared.clear(HeroID.detailTarget(id))
            for index in 0..<300 { HeroFrameStore.shared.clear(HeroID.album(albumID + index)) }
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(HeroFlightDirector.shared.active[id] != nil)
        detailStore.send(.detailResponse(playlist: detail, privileges: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(detailStore.tracks.count == 300, "data remains available during the flight")
        #expect(HeroFrameStore.shared.frame(for: rowAnchor) == nil,
                "loaded data must not construct track rows during the cover flight")
        HeroProbe.shared.cancel(id)
        HeroFlightDirector.shared.end(id: id)
        try await waitUntil { HeroFrameStore.shared.frame(for: rowAnchor) != nil }
    }

    @Test func artistNameLinksCannotOverwritePortraitReturnAnchor() async throws {
        let artistID = 9_876_543_227
        let id = HeroID.artist(artistID)
        let targetID = HeroID.detailTarget(id)
        let portrait = CGRect(x: 407, y: 371, width: 128, height: 128)
        let header = CGRect(x: 245, y: 54, width: 180, height: 180)
        HeroFrameStore.shared.set(id, frame: portrait, scale: 1)
        HeroFrameStore.shared.set(targetID, frame: header, scale: 1)
        let json = "{\"id\":9876543228,\"name\":\"Song\",\"ar\":[{\"id\":\(artistID),\"name\":\"Artist\"}],\"al\":{\"id\":9876543229,\"name\":\"Album\"},\"dt\":100000,\"fee\":0}"
        let track = try JSONDecoder().decode(Track.self, from: Data(json.utf8))
        let appStore = Store(initialState: AppFeature.State()) {
            Reduce<AppFeature.State, AppFeature.Action> { _, _ in .none }
        }
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:
            TrackRow(track: track, index: 1, onPlay: {}, appStore: appStore).frame(width: 800, height: 100))
        window.orderFront(nil)
        defer {
            window.close()
            HeroFlightDirector.shared.end(id: id + "-back")
            HeroProbe.shared.cancel(id + "-back")
            HeroFrameStore.shared.clear(id)
            HeroFrameStore.shared.clear(targetID)
            HeroFrameStore.shared.clear(HeroID.album(track.album.id))
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(HeroFrameStore.shared.frame(for: id) == portrait,
                "a text link for the same artist cannot replace the 128pt portrait geometry")
        HeroTrigger.flyBack(top: .artist(.init(artistID: artistID)))
        let back = try #require(HeroFlightDirector.shared.active[id + "-back"])
        #expect(back.target == portrait)
        #expect(back.targetCornerRadius == 64)
    }

    @Test func playlistPressDoesNotMoveHeroLayoutAnchor() async throws {
        let id = "hero-card-press-" + UUID().uuidString
        let model = PressFixtureModel()
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 400, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PressFixture(id: id, model: model))
        window.orderFront(nil)
        defer {
            window.close()
            HeroFrameStore.shared.clear(id)
        }
        try await waitUntil { HeroFrameStore.shared.frame(for: id) != nil }
        let resting = try #require(HeroFrameStore.shared.frame(for: id))
        for pressed in [true, false] {
            model.isPressed = pressed
            try await Task.sleep(nanoseconds: 200_000_000)
            let frame = try #require(HeroFrameStore.shared.frame(for: id))
            #expect(frame.approximately(resting), "press feedback cannot change the flight origin")
        }
    }

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

@MainActor
private final class PressFixtureModel: ObservableObject {
    @Published var isPressed = false
}

private struct PressFixture: View {
    let id: String
    @ObservedObject var model: PressFixtureModel

    var body: some View {
        CoverCardBody(coverURL: nil, title: "Playlist", playCount: 123, heroID: id)
            .environment(\.isCardPressed, model.isPressed)
            .frame(width: 400, height: 400)
    }
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
