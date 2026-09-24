#if os(macOS)
import AppKit
import KumoneCore
@testable import KumoneTCA
@testable import KumoneMac
import XCTest

@MainActor
final class DockMenuTests: XCTestCase {
    private static func makeTrack(_ id: Int, _ name: String) -> Track {
        Track(
            id: id, name: name, artists: [],
            album: AlbumRef(id: 0, name: "Album", picUrl: nil),
            durationMS: 200_000, alias: [], transNames: [], fee: 0, mvID: 0, trackNo: 0,
            disc: nil, noCopyright: false, isCloud: false, embeddedPrivilege: nil)
    }

    private static func makeState(
        isPlaying: Bool = false,
        shuffleEnabled: Bool = false,
        repeatMode: RepeatMode = .off,
        recentContexts: [PlayContext] = []
    ) -> PlayerFeature.State {
        var state = PlayerFeature.State()
        state.currentTrack = makeTrack(1, "one")
        state.isPlaying = isPlaying
        state.shuffleEnabled = shuffleEnabled
        state.repeatMode = repeatMode
        state.recentContexts = recentContexts
        return state
    }

    func testMenuReflectsPlaybackState() {
        let menu = DockMenu().makeMenu(from: Self.makeState(isPlaying: true, shuffleEnabled: true)) { _ in }
        let titles = menu.items.map(\.title)
        XCTAssertEqual(titles, [
            "暂停", "",
            "下一首", "上一首", "",
            "随机播放", "循环模式"
            // No recent contexts, so that section and its separator are omitted.
        ])

        let shuffle = menu.items.first { $0.title == "随机播放" }
        XCTAssertEqual(shuffle?.state, .on)
    }

    func testTransportIsDisabledWithoutATrack() {
        var state = PlayerFeature.State()
        state.currentTrack = nil
        let menu = DockMenu().makeMenu(from: state) { _ in }
        XCTAssertFalse(menu.items.first { $0.title == "播放" }?.isEnabled ?? true)
        XCTAssertFalse(menu.items.first { $0.title == "下一首" }?.isEnabled ?? true)
        XCTAssertFalse(menu.items.first { $0.title == "上一首" }?.isEnabled ?? true)
    }

    func testRepeatSubmenuMarksTheCurrentMode() {
        let menu = DockMenu().makeMenu(from: Self.makeState(repeatMode: .one)) { _ in }
        let repeatMenu = menu.items.first { $0.title == "循环模式" }?.submenu
        let titles = repeatMenu?.items.map(\.title)
        let states = repeatMenu?.items.map(\.state)
        XCTAssertEqual(titles, ["不循环", "列表循环", "单曲循环"])
        XCTAssertEqual(states, [.off, .off, .on] as [NSControl.StateValue])
    }

    func testRecentContextsAreListed() {
        let contexts = [
            PlayContext.playlist(id: 1, name: "我喜欢的音乐"),
            PlayContext.album(id: 2, name: "专辑"),
        ]
        let menu = DockMenu().makeMenu(from: Self.makeState(recentContexts: contexts)) { _ in }
        let titles = menu.items.map(\.title)
        XCTAssertEqual(titles.suffix(3), ["最近播放", "我喜欢的音乐", "专辑"])
    }

    func testTappingAnItemDispatchesTheAction() {
        var sent: [PlayerFeature.Action] = []
        let contexts = [PlayContext.playlist(id: 1, name: "我喜欢的音乐")]
        let menu = DockMenu().makeMenu(from: Self.makeState(recentContexts: contexts)) { sent.append($0) }

        func invoke(_ title: String, in menu: NSMenu = menu) {
            guard let item = menu.items.first(where: { $0.title == title }) as? DockMenuItem else {
                XCTFail("no item named \(title)")
                return
            }
            item.onInvoke?()
        }

        invoke("下一首")
        invoke("随机播放")
        invoke("单曲循环", in: menu.items.first { $0.title == "循环模式" }!.submenu!)
        invoke("我喜欢的音乐")

        XCTAssertEqual(sent, [
            .next,
            .toggleShuffle,
            .setRepeatMode(.one),
            .playContext(contexts[0]),
        ])
    }
}
#endif
