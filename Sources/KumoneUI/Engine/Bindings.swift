import Foundation
import SwiftUI

/// Resolves a `${path}` binding written in a screen file into the current
/// value it points at.
///
/// The engine never knows what a path *means* — that is the app's business,
/// and it registers paths here (the TCA store reads them directly). A
/// component calls `value(_:)` **inside its body**, so the observation
/// tracking SwiftUI runs for that body follows the read through the closure
/// and rebuilds the view when the value changes. That is the whole binding
/// layer: no compilers, no reactivity glue, just "read it in body".
public protocol BindingResolver: AnyObject {
    /// Current value of a path, or nil when the path is not registered
    /// (a screen referencing an unknown binding renders empty/nil, never
    /// crashes — same rule as unknown components). Called on the main thread
    /// from a component body.
    func value(_ path: String) -> Prop?
}

/// A resolver the app builds by registering paths. Components stay
/// declarative; this is the only place "what data exists" is answered.
///
/// Read-only: registered once at startup, queries afterwards.
/// Not final so an app can subclass it to hold the store it reads from.
open class PathBindingResolver: BindingResolver {
    private let getters: [String: () -> Prop?]

    public init(_ registrations: [String: () -> Prop?]) {
        self.getters = registrations
    }

    public func value(_ path: String) -> Prop? {
        getters[path]?() ?? nil
    }
}

/// SwiftUI environment channel for the resolver. Screens host it once near
/// the root; every component reads it through the environment.
private struct BindingResolverKey: EnvironmentKey {
    static let defaultValue: BindingResolver? = nil
}

extension EnvironmentValues {
    /// The app's resolver for `${path}` bindings. `nil` (no host) means
    /// dynamic props resolve to nothing: screens still render, just static.
    public var bindingResolver: BindingResolver? {
        get { self[BindingResolverKey.self] }
        set { self[BindingResolverKey.self] = newValue }
    }
}

/// Convenience for components: read a prop that may be a `${path}` binding
/// or a plain literal, resolving through the environment when dynamic.
public extension EnvironmentValues {
    /// Resolve any prop: literal passes through, `.binding` asks the
    /// resolver. Called from a component body so observation follows the read.
    func resolve(_ prop: Prop) -> Prop? {
        guard case .binding(let path) = prop else { return prop }
        return bindingResolver?.value(path)
    }
}
