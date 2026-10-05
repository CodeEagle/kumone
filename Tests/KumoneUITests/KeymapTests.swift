import KumoneUI
import XCTest

/// Keymap tests: shortcut parsing, the leniency rule for modifiers, and
/// document parsing's rule that bad rows report instead of fail.
@MainActor
final class KeymapTests: XCTestCase {

    // MARK: shortcut parsing

    func testParsesBareKey() {
        let binding = KeyBinding.parse("space")
        XCTAssertEqual(binding, KeyBinding(modifiers: [], key: "space"))
    }

    func testParsesModifiersAndKey() {
        XCTAssertEqual(KeyBinding.parse("cmd+shift+p"), KeyBinding(modifiers: [.command, .shift], key: "p"))
        XCTAssertEqual(KeyBinding.parse("ctrl+l"), KeyBinding(modifiers: [.control], key: "l"))
    }

    func testAliasesAndCaseDontMatter() {
        // cmd/command, opt/option/alt, ctrl/ctl/control — all one modifier.
        XCTAssertEqual(KeyBinding.parse("command+p")?.modifiers, [.command])
        XCTAssertEqual(KeyBinding.parse("alt+p")?.modifiers, [.option])
        XCTAssertEqual(KeyBinding.parse("ctl+p")?.modifiers, [.control])
        // A shortcut is written however the author writes it.
        XCTAssertEqual(KeyBinding.parse("CMD+L"), KeyBinding(modifiers: [.command], key: "l"))
    }

    func testMalformedShortcutsAreNil() {
        XCTAssertNil(KeyBinding.parse(""))
        XCTAssertNil(KeyBinding.parse("cmd+"))       // dangling plus
        XCTAssertNil(KeyBinding.parse("+p"))         // no first modifier
        XCTAssertNil(KeyBinding.parse("nonsense+p")) // unknown modifier
        XCTAssertNil(KeyBinding.parse("++"))         // nothing at all
    }

    // MARK: matching

    func testMatchesWithExtraModifiersHeld() {
        // cmd+l still fires when shift is held too: matching is a subset,
        // not an exact set — same leniency as window-manager keybinds.
        let binding = KeyBinding(modifiers: [.command], key: "l")
        XCTAssertTrue(binding.matches(modifiers: [.command, .shift], key: "L"))
        XCTAssertTrue(binding.matches(modifiers: [.command], key: "l"))
        XCTAssertFalse(binding.matches(modifiers: [.shift], key: "l"))
        XCTAssertFalse(binding.matches(modifiers: [.command], key: "k"))
    }

    // MARK: document parsing

    func testParsesDocument() {
        var issues: [String] = []
        let keymap = Keymap.parse("""
        space: player.togglePlayPause
        "cmd+l": player.toggleLyricsPanel
        cmd+shift+q: player.toggleQueuePanel
        rightarrow: player.next
        """, issues: &issues)
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(keymap.action(for: [], key: "space"), "player.togglePlayPause")
        XCTAssertEqual(keymap.action(for: [.command], key: "l"), "player.toggleLyricsPanel")
        // Unquoted modifiers parse too — YAML allows a plain `cmd+l` key.
        XCTAssertEqual(keymap.action(for: [.command, .shift], key: "q"), "player.toggleQueuePanel")
        XCTAssertEqual(keymap.action(for: [], key: "rightarrow"), "player.next")
    }

    func testBadRowsAreReportedAndSkipped() {
        var issues: [String] = []
        let keymap = Keymap.parse("""
        space: player.togglePlayPause
        bogus+p: player.next
        uptospace: 12
        """, issues: &issues)
        XCTAssertEqual(issues.count, 2)
        // The good row survives; the two broken ones bind nothing.
        XCTAssertEqual(keymap.bindings.count, 1)
        XCTAssertEqual(keymap.action(for: [], key: "space"), "player.togglePlayPause")
        XCTAssertNil(keymap.action(for: [], key: "p"))
    }

    func testEmptyDocumentIsEmptyKeymap() {
        var issues: [String] = []
        XCTAssertEqual(Keymap.parse("", issues: &issues), .empty)
        // Nil action for a press no binding covers, never a crash:
        XCTAssertEqual(Keymap.empty.action(for: [.command], key: "x"), nil)
    }

    // MARK: through the ConfigStore

    func testStoreLoadsBundledKeymap() throws {
        let bundled = try makeDirectory(files: [
            "keymap.yaml": "space: player.togglePlayPause\nescape: app.dismissNowPlaying\n",
        ])
        let store = ConfigStore(bundled: bundled, user: nil)
        XCTAssertEqual(store.keymap.action(for: [], key: "space"), "player.togglePlayPause")
        XCTAssertEqual(store.keymap.action(for: [], key: "escape"), "app.dismissNowPlaying")
        // The keymap file itself must not show up as a screen.
        XCTAssertNil(store.screens["keymap"])
    }

    func testUserKeymapOverridesBundled() throws {
        let bundled = try makeDirectory(files: ["keymap.yaml": "space: player.togglePlayPause\n"])
        let user = try makeDirectory(files: ["keymap.yaml": "space: player.next\n"])
        let store = ConfigStore(bundled: bundled, user: user)
        XCTAssertEqual(store.keymap.action(for: [], key: "space"), "player.next")
    }

    // MARK: helpers

    private func makeDirectory(files: [String: String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, body) in files {
            try body.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return url
    }
}
