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
    /// The resolved theme, so a component that re-hosts children itself
    /// (ForEach renders its template through NodeView) can keep the cascade.
    public let stylesheet: Stylesheet
    /// Resolves `${path}` props. The engine reads it from the SwiftUI
    /// environment at body time and hands it down, so a binding read inside
    /// a component lands inside the same observation-tracking frame as the
    /// view that hosts it — changing store values rebuild the screen.
    public let resolver: BindingResolver?

    public init(style: [String: Prop],
                children: [Node],
                stylesheet: Stylesheet = Stylesheet(),
                resolver: BindingResolver? = nil,
                child: @escaping (Int) -> AnyView) {
        self.style = style
        self.children = children
        self.stylesheet = stylesheet
        self.resolver = resolver
        self.child = child
    }

    /// Resolves any prop: literals pass through, `.binding` asks the resolver.
    /// Returns nil when a binding cannot be resolved (unknown path, no host).
    public func resolve(_ prop: Prop) -> Prop? {
        guard case .binding(let path) = prop else { return prop }
        return resolver?.value(path)
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
    @Environment(\.bindingResolver) private var resolver

    var body: some View {
        // Visibility is resolved here (not precomputed) so a bound path is
        // read inside this body's observation frame — the node appears and
        // disappears as the state it points at changes, without any other
        // wiring. Unknown bindings hide (safe direction); unknown component
        // types render nothing, the same never-crash rule.
        guard isShown, let builder = ComponentRegistry.resolve(node.type) else {
            return AnyView(EmptyView())
        }
        // Read the environment here so a binding read lands in the tracking
        // frame of this body, then hand it to the component through context.
        let bindingResolver = resolver
        let context = ComponentContext(
            style: stylesheet.resolve(node),
            children: node.children,
            stylesheet: stylesheet,
            resolver: bindingResolver,
            child: { index in
                AnyView(NodeView(node: node.children[index], stylesheet: stylesheet))
            })
        return AnyView(builder(node, context))
    }

    private var isShown: Bool {
        switch node.visible {
        case .always(let visible):
            return visible
        case .binding(let path):
            return Visibility.truth(of: resolver?.value(path))
        }
    }
}
