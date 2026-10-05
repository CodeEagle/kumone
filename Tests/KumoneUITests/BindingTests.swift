import KumoneUI
import SwiftUI
import XCTest

/// Binding-layer tests: `${path}` parsing, resolver lookup, and the
/// context's rule that unknown paths never throw — they render empty.
@MainActor
final class BindingTests: XCTestCase {

    func testParsesDollarBraceAsBinding() throws {
        let yaml = """
        root:
          type: Text
          text: ${player.title}
        """
        let node = try ConfigParser.screen(from: yaml)
        XCTAssertEqual(node.type, "Text")
        XCTAssertEqual(node.props["text"], .binding("player.title"))
    }

    func testQuotedBindingStillParses() throws {
        let yaml = """
        root:
          type: Text
          text: " ${player.title} "
        """
        let node = try ConfigParser.screen(from: yaml)
        XCTAssertEqual(node.props["text"], .binding("player.title"))
    }

    func testPlainStringStaysLiteral() throws {
        let yaml = """
        root:
          type: Text
          text: player.title
        """
        let node = try ConfigParser.screen(from: yaml)
        XCTAssertEqual(node.props["text"], .string("player.title"))
    }

    func testMalformedBindingFallsBackToString() throws {
        let yaml = """
        root:
          type: Text
          text: ${}
        """
        let node = try ConfigParser.screen(from: yaml)
        XCTAssertEqual(node.props["text"], .string("${}"))
    }

    func testResolverLooksUpRegisteredPath() {
        let resolver = PathBindingResolver([
            "player.title": { .string("Solar Flare") },
            "player.isPlaying": { .flag(true) },
            "player.progress": { .number(12.5) },
        ])
        XCTAssertEqual(resolver.value("player.title"), .string("Solar Flare"))
        XCTAssertEqual(resolver.value("player.isPlaying"), .flag(true))
        XCTAssertEqual(resolver.value("player.progress"), .number(12.5))
    }

    func testUnknownPathResolvesToNil() {
        let resolver = PathBindingResolver([:])
        XCTAssertNil(resolver.value("does.not.exist"))
    }

    func testContextResolvesBindingThroughResolver() {
        let context = ComponentContext(
            style: ["text": .binding("player.title")],
            children: [],
            resolver: PathBindingResolver(["player.title": { .string("Resolved") }])) { _ in AnyView(EmptyView()) }
        XCTAssertEqual(context.resolve(context.style["text"]!), .string("Resolved"))
    }

    func testContextPassesLiteralsThrough() {
        let context = ComponentContext(
            style: ["text": .string("literal"), "size": .number(13)],
            children: [],
            resolver: nil) { _ in AnyView(EmptyView()) }
        XCTAssertEqual(context.resolve(.string("literal")), .string("literal"))
        XCTAssertEqual(context.resolve(.number(13)), .number(13))
        XCTAssertNil(context.resolve(.binding("player.title")))  // no resolver: nil
    }

    func testVisibleBoolStaysLiteral() throws {
        let yaml = """
        root:
          type: Container
          visible: false
        """
        let node = try ConfigParser.screen(from: yaml)
        XCTAssertEqual(node.visible, .always(false))
    }
}
