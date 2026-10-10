#if os(macOS)
import AppKit
import Carbon
import XCTest
@testable import KumoneTCA

@MainActor
final class ShortcutManagerTests: XCTestCase {
    private func withManager(_ test: (ShortcutManager, UserDefaults) -> Void) {
        let name = "kumone.shortcut-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        test(ShortcutManager(defaults: defaults), defaults)
    }
    func testGlobalDefaultsAreAllDisabledAndPhysicalFKeysAreCorrect() {
        withManager { manager, _ in
            XCTAssertTrue(ShortcutAction.allCases.allSatisfy { manager.shortcut(for: $0, isGlobal: true).key.isEmpty })
        }
        XCTAssertEqual(GlobalHotKeyManager.resolveKeyCode("\u{F705}"), UInt32(kVK_F2))
        XCTAssertEqual(GlobalHotKeyManager.resolveKeyCode("\u{F70A}"), UInt32(kVK_F7))
        XCTAssertEqual(GlobalHotKeyManager.resolveKeyCode("\u{F703}"), UInt32(kVK_RightArrow))
    }
    func testLocalBindingPersistsAndClearingDisablesOldConfigAlias() {
        withManager { manager, defaults in
            let new = UserShortcut(key: "p", modifiers: [.command, .option], keyCode: 35)
            XCTAssertTrue(manager.setShortcut(new, for: .togglePlayPause, isGlobal: false))
            XCTAssertEqual(ShortcutManager(defaults: defaults).shortcut(for: .togglePlayPause, isGlobal: false), new)
            XCTAssertTrue(manager.hasOverride(for: "player.togglePlayPause"))
            XCTAssertTrue(manager.setShortcut(.init(key: "", modifiers: []), for: .togglePlayPause, isGlobal: false))
            XCTAssertEqual(ShortcutManager(defaults: defaults).shortcut(for: .togglePlayPause, isGlobal: false).key, "")
            manager.resetToDefaults()
            XCTAssertFalse(manager.hasOverride(for: "player.togglePlayPause"))
            XCTAssertEqual(manager.shortcut(for: .togglePlayPause, isGlobal: false), ShortcutAction.togglePlayPause.defaultShortcut)
        }
    }
    func testConflictsAndReservedWindowKeysKeepExistingBinding() {
        withManager { manager, defaults in
            let old = manager.shortcut(for: .nextTrack, isGlobal: false)
            XCTAssertFalse(manager.setShortcut(.init(key: "w", modifiers: .command), for: .nextTrack, isGlobal: false))
            XCTAssertFalse(manager.setShortcut(ShortcutAction.previousTrack.defaultShortcut, for: .nextTrack, isGlobal: false))
            XCTAssertEqual(manager.shortcut(for: .nextTrack, isGlobal: false), old)
            XCTAssertNil(defaults.data(forKey: "settings.shortcut.nextTrack"))
        }
    }
    func testInvalidGlobalRegistrationDoesNotChangeSavedBinding() {
        withManager { manager, defaults in
            XCTAssertFalse(manager.setShortcut(.init(key: "p", modifiers: []), for: .togglePlayPause, isGlobal: true))
            XCTAssertEqual(manager.shortcut(for: .togglePlayPause, isGlobal: true).key, "")
            XCTAssertNil(defaults.data(forKey: "settings.globalShortcut.togglePlayPause"))
            XCTAssertNotNil(manager.errorMessage)
        }
    }
    func testBareKeysDoNotStealTypingAndRecorderIsNotIntercepted() {
        withManager { manager, _ in
            XCTAssertTrue(manager.setShortcut(.init(key: "p", modifiers: []), for: .togglePlayPause, isGlobal: false))
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "p", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35)!
            XCTAssertEqual(manager.overriddenAction(matching: event, editingText: false), .togglePlayPause)
            XCTAssertNil(manager.overriddenAction(matching: event, editingText: true))
            manager.isRecording = true
            XCTAssertNil(manager.overriddenAction(matching: event, editingText: false))
        }
    }
}
#endif
