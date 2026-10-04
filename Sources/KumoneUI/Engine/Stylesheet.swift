import Foundation

/// Style rules collected from the theme file, resolved per node.
///
/// Resolution is deliberately the *whole* style story for M0: a component
/// gets one merged property bag built from
///
/// 1. the theme's named classes, in the order the node lists them, then
/// 2. the node's own inline `props` (which always win),
///
/// with `token(...)` references inside string values expanded. This mirrors
/// CSS cascade order closely enough for the use case, stays declarative, and
/// keeps the engine free of any expression logic.
public struct Stylesheet: Equatable, Sendable {
    /// Theme tokens: named values any style or component can reference.
    public var tokens: [String: Prop]
    /// Class names → property bags.
    public var rules: [String: [String: Prop]]

    public init(tokens: [String: Prop] = [:],
                rules: [String: [String: Prop]] = [:]) {
        self.tokens = tokens
        self.rules = rules
    }

    /// The merged property bag a component should read: class rules in the
    /// node's order, then the node's own props over them, with `token(name)`
    /// string references expanded.
    public func resolve(_ node: Node) -> [String: Prop] {
        var merged: [String: Prop] = [:]
        for name in node.classes {
            guard let rule = rules[name] else { continue }
            for (key, value) in rule { merged[key] = value }
        }
        for (key, value) in node.props { merged[key] = value }

        // One expansion pass: only top-level `token(name)` strings, in
        // resolved values. Nesting is not allowed — a token referencing a
        // token is a config error, reported as the raw text.
        return merged.mapValues { expand($0) }
    }

    private func expand(_ prop: Prop) -> Prop {
        guard case .string(let text) = prop else { return prop }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let prefix = "token("
        guard trimmed.hasPrefix(prefix), trimmed.hasSuffix(")") else { return prop }
        let name = String(trimmed.dropFirst(prefix.count).dropLast())
        return tokens[name] ?? prop
    }
}
