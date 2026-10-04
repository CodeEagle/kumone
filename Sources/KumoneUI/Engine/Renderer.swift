import Foundation
import SwiftUI

/// A resolved node handed to a component builder, with everything it needs.
///
/// The context gives a component its own merged style bag and a way to
/// render its children without knowing they are nodes — the recursion lives
/// here, components stay flat.
public struct ComponentContext {
    public let style: [String: Prop]
    /// Renders child index `i` of the node the builder received.
    public let child: (Int) -> AnyView
    public let children: [Node]

    public init(style: [String: Prop], children: [Node], child: @escaping (Int) -> AnyView) {
        self.style = style
        self.children = children
        self.child = child
    }
}

/// (node) → view. The registry maps a node's `type` to one of these;
/// built-in layouts and app components register exactly the same way a
/// plugin would, there is no second-class citizen.
public typealias ComponentBuilder = (Node, ComponentContext) -> AnyView

/// The component registry. A node type is nothing but a key in here, so the
/// engine never has to know what components exist — `HStack` and a plugin's
/// `CircularSpectrum` are indistinguishable from its side.
public enum ComponentRegistry {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var builders: [String: ComponentBuilder] = [:]

    /// Registers (or replaces) a component. Safe to call from anywhere,
    /// including app/plugin startup on any thread.
    public static func register(_ type: String, builder: @escaping ComponentBuilder) {
        lock.lock(); defer { lock.unlock() }
        builders[type] = builder
    }

    public static func resolve(_ type: String) -> ComponentBuilder? {
        lock.lock(); defer { lock.unlock() }
        return builders[type]
    }
}

/// Renders a parsed screen. A view, not a controller: SwiftUI is the display
/// backend, the node tree only describes it.
public struct ScreenView: View {
    public let root: Node
    public let stylesheet: Stylesheet

    public init(root: Node, stylesheet: Stylesheet = Stylesheet()) {
        self.root = root
        self.stylesheet = stylesheet
    }

    public var body: some View {
        NodeView(node: root, stylesheet: stylesheet)
    }
}

struct NodeView: View {
    let node: Node
    let stylesheet: Stylesheet

    var body: some View {
        // Missing or invisible nodes render nothing: the config never takes
        // the screen down, it just loses that part (diagnostics elsewhere
        // report which type was not found).
        guard node.visible else { return AnyView(EmptyView()) }
        guard let builder = ComponentRegistry.resolve(node.type) else {
            return AnyView(EmptyView())
        }
        let context = ComponentContext(style: stylesheet.resolve(node), children: node.children) { index in
            AnyView(NodeView(node: node.children[index], stylesheet: stylesheet))
        }
        return AnyView(builder(node, context))
    }
}
