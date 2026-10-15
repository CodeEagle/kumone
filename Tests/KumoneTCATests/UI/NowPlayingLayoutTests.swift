#if os(macOS)
import AppKit
import ComposableArchitecture
import KumoneCore
import SwiftUI
import Testing
@testable import KumoneTCA

@Suite("Now playing control symmetry and metadata handoff", .serialized)
@MainActor
struct NowPlayingLayoutTests {
    private var longTrack: Track {
        Track(id: 401, name: "A song title", artists: [
            ArtistRef(id: 11, name: "A very long artist name that cannot fit the minibar"),
            ArtistRef(id: 12, name: "Another artist")
        ], album: AlbumRef(id: 2, name: "A long album name exclusive to the detail page", picUrl: nil),
              durationMS: 180_000, alias: [], transNames: [], fee: 1,
              mvID: 0, trackNo: 0, disc: nil, noCopyright: false, isCloud: false,
              embeddedPrivilege: nil)
    }

    @Test func controlsStayCenteredAndUtilityOrderMatchesInBothModes() async throws {
        let frames = HeroFrameStore.shared
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1080, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            for pair in HeroID.nowPlayingPairs { frames.clear(pair.target) }
        }
        for width: CGFloat in [1020, 1440] {
            for fm in [false, true] {
                for lyrics in [false, true] {
                    for pair in HeroID.nowPlayingPairs { frames.clear(pair.target) }
                    var state = AppFeature.State()
                    state.player.currentTrack = longTrack
                    state.player.isFMMode = fm
                    state.player.activePanel = lyrics ? .lyrics : nil
                    // nil lyrics keeps the loading column available for this layout test.
                    let store = Store(initialState: state) {
                        Reduce<AppFeature.State, AppFeature.Action> { _, _ in .none }
                    }
                    window.setContentSize(NSSize(width: width, height: 760))
                    window.contentView = NSHostingView(rootView:
                        NowPlayingView(onOpenDestination: { _ in })
                            .environment(\.appStore, store)
                            .environmentObject(NowPlayingArtworkStore())
                            .frame(width: width, height: 760))
                    window.orderFront(nil)
                    window.contentView?.layoutSubtreeIfNeeded()
                    try await Task.sleep(nanoseconds: 150_000_000)
                    func frame(_ id: String) throws -> CGRect {
                        try #require(frames.frame(for: id))
                    }
                    let cover = try frame(HeroID.nowPlayingArtworkTarget)
                    let play = try frame(HeroID.nowPlayingPlayPauseTarget)
                    let left = try frame(fm ? HeroID.nowPlayingFMTrashTarget : HeroID.nowPlayingPreviousTarget)
                    let next = try frame(HeroID.nowPlayingNextTarget)
                    let like = try frame(HeroID.nowPlayingLikeTarget)
                    let airplay = try frame(HeroID.nowPlayingAirPlayTarget)
                    let lyric = try frame(HeroID.nowPlayingLyricsTarget)
                    let title = try frame(HeroID.nowPlayingTitleTarget)
                    let vip = try frame(HeroID.nowPlayingVIPTarget)
                    let quality = try frame(HeroID.nowPlayingQualityTarget)
                    let trailing = fm ? try frame(HeroID.nowPlayingRoamingTarget) : quality
                    let artist = try frame(HeroID.nowPlayingArtistTarget)
                    // Without lyrics the row is wide: the title centers on its
                    // own and the tags follow its trailing edge, so short
                    // titles keep their tags close by. With the lyrics column
                    // narrowing the row, the title and its tags center as one
                    // group so the title stays as long as possible.
                    if lyrics {
                        #expect(abs((title.minX + trailing.maxX) / 2 - play.midX) < 1,
                                "center the title and its tags as one group when the lyrics column narrows the row")
                        #expect(vip.maxX < artist.maxX)
                    } else {
                        #expect(abs(title.midX - play.midX) < 1,
                                "center the title on its own while the row is wide")
                        #expect(abs(vip.minX - title.maxX - 8) < 1,
                                "the tags follow the title's trailing edge instead of sitting far off at the row's end")
                    }
                    #expect(title.maxX < trailing.minX, "the title never overlaps its tags")
                    if lyrics {
                        #expect(artist.height > 22,
                                "long artist/album metadata still wraps when the lyrics column narrows the row")
                    }
                    #expect(vip.minX > title.maxX)
                    if !lyrics {
                        #expect(artist.width > 400, "metadata width follows the column with padding, without the old 400pt cap")
                    }
                    #expect(abs(play.midX - cover.midX) < 1)
                    #expect(abs((left.midX + next.midX) / 2 - play.midX) < 1)
                    #expect(abs((airplay.midX + like.midX) / 2 - play.midX) < 1)
                    #expect(abs(airplay.midY - like.midY) < 1)
                    #expect(airplay.midX < lyric.midX && lyric.midX < play.midX && play.midX < like.midX)
                    #expect(like.size == CGSize(width: 36, height: 36))
                    if fm {
                        let roaming = try frame(HeroID.nowPlayingRoamingTarget)
                        #expect(roaming.minX >= quality.maxX)
                        #expect(abs(roaming.midY - quality.midY) < 1)
                        #expect(roaming.size == CGSize(width: 20, height: 20))
                    } else {
                        let shuffle = try frame(HeroID.nowPlayingShuffleTarget)
                        let repeatButton = try frame(HeroID.nowPlayingRepeatTarget)
                        #expect(abs((shuffle.midX + repeatButton.midX) / 2 - play.midX) < 1)
                    }
                }
            }
        }
    }

    @Test func wrappedMetadataKeepsCompleteNamesAndNavigationLinks() throws {
        let view = NowPlayingTrackDestinationLinks(track: longTrack,
            font: .system(size: 13.5), color: .white.opacity(0.65),
            onOpenDestination: { _ in }, allowsWrapping: true)
        let metadata = view.linkedMetadata
        #expect(String(metadata.characters) == longTrack.artists.map(\.name).joined(separator: " / ")
                + " — " + longTrack.album.name)
        let destinations = metadata.runs.compactMap { run in
            run.link.flatMap(NowPlayingTrackDestinationLinks.destination(for:))
        }
        #expect(destinations == [.artist(11), .artist(12), .album(2)])
        #expect(NowPlayingTrackDestinationLinks.destination(for: URL(string: "https://example.com/artist/11")!) == nil)
    }

    @Test func nowPlayingAtFullTransparencyDoesNotDarkenBackground() async throws {
        var state = AppFeature.State()
        state.settings.shaderScrimTransparency = 1
        let store = Store(initialState: state) {
            Reduce<AppFeature.State, AppFeature.Action> { _, _ in .none }
        }
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1080, height: 703),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: NowPlayingView(onOpenDestination: { _ in })
            .environment(\.appStore, store).environmentObject(NowPlayingArtworkStore())
            .frame(width: 1080, height: 703).background(Color.white))
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 150_000_000)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        for fraction in [0.05, 0.3, 0.6, 0.95] {
            let color = try #require(bitmap.colorAt(x: 10,
                y: Int(Double(bitmap.pixelsHigh - 1) * fraction))?.usingColorSpace(.deviceRGB))
            #expect(color.redComponent > 0.97 && color.greenComponent > 0.97 && color.blueComponent > 0.97,
                    "100% must not leave an extra gray/black gradient over the original shader colors")
        }
    }

    @Test func artistStandInMatchesBothEndpointPixelsIncludingTruncationAndColor() async throws {
        func pixels<V: View>(_ view: V, width: CGFloat, height: CGFloat) async throws -> Data {
            // ImageRenderer can return an empty raster for hosted text. Use a
            // live AppKit window, as the production overlay does.
            let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: width, height: height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: view.frame(width: width, height: height)
                .background(Color.black).preferredColorScheme(.dark))
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(nanoseconds: 100_000_000)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.bitmapData)
            return Data(bytes: data, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        // The mini endpoint has a single leading, truncated artist string and
        // secondary color. The detail endpoint has multiline links.
        let mini = Text(longTrack.artistNames)
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .lineLimit(1).frame(width: 120, height: 14, alignment: .bottomLeading)
        let detail = NowPlayingTrackDestinationLinks(track: longTrack,
            font: .system(size: 13.5), color: .white.opacity(0.65), onOpenDestination: { _ in }, allowsWrapping: true)
            .frame(width: 400, height: 72)
        let miniFlight = try await pixels(HeroArtistStandIn(track: longTrack, pageProgress: 0), width: 120, height: 14)
        let detailFlight = try await pixels(HeroArtistStandIn(track: longTrack, pageProgress: 1), width: 400, height: 72)
        let miniPixels = try await pixels(mini, width: 120, height: 14)
        let detailPixels = try await pixels(detail, width: 400, height: 72)
        #expect(miniFlight == miniPixels,
                "landing must preserve the minibar's truncation, baseline and secondary color")
        #expect(detailFlight == detailPixels,
                "lift-off must preserve the actual artist/album links")
        #expect(Set(miniFlight).count > 4, "the raster comparison must contain visible text")
        #expect(HeroArtistStandIn.detailOpacity(at: 0.2) == 0,
                "the return flight has already handed text and color to the mini renderer before landing")
        #expect(HeroArtistStandIn.detailOpacity(at: 0.8) == 1)
    }
}
#endif

#if os(macOS)
@Suite("Centered title leads its tag group")
@MainActor
struct CenteredPlayerTitleLayoutTests {
    @Test func longTitleCentersItselfWithTagsFollowingItsTrailingEdge() async throws {
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1296, height: 44),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // The wide, lyric-less row: the title centers on its own and the tags
        // follow immediately after it, so a truncating title pushes the tags
        // to the row's right edge while a short one keeps them close by.
        for width: CGFloat in [400, 1296] {
            for tagWidth: CGFloat in [40, 105] {
                let frames = TitleLayoutFrames()
                let content = CenteredPlayerTitleLayout(spacing: 8, badgePlacement: .trailing) {
                    Text("A very long title which must leave enough room for all playback status tags")
                        .font(.system(size: 21, weight: .bold)).lineLimit(1)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.title = $0 }
                    Color.clear.frame(width: tagWidth, height: 20)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.tags = $0 }
                }
                .frame(width: width, height: 44)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.row = $0 }
                window.setContentSize(NSSize(width: width, height: 44))
                window.contentView = NSHostingView(rootView: content)
                window.orderFront(nil)
                try await Task.sleep(nanoseconds: 70_000_000)
                let title = try #require(frames.title)
                let tags = try #require(frames.tags)
                let row = try #require(frames.row)
                #expect(abs(title.midX - row.midX) < 1, "the title centers on its own")
                #expect(abs(tags.minX - title.maxX - 8) < 1, "the tags follow the title's trailing edge")
                #expect(tags.maxX <= row.maxX + 1, "the centered title's allowance keeps the tags inside the row")
                #expect(title.width <= width - 2 * (tagWidth + 8) + 1,
                        "the centered title reserves badge space on both sides")
            }
        }
    }

    @Test func shortTitleCentersItselfWithTrailingTags() async throws {
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1296, height: 44),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let frames = TitleLayoutFrames()
        let content = CenteredPlayerTitleLayout(spacing: 8, badgePlacement: .trailing) {
            Text("Short title")
                .font(.system(size: 21, weight: .bold)).lineLimit(1)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.title = $0 }
            Color.clear.frame(width: 105, height: 20)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.tags = $0 }
        }
        .frame(width: 1296, height: 44)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.row = $0 }
        window.contentView = NSHostingView(rootView: content)
        window.orderFront(nil)
        try await Task.sleep(nanoseconds: 70_000_000)
        let title = try #require(frames.title)
        let tags = try #require(frames.tags)
        let row = try #require(frames.row)
        #expect(abs(title.midX - row.midX) < 1, "a short title also centers on its own")
        #expect(abs(tags.minX - title.maxX - 8) < 1, "the tags stay close behind the title")
        #expect(tags.maxX < row.maxX, "a short title keeps the tags well inside the row")
    }

    @Test func longTitleFillsTheRowWhileTheGroupStaysCentered() async throws {
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 400, height: 44),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for width: CGFloat in [280, 400, 512] {
            for tagWidth: CGFloat in [40, 105] {
                let frames = TitleLayoutFrames()
                let content = CenteredPlayerTitleLayout(spacing: 8) {
                    Text("A very long title which must leave enough room for all playback status tags")
                        .font(.system(size: 21, weight: .bold)).lineLimit(1)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.title = $0 }
                    Color.clear.frame(width: tagWidth, height: 20)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.tags = $0 }
                }
                .frame(width: width, height: 44)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.row = $0 }
                window.setContentSize(NSSize(width: width, height: 44))
                window.contentView = NSHostingView(rootView: content)
                window.orderFront(nil)
                try await Task.sleep(nanoseconds: 70_000_000)
                let title = try #require(frames.title)
                let tags = try #require(frames.tags)
                let row = try #require(frames.row)
                // The title only yields the tags' width once, so a long title
                // truncates as late as possible (SwiftUI rounds a truncated
                // string down to glyph boundaries, hence the range check).
                #expect(title.width <= width - tagWidth - 8 + 1,
                        "the title never takes more than a single tag allowance")
                #expect(title.width > width - 2 * (tagWidth + 8),
                        "the title uses more room than the old double reservation")
                #expect(abs(tags.minX - title.maxX - 8) < 1)
                #expect(tags.maxX <= row.maxX + 1)
                // The whole group — title plus tags — stays centred in the row,
                // with the truncated title leading just left of the centre.
                #expect(abs((title.minX + tags.maxX) / 2 - row.midX) < 1)
                #expect(title.midX < row.midX)
            }
        }
    }

    @Test func shortTitleCentersTheTagGroupWithoutTruncating() async throws {
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 512, height: 44),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let frames = TitleLayoutFrames()
        let content = CenteredPlayerTitleLayout(spacing: 8) {
            Text("Short title")
                .font(.system(size: 21, weight: .bold)).lineLimit(1)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.title = $0 }
            Color.clear.frame(width: 105, height: 20)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.tags = $0 }
        }
        .frame(width: 512, height: 44)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.row = $0 }
        window.contentView = NSHostingView(rootView: content)
        window.orderFront(nil)
        try await Task.sleep(nanoseconds: 70_000_000)
        let title = try #require(frames.title)
        let tags = try #require(frames.tags)
        let row = try #require(frames.row)
        #expect((title.minX + tags.maxX) / 2 == row.midX, "the group, not the title alone, is what centres")
        #expect(abs(tags.minX - title.maxX - 8) < 1)
        #expect(title.minX > row.minX, "a fitting title keeps its full width instead of being truncated")
    }
}

@MainActor
private final class TitleLayoutFrames {
    var title: CGRect?
    var tags: CGRect?
    var row: CGRect?
}
#endif
