#if os(macOS)
import AppKit
import ComposableArchitecture
import KumoneCore
import KumoneTCA

@MainActor
enum MainMenu {
    private static var playerMenuDelegate: PlayerMenuDelegate?

    static func install(store: StoreOf<AppFeature>, showSettings: @escaping () -> Void) {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        let appItem = NSMenuItem(title: "Kumone", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Kumone")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        appMenu.addItem(NSMenuItem(title: String(localized: "关于 Kumone"),
                                  action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        add(to: appMenu, title: String(localized: "设置…"), keyEquivalent: ",", action: showSettings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: String(localized: "隐藏 Kumone"),
                                  action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: String(localized: "隐藏其它"),
                                    action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: String(localized: "显示全部"),
                                  action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: String(localized: "退出 Kumone"),
                                  action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let playerItem = NSMenuItem(title: String(localized: "播放"), action: nil, keyEquivalent: "")
        let playerMenu = NSMenu(title: playerItem.title)
        let delegate = PlayerMenuDelegate(store: store)
        playerMenuDelegate = delegate
        playerMenu.delegate = delegate
        // Populate immediately so shortcuts exist before the first menu opening.
        delegate.menuNeedsUpdate(playerMenu)
        playerItem.submenu = playerMenu
        mainMenu.addItem(playerItem)

        let windowItem = NSMenuItem(title: String(localized: "窗口"), action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: windowItem.title)
        windowMenu.addItem(NSMenuItem(title: String(localized: "最小化"),
                                     action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: String(localized: "缩放"),
                                     action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
    }
}

@MainActor
final class PlayerMenuDelegate: NSObject, NSMenuDelegate {
    private let store: StoreOf<AppFeature>

    init(store: StoreOf<AppFeature>) {
        self.store = store
        super.init()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let store = self.store
        let player = store.player

        add(to: menu, title: player.isPlaying ? String(localized: "暂停") : String(localized: "播放"),
            action: { store.send(.player(.togglePlayPause)) }, enabled: player.hasCurrentTrack)
        menu.addItem(.separator())
        add(to: menu, title: String(localized: "下一首"), keyEquivalent: "\u{F703}",
            action: { store.send(.player(.next)) }, enabled: player.hasCurrentTrack)
        add(to: menu, title: String(localized: "上一首"), keyEquivalent: "\u{F702}",
            action: { store.send(.player(.previous)) }, enabled: player.hasCurrentTrack)
        menu.addItem(.separator())

        let shuffle = add(to: menu, title: String(localized: "随机播放"), keyEquivalent: "s",
                          modifiers: [.command, .shift], action: { store.send(.player(.toggleShuffle)) })
        shuffle.state = player.shuffleEnabled ? .on : .off
        let repeatItem = NSMenuItem(title: String(localized: "循环模式"), action: nil, keyEquivalent: "r")
        repeatItem.keyEquivalentModifierMask = [.command, .shift]
        let repeatMenu = NSMenu()
        repeatMenu.autoenablesItems = false
        for mode in RepeatMode.allCases {
            let item = add(to: repeatMenu, title: mode.menuTitle,
                           action: { store.send(.player(.setRepeatMode(mode))) })
            item.state = player.repeatMode == mode ? .on : .off
        }
        repeatItem.submenu = repeatMenu
        menu.addItem(repeatItem)
        menu.addItem(.separator())

        let sleepItem = NSMenuItem(title: String(localized: "睡眠定时"), action: nil, keyEquivalent: "")
        let sleepMenu = NSMenu()
        sleepMenu.autoenablesItems = false
        if player.sleepTimer.isActive {
            let title = player.sleepTimer.mode == .endOfCurrentTrack
                ? String(localized: "当前歌曲结束时停止") : String(localized: "睡眠定时已设定")
            let status = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            status.isEnabled = false
            sleepMenu.addItem(status)
        }
        for minutes in [15, 30, 45, 60, 90] {
            add(to: sleepMenu, title: String(localized: "\(minutes) 分钟"),
                action: { store.send(.player(.sleepTimer(.schedule(minutes: minutes)))) },
                enabled: player.hasCurrentTrack)
        }
        if player.sleepTimer.isActive {
            sleepMenu.addItem(.separator())
            add(to: sleepMenu, title: String(localized: "取消睡眠定时"),
                action: { store.send(.player(.sleepTimer(.cancel))) })
        }
        sleepItem.submenu = sleepMenu
        menu.addItem(sleepItem)
        menu.addItem(.separator())

        let liked = player.currentTrack.map { store.account.isLiked($0.id) } ?? false
        add(to: menu, title: liked ? String(localized: "取消喜欢") : String(localized: "喜欢"),
            keyEquivalent: "l", modifiers: [.command, .shift], action: {
                if let id = store.player.currentTrack?.id {
                    store.send(.account(.toggleLike(id)))
                }
            }, enabled: player.hasCurrentTrack)
        add(to: menu, title: String(localized: "歌词"), keyEquivalent: "l",
            action: { store.send(.player(.togglePanel(.lyrics))) })
        add(to: menu, title: String(localized: "播放队列"), keyEquivalent: "u",
            action: { store.send(.player(.togglePanel(.queue))) })
        #if DEBUG
        // Zero-human hero verification, same round trip as the launch-flag tour
        // in AppDelegate: logs a verdict a script can assert, no GUI needed.
        menu.addItem(.separator())
        add(to: menu, title: String(localized: "Hero 转场自检"), keyEquivalent: "h",
            modifiers: [.command, .shift]) {
            Task { await HeroSelfTest.driveRoundTrip(appStore: store) }
        }
        #endif
    }
}

@MainActor
@discardableResult
private func add(
    to menu: NSMenu, title: String, keyEquivalent: String = "",
    modifiers: NSEvent.ModifierFlags = .command,
    action: @escaping () -> Void, enabled: Bool = true
) -> NSMenuItem {
    let item = DockMenuItem(title: title, action: #selector(DockMenuItem.invoke), keyEquivalent: keyEquivalent)
    item.target = item
    item.onInvoke = action
    item.keyEquivalentModifierMask = modifiers
    item.isEnabled = enabled
    menu.addItem(item)
    return item
}
#endif
