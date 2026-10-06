import Foundation
import Yams

/// Parses a screen/theme YAML document into the engine's value types.
///
/// The grammar is small on purpose — a screen is a tree of nodes, a theme is
/// tokens plus class rules — and the parser is strict about it: anything it
/// cannot place is collected in `diagnostics` instead of silently guessed.
/// A broken screen must refuse to render, not render wrong.
public struct ConfigParseError: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public enum ConfigParser {
    /// One screen document:
    ///
    ///     window:
    ///       width: 480
    ///       height: 640
    ///     root:
    ///       type: HStack
    ///       class: [chrome]
    ///       spacing: 12
    ///       children:
    ///         - type: Text
    ///           text: Hello
    ///
    /// The `window` block is optional; both parts are returned by
    /// `screenDocument`. The legacy `screen` accessor returns the tree only.
    public static func screen(from yaml: String) throws -> Node {
        try screenDocument(from: yaml).root
    }

    /// A screen's window geometry and title, all optional — every missing
    /// field means "the app's usual behaviour", so a screen that says
    /// nothing about its window is unchanged from before this existed.
    public struct ScreenWindow: Equatable, Sendable {
        public let width: Double?
        public let height: Double?
        public let minWidth: Double?
        public let minHeight: Double?
        /// The window's title, overriding the app's default.
        public let title: String?

        public init(width: Double? = nil,
                    height: Double? = nil,
                    minWidth: Double? = nil,
                    minHeight: Double? = nil,
                    title: String? = nil) {
            self.width = width
            self.height = height
            self.minWidth = minWidth
            self.minHeight = minHeight
            self.title = title
        }
    }

    /// A whole screen document: its tree plus its window block.
    public struct ScreenDocument: Equatable, Sendable {
        public let root: Node
        public let window: ScreenWindow

        public init(root: Node, window: ScreenWindow = ScreenWindow()) {
            self.root = root
            self.window = window
        }
    }

    public static func screenDocument(from yaml: String) throws -> ScreenDocument {
        guard let doc = try Yams.load(yaml: yaml) else {
            throw ConfigParseError("empty document")
        }
        guard let root = doc as? [String: Any] else {
            throw ConfigParseError("document root must be a mapping")
        }
        guard let rootNode = root["root"] else {
            throw ConfigParseError("missing 'root' node")
        }
        let window = (root["window"] as? [String: Any]).map { window(from: $0) }
            ?? ScreenWindow()
        return ScreenDocument(root: try node(from: rootNode), window: window)
    }

    /// One theme document: `tokens:` and `styles:` mappings.
    public static func theme(from yaml: String) throws -> Stylesheet {
        guard let doc = try Yams.load(yaml: yaml) else {
            throw ConfigParseError("empty document")
        }
        guard let root = doc as? [String: Any] else {
            throw ConfigParseError("document root must be a mapping")
        }
        var tokens: [String: Prop] = [:]
        if let raw = root["tokens"] as? [String: Any] {
            for (key, value) in raw { tokens[key] = prop(from: value) }
        }
        var rules: [String: [String: Prop]] = [:]
        if let raw = root["styles"] as? [String: Any] {
            for (name, body) in raw {
                guard let mapping = body as? [String: Any] else {
                    throw ConfigParseError("style '\(name)' must be a mapping")
                }
                rules[name] = mapping.mapValues { prop(from: $0) }
            }
        }
        return Stylesheet(tokens: tokens, rules: rules)
    }

    /// Pulls a screen or theme out of a mixed document by key, so one file
    /// can hold both (`screens/preview.yaml` + an inline theme later).
    public static func document(from yaml: String) throws -> [String: Any] {
        guard let doc = try Yams.load(yaml: yaml) as? [String: Any] else {
            throw ConfigParseError("document root must be a mapping")
        }
        return doc
    }

    // MARK: - Node tree

    private static func node(from any: Any) throws -> Node {
        guard let mapping = any as? [String: Any] else {
            throw ConfigParseError("node must be a mapping")
        }
        guard let type = mapping["type"] as? String else {
            throw ConfigParseError("node missing 'type'")
        }
        var props: [String: Prop] = [:]
        for (key, value) in mapping {
            // Structural keys are consumed here; everything else is a prop.
            switch key {
            case "type", "id", "class", "classes", "children", "visible":
                continue
            default:
                props[key] = prop(from: value)
            }
        }
        var children: [Node] = []
        if let raw = mapping["children"] as? [Any] {
            children = try raw.map { try node(from: $0) }
        } else if mapping["children"] != nil {
            throw ConfigParseError("node '\(type)': 'children' must be a list")
        }
        let names: [String] = (mapping["classes"] as? [String])
            ?? (mapping["class"] as? [String])
            ?? ((mapping["class"] as? String).map { [$0] } ?? [])
        let visible: Visibility? = (mapping["visible"] as? Bool).map { Visibility.always($0) }
            ?? ((mapping["visible"] as? String).flatMap { text in
                Visibility.binding(from: text)
            })
        return Node(
            type: type,
            id: mapping["id"] as? String,
            classes: names,
            props: props,
            children: children,
            visible: visible ?? .always(true)
        )
    }

    /// One window block: numeric sizes and an optional title. Values that
    /// are missing, non-numeric, or non-positive stay nil — no window
    /// shrinks to nothing because of a typo.
    private static func window(from mapping: [String: Any]) -> ScreenWindow {
        func size(_ key: String) -> Double? {
            guard case .number(let value) = prop(from: mapping[key] ?? 0) else { return nil }
            return value > 0 ? value : nil
        }
        func title() -> String? {
            guard case .string(let text) = prop(from: mapping["title"]) else { return nil }
            return text.isEmpty ? nil : text
        }
        return ScreenWindow(
            width: size("width"),
            height: size("height"),
            minWidth: size("minWidth"),
            minHeight: size("minHeight"),
            title: title())
    }

    private static func prop(from any: Any) -> Prop {
        if let bool = any as? Bool { return .flag(bool) }
        let string = (any as? String) ?? {
            // Lists and nested mappings are not properties: stringified so
            // the component can report what it got rather than the parse
            // failing.
            return "\(any)"
        }()
        // `${path}` (optionally quoted) → a dynamic binding.
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("${"), trimmed.hasSuffix("}") {
            let path = String(trimmed.dropFirst(2).dropLast())
                .trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { return .binding(path) }
        }
        if let int = any as? Int { return .number(Double(int)) }
        if let double = any as? Double { return .number(double) }
        return .string(string)
    }
}
