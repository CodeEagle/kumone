import KumoneUI
import SwiftUI
import XCTest

/// Composite-component tests: LyricView proves a component may be a view
/// written in Swift rather than config composed of children, and that the
/// same never-crash rules apply (missing bindings, empty lists, bad
/// cursors all degrade rather than fail).
@MainActor
final class LyricViewTests: XCTestCase {

    func testRegisteredAsComponent() {
        BuiltinComponents.register()
        XCTAssertNotNil(ComponentRegistry.resolve("LyricView"))
    }

    func testBuildsWithLinesAndCursor() {
        // The registry holds a view, not labels: from the builder's side,
        // lines and a cursor is just props resolved through a resolver.
        BuiltinComponents.register()
        guard let builder = ComponentRegistry.resolve("LyricView") else {
            return XCTFail("LyricView not registered")
        }
        let node = Node(type: "LyricView", props: [
            "lines": .binding("lyrics.lines"),
            "currentIndex": .binding("lyrics.currentIndex"),
            "fontSize": .number(16),
            "activeColor": .string("#F2F2F5"),
            "inactiveColor": .string("#5C5C66"),
        ])
        let resolver = PathBindingResolver([
            "lyrics.lines": { .list([.string("first"), .string("second")]) },
            "lyrics.currentIndex": { .number(1) },
        ])
        let context = ComponentContext(
            style: node.props, children: [], resolver: resolver) { _ in AnyView(EmptyView()) }
        XCTAssertNotNil(builder(node, context))
    }

    func testBuildsWithoutAnyBindings() {
        // No resolver, no props: an empty sheet with a placeholder. Still
        // a view, still no crash.
        BuiltinComponents.register()
        guard let builder = ComponentRegistry.resolve("LyricView") else {
            return XCTFail("LyricView not registered")
        }
        let node = Node(type: "LyricView")
        let context = ComponentContext(
            style: [:], children: [], resolver: nil) { _ in AnyView(EmptyView()) }
        XCTAssertNotNil(builder(node, context))
    }

    func testCursorOutOfRangeBuilds() {
        // A cursor past the end (between songs) and a non-number cursor
        // both land at -1 — nothing highlighted.
        BuiltinComponents.register()
        guard let builder = ComponentRegistry.resolve("LyricView") else {
            return XCTFail("LyricView not registered")
        }
        for cursor in ["99", "not-a-number"] {
            let node = Node(type: "LyricView", props: [
                "lines": .list([.string("a"), .string("b")]),
                "currentIndex": .string(cursor),
            ])
            let context = ComponentContext(
                style: node.props, children: [], resolver: nil) { _ in AnyView(EmptyView()) }
            XCTAssertNotNil(builder(node, context), "cursor '\(cursor)'")
        }
    }

    func testNodeParsesWithBindings() throws {
        // The lyrics screen's shape: lines to a list binding, cursor to an
        // index binding, colours as literals.
        let yaml = """
        root:
          type: LyricView
          lines: ${lyrics.lines}
          currentIndex: ${lyrics.currentIndex}
          fontSize: 16
          activeColor: "#F2F2F5"
          alignment: center
        """
        let node = try ConfigParser.screen(from: yaml)
        XCTAssertEqual(node.type, "LyricView")
        XCTAssertEqual(node.props["lines"], .binding("lyrics.lines"))
        XCTAssertEqual(node.props["currentIndex"], .binding("lyrics.currentIndex"))
        XCTAssertEqual(node.props["activeColor"], .string("#F2F2F5"))
    }
}
