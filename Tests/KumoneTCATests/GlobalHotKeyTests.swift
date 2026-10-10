#if os(macOS)
import AppKit
import Carbon
import XCTest
@testable import KumoneTCA

@MainActor
final class GlobalHotKeyTests: XCTestCase {
    func testNativeCarbonDispatchIsSingleAndConflictsPreserveOldRegistration() throws {
        let name = "kumone.global-hotkey-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let registry = GlobalHotKeyManager()
        defer { registry.shutdown() }
        var received: [ShortcutAction] = []
        registry.start(manager: ShortcutManager(defaults: defaults)) { received.append($0) }
        XCTAssertTrue(registry.activeRegistrations.isEmpty, "no keys are reserved on launch")
        let shortcut = UserShortcut(key: "\u{F70E}", modifiers: [.command, .control, .option])
        if let error = registry.register(.togglePlayPause, shortcut: shortcut) {
            throw XCTSkip("test key unavailable in this session: \(error)")
        }
        let original = try XCTUnwrap(registry.activeRegistrations[.togglePlayPause])
        XCTAssertNotNil(registry.register(.nextTrack, shortcut: shortcut))
        XCTAssertNotNil(registry.register(.togglePlayPause, shortcut: .init(key: "p", modifiers: [])))
        XCTAssertEqual(registry.activeRegistrations[.togglePlayPause]?.id, original.id)

        var event: EventRef?
        XCTAssertEqual(CreateEvent(nil, UInt32(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                   GetCurrentEventTime(), 0, &event), noErr)
        let nativeEvent = try XCTUnwrap(event)
        defer { ReleaseEvent(nativeEvent) }
        var id = original
        XCTAssertEqual(SetEventParameter(nativeEvent, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID),
                                         MemoryLayout<EventHotKeyID>.size, &id), noErr)
        XCTAssertEqual(SendEventToEventTarget(nativeEvent, GetApplicationEventTarget()), noErr)
        XCTAssertEqual(received, [.togglePlayPause], "actual native event fires exactly once")

        registry.unregister(.togglePlayPause)
        XCTAssertNil(registry.register(.nextTrack, shortcut: shortcut), "clearing releases the OS registration")
        registry.shutdown()
        XCTAssertTrue(registry.activeRegistrations.isEmpty)
    }
}
#endif
