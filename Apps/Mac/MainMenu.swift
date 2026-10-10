#if os(macOS)
import AppKit
import ComposableArchitecture
import KumoneCore
import KumoneTCA

@MainActor
enum MainMenu {
    private static var playerMenuDelegate: PlayerMenuDelegate?

    static func refreshPlaybackShortcuts() {
        func visit(_ menu: NSMenu) {
            for item in menu.items {
                if let raw = item.identifier?.rawValue, raw.hasPrefix("shortcut."),
                   let action = ShortcutAction(rawValue: String(raw.dropFirst(9))) {
                    applyShortcut(to: item, action: action)
                }
                if let submenu = item.submenu { visit(submenu) }
            }
        }
        if let menu = NSApp.mainMenu { visit(menu) }
    }

    static func applyShortcut(to item: NSMenuItem, action: ShortcutAction, manager: ShortcutManager? = nil) {
        let shortcut = (manager ?? .shared).shortcut(for: action, isGlobal: false)
        item.identifier = NSUserInterfaceItemIdentifier("shortcut." + action.rawValue)
        // Plain keys are handled by the local monitor, which protects editors.
        item.keyEquivalent = shortcut.modifiers.isEmpty ? "" : shortcut.key
        item.keyEquivalentModifierMask = shortcut.modifiers.nsFlags
    }

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
        let hide = NSMenuItem(title: String(localized: "隐藏 Kumone"),
                              action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.keyEquivalentModifierMask = [.command]
        appMenu.addItem(hide)
        let hideOthers = NSMenuItem(title: String(localized: "隐藏其它"),
                                    action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: String(localized: "显示全部"),
                                  action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "退出 Kumone"),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        appMenu.addItem(quit)

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
        let close = NSMenuItem(title: String(localized: "关闭窗口"),
                               action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        close.keyEquivalentModifierMask = [.command]
        windowMenu.addItem(close)
        windowMenu.addItem(.separator())
        let minimize = NSMenuItem(title: String(localized: "最小化"),
                                  action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        minimize.keyEquivalentModifierMask = [.command]
        windowMenu.addItem(minimize)
        let zoom = NSMenuItem(title: String(localized: "缩放"),
                              action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(zoom)
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
            shortcut: .togglePlayPause,
            action: { store.send(.player(.togglePlayPause)) }, enabled: player.hasCurrentTrack)
        menu.addItem(.separator())
        add(to: menu, title: String(localized: "下一首"), shortcut: .nextTrack,
            action: { store.send(.player(.next)) }, enabled: player.hasCurrentTrack)
        add(to: menu, title: String(localized: "上一首"), shortcut: .previousTrack,
            action: { store.send(.player(.previous)) }, enabled: player.hasCurrentTrack)
        menu.addItem(.separator())

        let shuffle = add(to: menu, title: String(localized: "随机播放"), shortcut: .cycleQueueOrder,
                          action: { store.send(.player(.toggleShuffle)) })
        shuffle.state = player.shuffleEnabled ? .on : .off
        let repeatItem = NSMenuItem(title: String(localized: "循环模式"), action: nil, keyEquivalent: "r")
        repeatItem.keyEquivalentModifierMask = [.command, .shift]
        MainMenu.applyShortcut(to: repeatItem, action: .cycleRepeatMode)
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
            shortcut: .toggleLike, action: {
                if let id = store.player.currentTrack?.id {
                    store.send(.account(.toggleLike(id)))
                }
            }, enabled: player.hasCurrentTrack)
        add(to: menu, title: String(localized: "歌词"), shortcut: .toggleLyrics,
            action: { store.send(.player(.togglePanel(.lyrics))) })
        add(to: menu, title: String(localized: "播放队列"), shortcut: .toggleQueue,
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
    shortcut: ShortcutAction? = nil,
    action: @escaping () -> Void, enabled: Bool = true
) -> NSMenuItem {
    let item = DockMenuItem(title: title, action: #selector(DockMenuItem.invoke), keyEquivalent: keyEquivalent)
    item.target = item
    item.onInvoke = action
    item.keyEquivalentModifierMask = modifiers
    item.isEnabled = enabled
    if let shortcut { MainMenu.applyShortcut(to: item, action: shortcut) }
    menu.addItem(item)
    return item
}
#endif
