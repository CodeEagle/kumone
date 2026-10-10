import AppKit
import KumoneUI
import KumoneTCA

/// Turns key presses into named actions by way of the user's keymap.
///
/// The app layer owns the NSEvent side of a shortcut: a press becomes the
/// `(modifiers, key)` pair the engine's `KeyBinding` matches on, and a hit
/// fires the action through the same dispatcher a Button prop uses — one
/// verb, two ways to reach it. Editing `keymap.yaml` rebinds live: the file
/// watcher reloads `ConfigStore.keymap`, and this monitor reads it per
/// press, so nothing here caches the mapping.
@MainActor
final class AppKeymapMonitor {
    private let store: ConfigStore
    private let dispatcher: ActionDispatcher
    private var monitor: Any?

    init(store: ConfigStore, dispatcher: ActionDispatcher) {
        self.store = store
        self.dispatcher = dispatcher
    }

    func start() {
        guard monitor == nil else { return }
        // .keyDown for every writable key, .systemDefined for the media
        // keys (F7–F9 and volume keys arrive there, not as keyDown).
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .systemDefined]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// nil = not ours, pass it on; swallowing (returning nil from the
    /// monitor) is what makes a shortcut *consumed*.
    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .systemDefined {
            return handleMedia(event)
        }
        return handleKeyDown(event)
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let shortcuts = ShortcutManager.shared
        if shortcuts.isRecording {
            // Returning the event lets NSMenu steal Command chords before the
            // recorder's keyDown. Deliver once and consume before menu routing.
            Self.routeRecordingEvent(event, to: NSApp.keyWindow?.firstResponder)
            return nil
        }
        if let action = shortcuts.overriddenAction(matching: event, editingText: isEditingText) {
            return dispatch(action.actionName)
        }
        guard let key = keyName(event) else { return event }
        let pressed = pressedModifiers(event)
        guard let action = Self.configuredAction(in: store.keymap, modifiers: pressed, key: key) else {
            return event
        }
        // Rebinding/clearing an action must disable its old YAML aliases too.
        // Media keys deliberately remain independent physical controls.
        if shortcuts.hasOverride(for: action) { return event }
        // A bare-key binding (like space) while a text field has focus would
        // type instead of toggle, so plain-key bindings stay inert then;
        // modified ones (cmd+l) work anywhere — the editor never eats those.
        if isEditingText && pressed.isEmpty {
            return event
        }
        return dispatch(action)
    }

    static func configuredAction(in keymap: Keymap, modifiers: Set<KeyBinding.Modifier>, key: String) -> String? {
        // A plain cmd+l must never win over cmd+shift+l by dictionary order.
        keymap.bindings[KeyBinding(modifiers: modifiers, key: key)] ?? keymap.action(for: modifiers, key: key)
    }

    static func routeRecordingEvent(_ event: NSEvent, to responder: NSResponder?) {
        (responder as? any ShortcutRecordingResponder)?.recordShortcut(event: event)
    }

    /// Media keys: their `.systemDefined` events are decoded by
    /// `mediaKeyName`; whatever fires has no modifiers, and a text field
    //  never eats them.
    private func handleMedia(_ event: NSEvent) -> NSEvent? {
        guard let name = mediaKeyName(event),
              let action = store.keymap.action(for: [], key: name) else {
            return event
        }
        return dispatch(action)
    }

    /// Fires a verb; nil consumes the key. An unknown action name still
    /// consumes (the user bound a real key to a broken verb, so the key
    //  should not also do its system thing) but says so in the log.
    private func dispatch(_ action: String) -> NSEvent? {
        #if DEBUG
        if !dispatcher.invoke(action) {
            print("[Kumone] keymap: unknown action: \(action)")
        }
        #else
        _ = dispatcher.invoke(action)
        #endif
        return nil
    }

    private var isEditingText: Bool {
        let responder = NSApp.keyWindow?.firstResponder
        return responder is NSText || responder is NSTextView
    }

    /// The modifiers actually held, in the engine's terms.
    private func pressedModifiers(_ event: NSEvent) -> Set<KeyBinding.Modifier> {
        let flags = event.modifierFlags
        var pressed: Set<KeyBinding.Modifier> = []
        if flags.contains(.command) { pressed.insert(.command) }
        if flags.contains(.option) { pressed.insert(.option) }
        if flags.contains(.control) { pressed.insert(.control) }
        if flags.contains(.shift) { pressed.insert(.shift) }
        return pressed
    }

    /// A press's key name: printable characters straight from the event,
    /// whitespace/control characters and special keys through the tables.
    private func keyName(_ event: NSEvent) -> String? {
        if let chars = event.charactersIgnoringModifiers, let first = chars.first {
            let name = characterNames[first] ?? String(first).lowercased()
            return name
        }
        return specialKeyNames[event.keyCode]
    }

    /// Characters that are written by name in configs: nobody types
    /// `" "` intending a space binding.
    private let characterNames: [Character: String] = [
        " ": "space",
        "\r": "return",
        "\n": "return",
        "\t": "tab",
        "\u{1b}": "escape",
        "\u{7f}": "delete",
        "\u{8}": "delete",
    ]

    /// Keys with no printable character: arrows and function keys, by the
    /// virtual key codes AppKit reports for them.
    private let specialKeyNames: [UInt16: String] = [
        49: "space",
        36: "return",
        53: "escape",
        48: "tab",
        51: "delete",
        123: "leftarrow",
        124: "rightarrow",
        125: "downarrow",
        126: "uparrow",
        122: "f1", 120: "f2", 99: "f3", 118: "f4",
        96: "f5", 97: "f6", 98: "f7", 100: "f8",
        101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    /// Media key presses arrive as `.systemDefined` events: the key type
    /// sits in the high half of `data1`, and a press/release byte in the
    /// low half. Only the *press* fires — the release would double every
    /// action.
    private func mediaKeyName(_ event: NSEvent) -> String? {
        guard event.subtype == mediaKeySubtype else { return nil }
        let keyType = Int((event.data1 & 0xFFFF0000) >> 16)
        let isPress = (event.data1 & 0xFF00) >> 8 == mediaKeyPressedFlag
        guard isPress else { return nil }
        return mediaKeyNames[keyType]
    }

    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS: the only `.systemDefined` subtype
    /// that carries key presses.
    private let mediaKeySubtype = NSEvent.EventSubtype(rawValue: 8)
    /// The byte AppKit writes for "this key went down".
    private let mediaKeyPressedFlag: Int32 = 0x0A

    /// NX_KEYTYPE_* values per ev_keymap.h. Volume keys stay unbound by
    /// default (the system owns them) but are nameable for a user.
    private let mediaKeyNames: [Int: String] = [
        0: "volumeup",
        1: "volumedown",
        7: "mute",
        16: "media-play",
        17: "media-next",
        18: "media-previous",
    ]
}
