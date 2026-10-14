#if os(macOS)
import AppKit
import Carbon
import SwiftUI

// Port of upstream #125, adapted to the AppKit/TCA action dispatcher.
public struct UserShortcut: Codable, Equatable {
    public var key: String
    public var modifiers: Modifiers
    public var keyCode: UInt32?
    public init(key: String, modifiers: Modifiers, keyCode: UInt32? = nil) {
        self.key = key.lowercased(); self.modifiers = modifiers; self.keyCode = keyCode
    }
    public struct Modifiers: OptionSet, Codable, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Self(rawValue: 1)
        public static let shift = Self(rawValue: 2)
        public static let option = Self(rawValue: 4)
        public static let control = Self(rawValue: 8)
        public init(_ flags: NSEvent.ModifierFlags) {
            var result: Self = []
            if flags.contains(.command) { result.insert(.command) }
            if flags.contains(.shift) { result.insert(.shift) }
            if flags.contains(.option) { result.insert(.option) }
            if flags.contains(.control) { result.insert(.control) }
            self = result
        }
        public var nsFlags: NSEvent.ModifierFlags {
            var flags: NSEvent.ModifierFlags = []
            if contains(.command) { flags.insert(.command) }
            if contains(.shift) { flags.insert(.shift) }
            if contains(.option) { flags.insert(.option) }
            if contains(.control) { flags.insert(.control) }
            return flags
        }
        var carbonFlags: UInt32 {
            var flags: UInt32 = 0
            if contains(.command) { flags |= UInt32(cmdKey) }
            if contains(.shift) { flags |= UInt32(shiftKey) }
            if contains(.option) { flags |= UInt32(optionKey) }
            if contains(.control) { flags |= UInt32(controlKey) }
            return flags
        }
    }
    public var displayString: String {
        guard !key.isEmpty else { return String(localized: "无") }
        var prefix = ""
        if modifiers.contains(.control) { prefix += "⌃" }
        if modifiers.contains(.option) { prefix += "⌥" }
        if modifiers.contains(.shift) { prefix += "⇧" }
        if modifiers.contains(.command) { prefix += "⌘" }
        let labels = [" ": "Space", "\u{F703}": "→", "\u{F702}": "←", "\u{F700}": "↑",
                      "\u{F701}": "↓", "\u{1B}": "⎋", "\r": "↩", "\t": "Tab", "\u{7F}": "⌫"]
        if let label = labels[key] { return prefix + label }
        if let scalar = key.unicodeScalars.first, (0xF704...0xF70F).contains(scalar.value) {
            return prefix + "F\(scalar.value - 0xF704 + 1)"
        }
        return prefix + key.uppercased()
    }
    public func matches(_ event: NSEvent) -> Bool {
        !key.isEmpty && event.charactersIgnoringModifiers?.lowercased() == key
            && Modifiers(event.modifierFlags) == modifiers
    }
}

public enum ShortcutAction: String, CaseIterable, Identifiable {
    case togglePlayPause, nextTrack, previousTrack, cycleQueueOrder, cycleRepeatMode
    case toggleLike, toggleLyrics, toggleQueue, closeImmersive, volumeUp, volumeDown
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .togglePlayPause: String(localized: "播放 / 暂停")
        case .nextTrack: String(localized: "下一首")
        case .previousTrack: String(localized: "上一首")
        case .cycleQueueOrder: String(localized: "切换播放顺序")
        case .cycleRepeatMode: String(localized: "切换循环模式")
        case .toggleLike: String(localized: "收藏 / 取消收藏")
        case .toggleLyrics: String(localized: "切换歌词面板")
        case .toggleQueue: String(localized: "切换播放队列")
        case .closeImmersive: String(localized: "收起播放详情")
        case .volumeUp: String(localized: "增加音量")
        case .volumeDown: String(localized: "减少音量")
        }
    }
    public var actionName: String {
        switch self {
        case .togglePlayPause: "player.togglePlayPause"
        case .nextTrack: "player.next"
        case .previousTrack: "player.previous"
        case .cycleQueueOrder: "player.toggleShuffle"
        case .cycleRepeatMode: "player.cycleRepeatMode"
        case .toggleLike: "account.toggleLike"
        case .toggleLyrics: "player.toggleLyricsPanel"
        case .toggleQueue: "player.toggleQueuePanel"
        case .closeImmersive: "app.dismissNowPlaying"
        case .volumeUp: "player.volumeUp"
        case .volumeDown: "player.volumeDown"
        }
    }
    public var defaultShortcut: UserShortcut {
        switch self {
        case .togglePlayPause: .init(key: " ", modifiers: [])
        case .nextTrack: .init(key: "\u{F703}", modifiers: .command)
        case .previousTrack: .init(key: "\u{F702}", modifiers: .command)
        case .cycleQueueOrder: .init(key: "s", modifiers: [.command, .shift])
        case .cycleRepeatMode: .init(key: "r", modifiers: [.command, .shift])
        case .toggleLike: .init(key: "l", modifiers: [.command, .shift])
        case .toggleLyrics: .init(key: "l", modifiers: .command)
        case .toggleQueue: .init(key: "u", modifiers: .command)
        case .closeImmersive: .init(key: "\u{1B}", modifiers: [])
        case .volumeUp: .init(key: "\u{F700}", modifiers: [.command, .shift])
        case .volumeDown: .init(key: "\u{F701}", modifiers: [.command, .shift])
        }
    }
}

@MainActor
public final class ShortcutManager: ObservableObject {
    public static let shared = ShortcutManager()
    @Published public private(set) var appShortcuts: [ShortcutAction: UserShortcut] = [:]
    @Published public private(set) var globalShortcuts: [ShortcutAction: UserShortcut] = [:]
    @Published public private(set) var errorMessage: String?
    @Published public var isRecording = false {
        didSet {
            guard isRecording != oldValue, self === Self.shared else { return }
            if isRecording { GlobalHotKeyManager.shared.unregisterAll() }
            else { GlobalHotKeyManager.shared.refresh(from: self) }
        }
    }
    private let defaults: UserDefaults
    private var overrides: Set<ShortcutAction> = []
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for action in ShortcutAction.allCases {
            if let data = defaults.data(forKey: "settings.shortcut." + action.rawValue),
               let saved = try? JSONDecoder().decode(UserShortcut.self, from: data), saved.key.count <= 1 {
                appShortcuts[action] = saved
                overrides.insert(action)
            } else { appShortcuts[action] = action.defaultShortcut }
            globalShortcuts[action] = defaults.data(forKey: "settings.globalShortcut." + action.rawValue)
                .flatMap { try? JSONDecoder().decode(UserShortcut.self, from: $0) }
                ?? UserShortcut(key: "", modifiers: [])
        }
    }
    public func shortcut(for action: ShortcutAction, isGlobal: Bool) -> UserShortcut {
        (isGlobal ? globalShortcuts[action] : appShortcuts[action]) ?? .init(key: "", modifiers: [])
    }
    public func hasOverride(for actionName: String) -> Bool {
        overrides.contains { $0.actionName == actionName }
    }
    public func overriddenAction(matching event: NSEvent, editingText: Bool) -> ShortcutAction? {
        guard !isRecording else { return nil }
        let modifiers = UserShortcut.Modifiers(event.modifierFlags)
        if editingText && !modifiers.contains(.command) && !modifiers.contains(.control) { return nil }
        return ShortcutAction.allCases.first { overrides.contains($0) && appShortcuts[$0]?.matches(event) == true }
    }
    @discardableResult
    public func setShortcut(_ shortcut: UserShortcut, for action: ShortcutAction, isGlobal: Bool) -> Bool {
        errorMessage = nil
        guard shortcut.key.count <= 1, shortcut.modifiers.rawValue & ~15 == 0 else {
            errorMessage = String(localized: "无效的快捷键"); return false
        }
        let bindings = isGlobal ? globalShortcuts : appShortcuts
        if !shortcut.key.isEmpty, bindings.contains(where: {
            $0.key != action && $0.value.key == shortcut.key && $0.value.modifiers == shortcut.modifiers
        }) { errorMessage = String(localized: "快捷键已被其他操作使用"); return false }
        if !isGlobal && Self.isReserved(shortcut) {
            errorMessage = String(localized: "请保留系统窗口和应用快捷键"); return false
        }
        if isGlobal {
            if shortcut.key.isEmpty { GlobalHotKeyManager.shared.unregister(action) }
            else if let error = GlobalHotKeyManager.shared.register(action, shortcut: shortcut) {
                errorMessage = error; return false
            }
            globalShortcuts[action] = shortcut
        } else {
            overrides.insert(action)
            appShortcuts[action] = shortcut
        }
        let prefix = isGlobal ? "settings.globalShortcut." : "settings.shortcut."
        defaults.set(try? JSONEncoder().encode(shortcut), forKey: prefix + action.rawValue)
        return true
    }
    public func resetToDefaults() {
        for action in ShortcutAction.allCases {
            defaults.removeObject(forKey: "settings.shortcut." + action.rawValue)
            defaults.removeObject(forKey: "settings.globalShortcut." + action.rawValue)
            appShortcuts[action] = action.defaultShortcut
            globalShortcuts[action] = .init(key: "", modifiers: [])
        }
        overrides.removeAll()
        if self === Self.shared { GlobalHotKeyManager.shared.unregisterAll() }
        errorMessage = nil
    }
    private static func isReserved(_ shortcut: UserShortcut) -> Bool {
        (shortcut.modifiers == .command && ["w", "m", "h", "q", ","].contains(shortcut.key))
        || (shortcut.modifiers == [.command, .option] && shortcut.key == "h")
    }
}
#endif
