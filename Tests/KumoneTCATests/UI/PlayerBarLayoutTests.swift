#if os(macOS)
import AppKit
import ComposableArchitecture
import KumoneCore
import SwiftUI
import Testing
@testable import KumoneTCA

@Suite("Two-row minibar hero anchors")
@MainActor
struct PlayerBarLayoutTests {
    @Test func layoutKeepsHeroEndpointsStableAcrossModesAndStatus() async throws {
        let frames = HeroFrameStore.shared
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 940, height: 90),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            for pair in HeroID.nowPlayingPairs { frames.clear(pair.source) }
        }
        for width: CGFloat in [720, 940] {
            var restingPlayFrame: CGRect?
            for fm in [false, true] {
                for vip in [true, false] {
                    for pair in HeroID.nowPlayingPairs { frames.clear(pair.source) }
                    var state = AppFeature.State()
                    state.player.currentTrack = Track(
                        id: 1, name: "A long song title that should not displace the controls",
                        artists: [], album: AlbumRef(id: 2, name: "Album", picUrl: nil),
                        durationMS: 180_000, alias: [], transNames: [], fee: vip ? 1 : 0,
                        mvID: 0, trackNo: 0, disc: nil, noCopyright: false, isCloud: false,
                        embeddedPrivilege: nil)
                    state.player.isFMMode = fm
                    state.player.servedQuality = vip ? "lossless" : nil
                    state.player.unblockSource = fm ? "A very long third-party source name" : nil
                    let store = Store(initialState: state) { AppFeature() }
                    let bounds = BarLayoutBounds()
                    window.contentView = NSHostingView(rootView:
                        PlayerBar(appStore: store).frame(width: width, height: 90)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                bounds.frame = $0
                            })
                    window.setContentSize(NSSize(width: width, height: 90))
                    window.orderFront(nil)
                    window.contentView?.layoutSubtreeIfNeeded()
                    try await Task.sleep(nanoseconds: 100_000_000)

                    let artwork = try #require(frames.frame(for: HeroID.nowPlayingArtwork))
                    let like = try #require(frames.frame(for: HeroID.nowPlayingLike))
                    let title = try #require(frames.frame(for: HeroID.nowPlayingTitle))
                    let play = try #require(frames.frame(for: HeroID.nowPlayingPlayPause))
                    let lyrics = try #require(frames.frame(for: HeroID.nowPlayingLyrics))
                    let airplay = try #require(frames.frame(for: HeroID.nowPlayingAirPlay))
                    #expect(artwork.size == CGSize(width: 38, height: 38))
                    #expect(like.size == CGSize(width: 38, height: 38))
                    #expect(play.size == CGSize(width: 26, height: 26))
                    let barFrame = try #require(bounds.frame)
                    #expect(abs(play.midX - barFrame.midX) < 0.5,
                            "play/pause must sit at the minibar's geometric center")
                    #expect(lyrics.size == CGSize(width: 19, height: 19))
                    #expect(airplay.size == CGSize(width: 19, height: 19))
                    #expect(artwork.maxX < title.minX)
                    #expect(airplay.maxX < like.minX)
                    #expect(like.maxX > play.maxX)
                    #expect(title.maxX < play.minX)
                    let artist = try #require(frames.frame(for: HeroID.nowPlayingArtist))
                    #expect(abs(play.minY - artwork.minY) < 0.5)
                    #expect(abs(lyrics.minY - artwork.minY) < 0.5)
                    #expect(abs(airplay.maxY - artwork.maxY) < 0.5)
                    #expect(abs(title.minY - artwork.minY) < 0.5)
                    #expect(abs(artist.maxY - artwork.maxY) < 0.5)
                    #expect(abs(like.minY - artwork.minY) < 0.5)
                    #expect(abs(like.maxY - artwork.maxY) < 0.5)
                    #expect(lyrics.maxY <= airplay.minY + 0.5)
                    #expect(abs(lyrics.minX + 29 - airplay.minX) < 0.5)
                    #expect(lyrics.minX > play.maxX)
                    // VIP remains mounted at the same endpoint when unavailable.
                    let badge = try #require(frames.frame(for: HeroID.nowPlayingVIP))
                    #expect(badge.minX > play.maxX && badge.maxX < lyrics.minX)
                    #expect(abs(badge.minY - artwork.minY - 3) < 0.5,
                            "VIP outline needs the same optical inset as the title glyphs")
                    let quality = try #require(frames.frame(for: HeroID.nowPlayingQuality))
                    #expect(abs(quality.height - badge.height) < 0.5,
                            "VIP and quality outlines must have identical heights")
                    #expect(abs(quality.minX - badge.minX) < 0.5)
                    #expect(quality.minY > badge.maxY)
                    #expect(quality.maxX + 10 < lyrics.minX)
                    if let restingPlayFrame {
                        #expect(play.approximately(restingPlayFrame))
                    } else {
                        restingPlayFrame = play
                    }
                }
            }
        }
    }
}
@MainActor
private final class BarLayoutBounds {
    var frame: CGRect?
}
#endif
