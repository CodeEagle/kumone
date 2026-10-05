import AppKit
import KumoneUI

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
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
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
        guard let key = keyName(event) else { return event }
        let pressed = pressedModifiers(event)
        guard let action = store.keymap.action(for: pressed, key: key) else {
            return event
        }
        // A bare-key binding (like space) while a text field has focus would
        // type instead of toggle, so plain-key bindings stay inert then;
        // modified ones (cmd+l) work anywhere — the editor never eats those.
        if isEditingText && pressed.isEmpty {
            return event
        }
        // Unknown action name: false, pass through, log instead of eating.
        if dispatcher.invoke(action) {
            return nil
        }
        #if DEBUG
        print("[Kumone] keymap: unknown action: \(action)")
        #endif
        return event
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
}
