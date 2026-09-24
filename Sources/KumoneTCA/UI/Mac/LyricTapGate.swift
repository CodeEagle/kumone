import Foundation
#if os(macOS)
import AppKit
#endif

/// Decides whether a lyric-line click counts.
///
/// The click that brings an inactive app to the front must not also jump the
/// song. `NSApplication.shared.keyWindow` is a poor proxy for that: AppKit can
/// have made the window key by the time the button's action runs, so the guard
/// passes and the seek fires on the very click that was only meant to focus the
/// window. Measuring time since the app last became active is reliable, and the
/// grace period covers the hand-off between "this click activates" and "this
/// click means something".
@MainActor
final class LyricTapGate {
    static let shared = LyricTapGate()

    /// How long the app must be active before a lyric click is honoured.
    static let graceInterval: TimeInterval = 1

    private var lastActivatedAt: Date = .distantPast

    private init() {
        #if os(macOS)
        // The gate is a singleton that outlives the app, so the observers are
        // registered once and never removed.
        let center = NotificationCenter.default
        center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.markActivated()
        }
        center.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.markDeactivated()
        }
        #endif
    }

    func markActivated() {
        lastActivatedAt = Date()
    }

    func markDeactivated() {
        // Far enough ahead that no elapsed time can clear the gate; the next
        // `markActivated` starts the grace period over.
        lastActivatedAt = .distantFuture
    }

    /// True when the app has been active long enough that the click is a
    /// deliberate one. On iOS an app that can receive a touch is already
    /// active, so there is nothing to gate.
    var allowsTap: Bool {
        #if os(macOS)
        return Date().timeIntervalSince(lastActivatedAt) >= Self.graceInterval
        #else
        return true
        #endif
    }
}
