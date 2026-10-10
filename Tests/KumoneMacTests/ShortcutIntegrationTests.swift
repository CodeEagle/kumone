#if os(macOS)
import AppKit
import KumoneTCA
import KumoneUI
@testable import KumoneMac
import XCTest

@MainActor
final class ShortcutIntegrationTests: XCTestCase {
    private final class Recorder: NSView, ShortcutRecordingResponder {
        var events: [NSEvent] = []
        func recordShortcut(event: NSEvent) { events.append(event) }
    }
    func testCommandChordIsDeliveredOnceToRecorderBeforeMenus() {
        let recorder = Recorder()
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: 0, context: nil, characters: "l", charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37)!
        AppKeymapMonitor.routeRecordingEvent(event, to: recorder)
        XCTAssertEqual(recorder.events.count, 1)
        XCTAssertEqual(recorder.events.first?.modifierFlags, .command)
    }
    func testMenuUsesNewBindingAndClearsStaleKeyEquivalent() {
        let name = "kumone.menu-shortcut-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = ShortcutManager(defaults: defaults)
        let item = NSMenuItem(title: "下一首", action: nil, keyEquivalent: "\u{F703}")
        XCTAssertTrue(manager.setShortcut(.init(key: "n", modifiers: [.control, .option]), for: .nextTrack, isGlobal: false))
        MainMenu.applyShortcut(to: item, action: .nextTrack, manager: manager)
        XCTAssertEqual(item.keyEquivalent, "n")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.control, .option])
        XCTAssertTrue(manager.setShortcut(.init(key: "", modifiers: []), for: .nextTrack, isGlobal: false))
        MainMenu.applyShortcut(to: item, action: .nextTrack, manager: manager)
        XCTAssertEqual(item.keyEquivalent, "")
    }
    func testExactConfiguredChordWinsOverSubset() {
        let map = Keymap(bindings: [
            KeyBinding(modifiers: [.command], key: "l"): "player.toggleLyricsPanel",
            KeyBinding(modifiers: [.command, .shift], key: "l"): "account.toggleLike",
        ])
        XCTAssertEqual(AppKeymapMonitor.configuredAction(in: map, modifiers: [.command, .shift], key: "l"), "account.toggleLike")
        XCTAssertEqual(AppKeymapMonitor.configuredAction(in: map, modifiers: [.command], key: "l"), "player.toggleLyricsPanel")
    }
}
#endif
