#if os(macOS)
import AppKit
import Carbon
import KumoneCore

/// Carbon hotkeys, opt-in and permission-free. Owned for app lifetime; the
/// unretained callback context is removed synchronously by shutdown().
@MainActor
public final class GlobalHotKeyManager {
    public static let shared = GlobalHotKeyManager()
    private var refs: [ShortcutAction: (id: UInt32, ref: EventHotKeyRef, shortcut: UserShortcut)] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 0
    private var dispatch: ((ShortcutAction) -> Void)?
    private let signature: OSType = 0x4B4D4E31
    public func start(manager: ShortcutManager? = nil, dispatch: @escaping (ShortcutAction) -> Void) {
        self.dispatch = dispatch
        refresh(from: manager ?? .shared)
    }
    public func refresh(from manager: ShortcutManager) {
        guard dispatch != nil else { return }
        for action in ShortcutAction.allCases {
            let shortcut = manager.shortcut(for: action, isGlobal: true)
            if shortcut.key.isEmpty { unregister(action) }
            else if let error = register(action, shortcut: shortcut) {
                KumoneLogger.app.error("HOTKEY registration failed action=\(action.rawValue, privacy: .public) error=\(error, privacy: .public)")
            }
        }
    }
    public func unregister(_ action: ShortcutAction) {
        if let old = refs.removeValue(forKey: action) { UnregisterEventHotKey(old.ref) }
    }
    public func unregisterAll() {
        for action in Array(refs.keys) { unregister(action) }
    }
    public func shutdown() {
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        dispatch = nil
    }
    public func register(_ action: ShortcutAction, shortcut: UserShortcut) -> String? {
        guard shortcut.key.count == 1, shortcut.modifiers.rawValue & ~15 == 0,
              shortcut.modifiers.intersection([.command, .control, .option]).isEmpty == false,
              let keyCode = shortcut.keyCode ?? Self.resolveKeyCode(shortcut.key) else {
            return String(localized: "全局快捷键需要 ⌘、⌃ 或 ⌥ 修饰键")
        }
        if let old = refs[action], old.shortcut.key == shortcut.key,
           old.shortcut.modifiers == shortcut.modifiers, old.shortcut.keyCode == shortcut.keyCode { return nil }
        if refs.contains(where: {
            $0.key != action && ($0.value.shortcut.keyCode ?? Self.resolveKeyCode($0.value.shortcut.key)) == keyCode
                && $0.value.shortcut.modifiers == shortcut.modifiers
        }) { return String(localized: "快捷键已被其他操作使用") }
        if eventHandler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let callback: EventHandlerUPP = { _, event, context in
                guard let context, Thread.isMainThread else { return OSStatus(eventNotHandledErr) }
                // Carbon's application event target is served by the main run loop.
                return MainActor.assumeIsolated {
                    let owner = Unmanaged<GlobalHotKeyManager>.fromOpaque(context).takeUnretainedValue()
                    var id = EventHotKeyID()
                    let result = GetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID),
                                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                    guard result == noErr, id.signature == owner.signature,
                          let action = owner.refs.first(where: { $0.value.id == id.id })?.key else {
                        return OSStatus(eventNotHandledErr)
                    }
                    owner.dispatch?(action)
                    return noErr
                }
            }
            let status = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &type,
                                            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
            guard status == noErr else { return String(localized: "无法安装全局快捷键：\(status)") }
        }
        guard nextID < UInt32.max else { return String(localized: "全局快捷键编号耗尽") }
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, shortcut.modifiers.carbonFlags,
                                        EventHotKeyID(signature: signature, id: nextID),
                                        GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return String(localized: "快捷键被系统或其他应用占用：\(status)") }
        // Commit only after the new registration succeeded, retaining the old
        // binding on any conflict/error, as in upstream #125.
        unregister(action)
        refs[action] = (nextID, ref, shortcut)
        return nil
    }
    // Native-event acceptance tests can send the exact ID registered with OS.
    var activeRegistrations: [ShortcutAction: EventHotKeyID] {
        refs.mapValues { EventHotKeyID(signature: signature, id: $0.id) }
    }
    public static func resolveKeyCode(_ key: String) -> UInt32? {
        let letters = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
                       "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16,
                       "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24,
                       "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34,
                       "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
                       "/": 44, "n": 45, "m": 46, ".": 47, "[": 33, "]": 30, "`": 50]
        if let code = letters[key.lowercased()] { return UInt32(code) }
        let special: [String: UInt32] = [" ": 49, "\t": 48, "\r": 36, "\u{1B}": 53, "\u{7F}": 51,
            "\u{F700}": 126, "\u{F701}": 125, "\u{F702}": 123, "\u{F703}": 124]
        if let code = special[key] { return code }
        let functions: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        if let scalar = key.unicodeScalars.first, (0xF704...0xF70F).contains(scalar.value) {
            return functions[Int(scalar.value - 0xF704)]
        }
        return nil
    }
}
#endif
