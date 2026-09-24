#if os(macOS)
import AppKit
import ComposableArchitecture
import KumoneCore
import KumoneTCA

/// Dock icon menu (right-click / long-press on the Dock tile).
///
/// AppKit asks for this menu each time it is opened, so it is rebuilt from the
/// player's current state rather than kept in sync. Layout follows what
/// Spotify and Music put there: transport controls, shuffle / repeat state,
/// and recently played tracks.
///
/// The menu holds no state of its own: it reads `PlayerFeature.State` and
/// dispatches `PlayerFeature.Action`s, so the store stays the single source of
/// truth.
@MainActor
struct DockMenu {
    /// Builds the menu. `send` hops to the store; it is a closure (not a store
    /// reference) so this type stays free of feature coupling.
    func makeMenu(from player: PlayerFeature.State, send: @escaping (PlayerFeature.Action) -> Void) -> NSMenu {
        let menu = NSMenu()
        // The Dock menu is not in the responder chain, so nothing would
        // validate the items for us.
        menu.autoenablesItems = false

        add(to: menu,
            title: player.isPlaying ? String(localized: "暂停") : String(localized: "播放"),
            action: { send(.togglePlayPause) },
            enabled: player.hasCurrentTrack)
        menu.addItem(.separator())

        add(to: menu, title: String(localized: "下一首"),
            action: { send(.next) }, enabled: player.hasCurrentTrack)
        add(to: menu, title: String(localized: "上一首"),
            action: { send(.previous) }, enabled: player.hasCurrentTrack)
        menu.addItem(.separator())

        let shuffle = add(to: menu, title: String(localized: "随机播放"),
                          action: { send(.toggleShuffle) }, enabled: true)
        shuffle.state = player.shuffleEnabled ? .on : .off

        // Three-way repeat reads better as a submenu than as one checkmark.
        let repeatItem = NSMenuItem(title: String(localized: "循环模式"),
                                    action: nil, keyEquivalent: "")
        let repeatMenu = NSMenu()
        repeatMenu.autoenablesItems = false
        for mode in RepeatMode.allCases {
            let item = add(to: repeatMenu, title: mode.menuTitle,
                           action: { send(.setRepeatMode(mode)) }, enabled: true)
            item.state = player.repeatMode == mode ? .on : .off
        }
        repeatItem.submenu = repeatMenu
        menu.addItem(repeatItem)

        if !player.recentContexts.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: String(localized: "最近播放"),
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for context in player.recentContexts {
                let item = add(to: menu, title: context.name,
                               action: { send(.playContext(context)) }, enabled: true)
                item.indentationLevel = 1
            }
        }

        return menu
    }

    @discardableResult
    private func add(
        to menu: NSMenu, title: String, action: @escaping () -> Void, enabled: Bool
    ) -> NSMenuItem {
        let item = DockMenuItem(title: title, action: #selector(DockMenuItem.invoke), keyEquivalent: "")
        item.onInvoke = action
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }
}

/// A menu item that forwards its tap to a closure — the Dock menu is not in
/// the responder chain, so there is no first responder to receive an action.
final class DockMenuItem: NSMenuItem {
    var onInvoke: (() -> Void)?

    @objc func invoke() {
        onInvoke?()
    }
}

extension RepeatMode {
    var menuTitle: String {
        switch self {
        case .off: return String(localized: "不循环")
        case .all: return String(localized: "列表循环")
        case .one: return String(localized: "单曲循环")
        }
    }
}
#endif
