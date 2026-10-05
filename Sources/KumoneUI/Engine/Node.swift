import Foundation

/// A single node of a screen described by configuration.
///
/// The whole point of the config-driven UI: a screen is a *value*, not code.
/// Nodes are parsed from YAML, diffable (`Equatable`), and rendered by the
/// engine into SwiftUI. Nothing here knows about the app's state — data
/// binding is the component's business (via the environment), the tree only
/// carries structure and literals.
public struct Node: Equatable, Sendable {
    /// Component id in the registry, e.g. `HStack`, `Text`, `SpectrumBars`,
    /// or `plugin.Something` for user-registered components.
    public var type: String
    /// Stable identity for diffing and style targeting.
    public var id: String?
    /// Style class names, resolved against the theme's rules.
    public var classes: [String]
    /// Literal properties the component reads: sizes, colours, text…
    public var props: [String: Prop]
    /// Child nodes. Layouts render these; leaf components ignore them.
    public var children: [Node]
    /// Visibility. A plain boolean from YAML, or a `${path}` binding whose
    /// resolved truth decides it — the only mini-expression in the whole
    /// system, by design: screens show or hide by state, never compute it.
    public var visible: Visibility

    public init(type: String,
                id: String? = nil,
                classes: [String] = [],
                props: [String: Prop] = [:],
                children: [Node] = [],
                visible: Visibility = .always(true)) {
        self.type = type
        self.id = id
        self.classes = classes
        self.props = props
        self.children = children
        self.visible = visible
    }
}

/// How a node decides whether it is on screen.
public enum Visibility: Equatable, Sendable {
    /// Always this state, straight from the YAML.
    case always(Bool)
    /// Whatever the path resolves to, read at body time so observation
    /// follows it: truthy strings and non-zero numbers count as true, flags
    /// as themselves.
    case binding(String)
}

/// A literal property value, as written in YAML.
///
/// Deliberately tiny: strings, numbers, booleans. Colours, gradients and
/// every richer value are *strings the component interprets* (`#RRGGBB`,
/// `token(name)`), so the model stays simple and the schema stays out of the
/// engine's way. A bad literal is reported, not fatal.
///
/// One dynamic case: `.binding(path)` written in YAML as `${path}` — the
/// value is not in the file but resolved at render time through the app's
/// binding resolver, which is how a screen stops being static.
public enum Prop: Equatable, Sendable {
    case string(String)
    case number(Double)
    case flag(Bool)
    case binding(String)
}

extension Prop {
    /// Pulls the dynamic case's path, or nil for literal props.
    public var bindingPath: String? {
        if case .binding(let path) = self { return path }
        return nil
    }
}

extension Visibility {
    /// Parses a `visible:` value that may be `${path}` or a plain bool
    /// (handled by the caller); nil when it is neither.
    public static func binding(from text: String) -> Visibility? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("${"), trimmed.hasSuffix("}") else { return nil }
        let path = String(trimmed.dropFirst(2).dropLast())
            .trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        return .binding(path)
    }

    /// Truth for a resolved prop: flags as themselves, strings by being
    /// non-empty, numbers by being non-zero. Nil (unresolvable path) is false;
    /// hiding is the safe direction for an unknown binding.
    public static func truth(of prop: Prop?) -> Bool {
        switch prop {
        case .flag(let bool): return bool
        case .string(let text): return !text.isEmpty
        case .number(let value): return value != 0
        case .binding, .none: return false
        }
    }
}
