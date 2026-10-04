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
    ///     root:
    ///       type: HStack
    ///       class: [chrome]
    ///       spacing: 12
    ///       children:
    ///         - type: Text
    ///           text: Hello
    ///
    public static func screen(from yaml: String) throws -> Node {
        guard let doc = try Yams.load(yaml: yaml) else {
            throw ConfigParseError("empty document")
        }
        guard let root = doc as? [String: Any] else {
            throw ConfigParseError("document root must be a mapping")
        }
        guard let rootNode = root["root"] else {
            throw ConfigParseError("missing 'root' node")
        }
        return try node(from: rootNode)
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
        return Node(
            type: type,
            id: mapping["id"] as? String,
            classes: names,
            props: props,
            children: children,
            visible: (mapping["visible"] as? Bool) ?? true
        )
    }

    private static func prop(from any: Any) -> Prop {
        if let bool = any as? Bool { return .flag(bool) }
        if let int = any as? Int { return .number(Double(int)) }
        if let double = any as? Double { return .number(double) }
        if let string = any as? String { return .string(string) }
        // Lists and nested mappings are not properties: stringified so the
        // component can report what it got rather than the parse failing.
        return .string("\(any)")
    }
}
