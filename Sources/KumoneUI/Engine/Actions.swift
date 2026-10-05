import Foundation
import SwiftUI

/// Dispatches a named action, e.g. `player.next` written as a prop.
///
/// Mirrors the binding resolver: the engine never knows what an action does
/// — the app registers handlers, and a screen names them. Actions are the
/// *only* way config reaches behaviour, so screens stay declarative:
/// structure says what, actions say what happens, and neither says how.
public protocol ActionDispatcher: AnyObject {
    /// Runs the handler for a name, optionally carrying one argument — a
    /// value the screen cannot know at authoring time (where a slider was
    /// dragged to). Returns whether one was registered — false means the
    /// screen references an action the app does not know, which the caller
    /// surfaces instead of silently doing nothing.
    @discardableResult
    func invoke(_ action: String, with argument: Prop?) -> Bool
}

public extension ActionDispatcher {
    /// The no-argument form every button uses: identical to passing nil.
    @discardableResult
    func invoke(_ action: String) -> Bool {
        invoke(action, with: nil)
    }
}

/// The registry the app fills at startup. Handlers are plain closures, so
/// an app's actions are the public counterpart of its binding path table.
///
/// Two register shapes exist because most verbs take no argument at all
/// (`player.next`) while a few need a runtime value (`player.seek` with the
/// dragged-to position); both map to the same storage.
public final class ActionRegistry: ActionDispatcher {
    private let lock = NSLock()
    private nonisolated(unsafe) var actions: [String: (Prop?) -> Void] = [:]

    public init() {}

    /// Handler that ignores any argument — the common case.
    public func register(_ name: String, handler: @escaping () -> Void) {
        register(name) { _ in handler() }
    }

    /// Handler that receives the argument an interaction produced. nil
    /// means the caller used the no-argument form.
    public func register(_ name: String, handler: @escaping (Prop?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        actions[name] = handler
    }

    @discardableResult
    public func invoke(_ action: String, with argument: Prop? = nil) -> Bool {
        lock.lock()
        let handler = actions[action]
        lock.unlock()
        guard let handler else { return false }
        handler(argument)
        return true
    }
}

private struct ActionDispatcherKey: EnvironmentKey {
    static let defaultValue: ActionDispatcher? = nil
}

extension EnvironmentValues {
    /// Where components send named actions. `nil` (no host) leaves a button
    /// inert: the screen still renders, it just does not do anything.
    public var actionDispatcher: ActionDispatcher? {
        get { self[ActionDispatcherKey.self] }
        set { self[ActionDispatcherKey.self] = newValue }
    }
}
