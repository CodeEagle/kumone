import Foundation
import Yams

/// A keyboard shortcut as written in `keymap.yaml`: the modifiers that must
/// be held, plus one key name.
///
/// Deliberately stringly-typed: this lives in the engine so a keymap parses
/// and matches on any platform, and the *event* side (NSEvent and its
/// modifier flags) stays in the app layer, which converts a press into the
/// `(modifiers, key)` pair every match runs on.
public struct KeyBinding: Equatable, Hashable, Sendable {
    /// A held modifier. `option` is also written `alt` in configs.
    public enum Modifier: String, CaseIterable, Sendable {
        case command
        case option
        case control
        case shift
    }

    /// The modifiers the shortcut requires. Extra held modifiers still
    /// match (cmd+l fires with cmd+shift+l held) — the same leniency
    /// sxhkd-class tools use; exactness is not worth the surprise.
    public let modifiers: Set<Modifier>

    /// Normalized key name: single characters (`a`, `1`, `/`) or a named
    /// key: `space`, `return`, `escape`, `tab`, `delete`, `leftarrow`,
    /// `rightarrow`, `uparrow`, `downarrow`, `f1`…`f12`.
    public let key: String

    public init(modifiers: Set<Modifier> = [], key: String) {
        self.modifiers = modifiers
        self.key = key.lowercased()
    }

    /// Parses a shortcut text like `cmd+shift+p` or `space`.
    ///
    /// Modifier aliases: cmd/command, opt/option/alt, ctrl/ctl/control,
    /// shift. Returns nil on anything malformed (empty, dangling `+`,
    /// unknown modifier) — the caller reports the line, it does not guess.
    public static func parse(_ text: String) -> KeyBinding? {
        let parts = text.lowercased()
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // A single empty part means plain ""; `a+` or `+a` both produce an
        // empty part too (omittingEmptySubsequences: false keeps them).
        guard parts.count >= 1 else { return nil }
        var modifiers: Set<Modifier> = []
        for part in parts.dropLast() {
            guard let modifier = modifierAliases[part] else { return nil }
            modifiers.insert(modifier)
        }
        let key = parts.last ?? ""
        guard !key.isEmpty else { return nil }
        // The document `key+key` (no real last key) is caught above; a
        // shortcut ending with a dangling plus arrives as one empty last
        // part, which the guard rejects.
        return KeyBinding(modifiers: modifiers, key: key)
    }

    /// Whether a press matches: same key, required modifiers held.
    public func matches(modifiers pressed: Set<Modifier>, key: String) -> Bool {
        self.key == key.lowercased() && modifiers.isSubset(of: pressed)
    }

    private static let modifierAliases: [String: Modifier] = [
        "cmd": .command, "command": .command,
        "opt": .option, "option": .option, "alt": .option,
        "ctrl": .control, "ctl": .control, "control": .control,
        "shift": .shift, "shft": .shift,
    ]
}

/// The whole keymap: shortcuts pointing at action names, the same verbs
/// `action:` props use. Editing this file is rebinding the app — no
/// recompile, no restart, the file watcher picks it up.
public struct Keymap: Equatable, Sendable {
    /// Shortcut → action name. A dictionary because lookup is the hot path
    /// (every key press); ties between equivalent shortcuts are arbitrary,
    /// which is fine — writing the same key twice is the author's typo.
    public let bindings: [KeyBinding: String]

    public init(bindings: [KeyBinding: String] = [:]) {
        self.bindings = bindings
    }

    public static let empty = Keymap()

    /// The action a pressed combination maps to, if any.
    public func action(for modifiers: Set<KeyBinding.Modifier>, key: String) -> String? {
        bindings.first { $0.key.matches(modifiers: modifiers, key: key) }?.value
    }

    /// Parses a keymap document — a flat mapping of shortcut → action.
    ///
    ///     space: player.togglePlayPause
    ///     cmd+l: player.toggleLyricsPanel
    ///     rightarrow: player.next
    ///
    /// Unknown keys or bad rows are collected in `issues` (row by row) and
    /// skipped; a document that parses to nothing is an empty keymap, not
    /// an error — removing every binding is how you disable a shortcut.
    public static func parse(_ yaml: String, issues: inout [String]) -> Keymap {
        guard let doc = try? Yams.load(yaml: yaml) else {
            issues.append("keymap: unreadable document")
            return .empty
        }
        guard let mapping = doc as? [String: Any] else {
            issues.append("keymap: document root must be a mapping")
            return .empty
        }
        var bindings: [KeyBinding: String] = [:]
        for (shortcut, value) in mapping {
            guard let action = value as? String else {
                issues.append("keymap: '\(shortcut)' must name an action")
                continue
            }
            guard let binding = KeyBinding.parse(shortcut) else {
                issues.append("keymap: '\(shortcut)' is not a shortcut")
                continue
            }
            bindings[binding] = action
        }
        return Keymap(bindings: bindings)
    }
}
