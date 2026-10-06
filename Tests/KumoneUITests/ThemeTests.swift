import KumoneUI
import XCTest

/// Theme-library tests: how themes are discovered, switched, persisted,
/// and what happens when a name is wrong or a file vanishes.
@MainActor
final class ThemeTests: XCTestCase {

    // A ThemeStorage that records calls, for the persist-and-restore paths.
    private final class RecordingStorage: ThemeStorage {
        var stored: String?
        var writes: [String] = []
        func themeName() -> String? { stored }
        func setThemeName(_ name: String) { writes.append(name); stored = name }
    }

    private func directory(_ files: [String: String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, body) in files {
            try body.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return url
    }

    private let defaultTheme = """
    tokens:
      accent: "#E8567A"
    """
    private let auroraTheme = """
    tokens:
      accent: "#5FD0E8"
    """

    func testDiscoversTheDefaultAndNamedThemes() throws {
        let dir = try directory([
            "theme.yaml": defaultTheme,
            "theme-aurora.yaml": auroraTheme,
        ])
        let store = ConfigStore(bundled: dir, user: nil)
        XCTAssertEqual(store.themes.keys.sorted(), ["aurora", "default"])
        XCTAssertEqual(store.currentTheme, "default")
        // The nameless file is the default, the named one keeps its stem.
        XCTAssertEqual(store.themes["default"]?.tokens["accent"], .string("#E8567A"))
        XCTAssertEqual(store.themes["aurora"]?.tokens["accent"], .string("#5FD0E8"))
    }

    func testThemeFilesAreNotScreens() throws {
        let dir = try directory([
            "theme.yaml": defaultTheme,
            "theme-aurora.yaml": auroraTheme,
            "preview.yaml": "root:\n  type: Text\n  text: hi\n",
        ])
        let store = ConfigStore(bundled: dir, user: nil)
        XCTAssertEqual(Array(store.screens.keys), ["preview"])
    }

    func testSwitchReRendersWithTheNewSheet() throws {
        let dir = try directory([
            "theme.yaml": defaultTheme,
            "theme-aurora.yaml": auroraTheme,
            "preview.yaml": "root:\n  type: Text\n  text: hi\n",
        ])
        let storage = RecordingStorage()
        let store = ConfigStore(bundled: dir, user: nil, themeStorage: storage)
        XCTAssertEqual(store.screens["preview"]?.stylesheet.tokens["accent"], .string("#E8567A"))

        store.setCurrentTheme("aurora")
        XCTAssertEqual(store.currentTheme, "aurora")
        XCTAssertEqual(store.screens["preview"]?.stylesheet.tokens["accent"], .string("#5FD0E8"))
        // The choice is handed to storage exactly once.
        XCTAssertEqual(storage.writes, ["aurora"])
        // The root tree itself is untouched — only the sheet swapped.
        XCTAssertEqual(store.screens["preview"]?.root.props["text"], .string("hi"))
    }

    func testUnknownThemeNameIsIgnored() throws {
        let dir = try directory(["theme.yaml": defaultTheme])
        let store = ConfigStore(bundled: dir, user: nil)
        store.setCurrentTheme("does-not-exist")
        XCTAssertEqual(store.currentTheme, "default")
    }

    func testStoredChoiceRestoresAtLaunch() throws {
        let dir = try directory([
            "theme.yaml": defaultTheme,
            "theme-aurora.yaml": auroraTheme,
        ])
        let storage = RecordingStorage()
        storage.stored = "aurora"
        let store = ConfigStore(bundled: dir, user: nil, themeStorage: storage)
        XCTAssertEqual(store.currentTheme, "aurora")
        // Nothing written at startup — restore is a read, not a save.
        XCTAssertEqual(storage.writes, [])
    }

    func testStoredButMissingThemeFallsBackToDefault() throws {
        let dir = try directory(["theme.yaml": defaultTheme])
        let storage = RecordingStorage()
        storage.stored = "deleted-somewhere"
        let store = ConfigStore(bundled: dir, user: nil, themeStorage: storage)
        XCTAssertEqual(store.currentTheme, "default")
    }

    func testUserThemeFileOverridesBundledSameName() throws {
        let bundled = try directory(["theme.yaml": defaultTheme])
        let user = try directory(["theme.yaml": auroraTheme])
        let store = ConfigStore(bundled: bundled, user: user)
        // One theme, the user's — later candidates overwrite.
        XCTAssertEqual(store.themes.count, 1)
        XCTAssertEqual(store.themes["default"]?.tokens["accent"], .string("#5FD0E8"))
    }
}
