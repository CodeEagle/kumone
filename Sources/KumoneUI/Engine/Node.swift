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
    /// Config-driven visibility. Kept as a plain boolean for M0 — an
    /// expression mini-language comes with the binding layer.
    public var visible: Bool

    public init(type: String,
                id: String? = nil,
                classes: [String] = [],
                props: [String: Prop] = [:],
                children: [Node] = [],
                visible: Bool = true) {
        self.type = type
        self.id = id
        self.classes = classes
        self.props = props
        self.children = children
        self.visible = visible
    }
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
