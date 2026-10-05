import KumoneUI
import SwiftUI
import XCTest

/// Collection-layer tests: the two prop cases a binding can hand back,
/// the `item.` scope a ForEach opens, and the component itself.
@MainActor
final class CollectionTests: XCTestCase {

    // MARK: collection props

    func testTruthOfCollections() {
        // A list/mapping shows its node when non-empty — a queue screen
        // with an empty queue hides itself, which is what a ForEach
        // wrapped in visible: ${player.upcomingTracks} wants.
        XCTAssertTrue(Visibility.truth(of: .list([.string("a")])))
        XCTAssertFalse(Visibility.truth(of: .list([])))
        XCTAssertTrue(Visibility.truth(of: .mapping(["title": .string("T")])))
        XCTAssertFalse(Visibility.truth(of: .mapping([:])))
    }

    // MARK: the item scope

    func testItemPathIsTheElement() {
        let scope = ScopedResolver(base: nil, item: .string("a line"))
        XCTAssertEqual(scope.value("item"), .string("a line"))
    }

    func testItemFieldsAreReadThroughTheMapping() {
        let scope = ScopedResolver(
            base: nil,
            item: .mapping([
                "title": .string("Solar Flare"),
                "duration": .number(247),
            ]))
        XCTAssertEqual(scope.value("item.title"), .string("Solar Flare"))
        XCTAssertEqual(scope.value("item.duration"), .number(247))
        // A field the item does not have: nil, like an unknown app path.
        XCTAssertNil(scope.value("item.artist"))
    }

    func testItemScopeFallsThroughToBase() {
        let base = PathBindingResolver(["player.title": { .string("Now") }])
        let scope = ScopedResolver(base: base, item: .mapping(["title": .string("Next")]))
        XCTAssertEqual(scope.value("player.title"), .string("Now"))
        // item.artist missing in the item, and `item.` never falls
        // through to base — the scope owns the whole prefix.
        XCTAssertNil(scope.value("item.artist"))
    }

    func testNonMappingItemHasNoFields() {
        let scope = ScopedResolver(base: nil, item: .list([.string("x")]))
        XCTAssertNil(scope.value("item.anything"))
    }

    // MARK: the component

    func testForEachRegisteredAsComponent() {
        BuiltinComponents.register()
        XCTAssertNotNil(ComponentRegistry.resolve("ForEach"))
    }

    func testForEachBuildsWithListItems() {
        // The builder path runs with a resolved list and a template child:
        // it must return a view, not reason about the elements.
        BuiltinComponents.register()
        guard let builder = ComponentRegistry.resolve("ForEach") else {
            return XCTFail("ForEach not registered")
        }
        let node = Node(type: "ForEach", children: [
            Node(type: "Text", props: ["text": .binding("item")]),
        ])
        let resolver = PathBindingResolver([
            "player.upcomingTracks": {
                .list([.mapping(["title": .string("A")]), .mapping(["title": .string("B")])])
            },
        ])
        let context = ComponentContext(
            style: ["items": .binding("player.upcomingTracks")],
            children: node.children,
            resolver: resolver) { _ in AnyView(EmptyView()) }
        XCTAssertNotNil(builder(node, context))
    }

    func testForEachWithoutItemsBuildsEmpty() {
        // No items prop, no resolver: nothing to repeat, but still a view.
        BuiltinComponents.register()
        guard let builder = ComponentRegistry.resolve("ForEach") else {
            return XCTFail("ForEach not registered")
        }
        let node = Node(type: "ForEach", children: [
            Node(type: "Text", props: ["text": .binding("item")]),
        ])
        let context = ComponentContext(
            style: [:], children: node.children, resolver: nil) { _ in AnyView(EmptyView()) }
        XCTAssertNotNil(builder(node, context))
    }

    // MARK: the screen shape

    func testForEachNodeParsesWithItemBindings() throws {
        // A queue row as written in a screen: items bound to a list path,
        // the template's inner bindings pointing at item fields.
        let yaml = """
        root:
          type: ForEach
          items: ${player.upcomingTracks}
          spacing: 10
          children:
            - type: Text
              text: ${item.title}
        """
        let node = try ConfigParser.screen(from: yaml)
        XCTAssertEqual(node.type, "ForEach")
        XCTAssertEqual(node.props["items"], .binding("player.upcomingTracks"))
        XCTAssertEqual(node.children.first?.props["text"], .binding("item.title"))
    }
}
