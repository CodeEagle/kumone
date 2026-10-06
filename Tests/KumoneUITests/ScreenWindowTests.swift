import KumoneUI
import XCTest

/// Screen-document tests: the `window:` block — what it parses, what it
/// ignores, and that a screen without one behaves exactly as before.
@MainActor
final class ScreenWindowTests: XCTestCase {

    func testParsesEveryWindowField() throws {
        let document = try ConfigParser.screenDocument(from: """
        window:
          width: 480
          height: 640
          minWidth: 360
          minHeight: 480
          title: Mini
        root:
          type: Text
          text: hi
        """)
        XCTAssertEqual(document.window.width, 480)
        XCTAssertEqual(document.window.height, 640)
        XCTAssertEqual(document.window.minWidth, 360)
        XCTAssertEqual(document.window.minHeight, 480)
        XCTAssertEqual(document.window.title, "Mini")
        XCTAssertEqual(document.root.type, "Text")
    }

    func testMissingBlockKeepsDefaults() throws {
        let document = try ConfigParser.screenDocument(from: """
        root:
          type: Text
          text: hi
        """)
        // An absent window block is an all-nil window: the app's usual
        // geometry and the default title.
        XCTAssertNil(document.window.width)
        XCTAssertNil(document.window.height)
        XCTAssertNil(document.window.minWidth)
        XCTAssertNil(document.window.minHeight)
        XCTAssertNil(document.window.title)
    }

    func testBadValuesAreIgnoredNotFatal() throws {
        // Non-numeric, zero, and negative sizes all drop out as nil; the
        // screen still parses — a typo does not take the window down.
        let document = try ConfigParser.screenDocument(from: """
        window:
          width: wide
          height: 0
          minWidth: -10
          minHeight: 200
          title: 42
        root:
          type: Text
          text: hi
        """)
        XCTAssertNil(document.window.width)
        XCTAssertNil(document.window.height)
        XCTAssertNil(document.window.minWidth)
        XCTAssertEqual(document.window.minHeight, 200)
        XCTAssertNil(document.window.title)
    }

    func testLegacyScreenAccessorStillReturnsTheTree() throws {
        // screen(from:) predates window blocks and must keep working for
        // anything that only cares about the tree.
        let node = try ConfigParser.screen(from: """
        window:
          width: 100
        root:
          type: Text
          text: hi
        """)
        XCTAssertEqual(node.type, "Text")
        XCTAssertEqual(node.props["text"], .string("hi"))
    }

    func testStoreCarriesTheWindowWithTheScreen() throws {
        let bundled = try makeDirectory(files: [
            "mini.yaml": """
            window:
              width: 400
              height: 620
              title: Mini
            root:
              type: Text
              text: hi
            """,
        ])
        let store = ConfigStore(bundled: bundled, user: nil)
        XCTAssertEqual(store.screens["mini"]?.window.width, 400)
        XCTAssertEqual(store.screens["mini"]?.window.height, 620)
        XCTAssertEqual(store.screens["mini"]?.window.title, "Mini")
        // A screen with no block: all defaults.
        let plain = try makeDirectory(files: [
            "plain.yaml": "root:\n  type: Text\n  text: hi\n",
        ])
        let other = ConfigStore(bundled: plain, user: nil)
        XCTAssertNil(other.screens["plain"]?.window.width)
    }

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
