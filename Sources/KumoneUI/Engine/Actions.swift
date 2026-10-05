import Foundation
import SwiftUI

/// Dispatches a named action, e.g. `player.next` written as a prop.
///
/// Mirrors the binding resolver: the engine never knows what an action does
/// — the app registers handlers, and a screen names them. Actions are the
/// *only* way config reaches behaviour, so screens stay declarative:
/// structure says what, actions say what happens, and neither says how.
public protocol ActionDispatcher: AnyObject {
    /// Runs the handler for a name. Returns whether one was registered —
    /// false means the screen references an action the app does not know,
    /// which the caller surfaces instead of silently doing nothing.
    @discardableResult
    func invoke(_ action: String) -> Bool
}

/// The registry the app fills at startup. Handlers are plain closures, so
/// an app's actions are the public counterpart of its binding path table.
public final class ActionRegistry: ActionDispatcher {
    private let lock = NSLock()
    private nonisolated(unsafe) var actions: [String: () -> Void] = [:]

    public init() {}

    public func register(_ name: String, handler: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        actions[name] = handler
    }

    @discardableResult
    public func invoke(_ action: String) -> Bool {
        lock.lock()
        let handler = actions[action]
        lock.unlock()
        guard let handler else { return false }
        handler()
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
