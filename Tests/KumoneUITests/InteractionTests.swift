import KumoneUI
import SwiftUI
import XCTest

/// M2 interaction-layer tests: `visible:` as a `${path}` binding, the truth
/// rules for a resolved prop, and the action registry a screen's buttons
/// send names to. Together with BindingTests, the rule under test is that
/// a screen never computes — it names state to show by, and verbs to fire.
@MainActor
final class InteractionTests: XCTestCase {

    // MARK: visible: as a binding

    func testParsesVisibleBinding() throws {
        let yaml = """
        root:
          type: HStack
          visible: ${player.hasTrack}
        """
        let node = try ConfigParser.screen(from: yaml)
        XCTAssertEqual(node.visible, .binding("player.hasTrack"))
    }

    func testQuotedVisibleBindingParses() throws {
        let yaml = """
        root:
          type: HStack
          visible: " ${player.isPlaying} "
        """
        let node = try ConfigParser.screen(from: yaml)
        XCTAssertEqual(node.visible, .binding("player.isPlaying"))
    }

    func testVisibleDefaultsToAlwaysShown() throws {
        let yaml = """
        root:
          type: Text
          text: anything
        """
        let node = try ConfigParser.screen(from: yaml)
        XCTAssertEqual(node.visible, .always(true))
    }

    func testMalformedVisibleStaysLiteral() throws {
        // `${}` has an empty path: not a binding, so it falls back to the
        // plain-string reading, which is not a bool either — the node
        // defaults to visible rather than vanishing on a typo.
        let yaml = """
        root:
          type: Text
          visible: ${}
        """
        let node = try ConfigParser.screen(from: yaml)
        XCTAssertEqual(node.visible, .always(true))
    }

    // MARK: truth of a resolved prop

    func testTruthOfFlags() {
        XCTAssertTrue(Visibility.truth(of: .flag(true)))
        XCTAssertFalse(Visibility.truth(of: .flag(false)))
    }

    func testTruthOfStringsAndNumbers() {
        XCTAssertTrue(Visibility.truth(of: .string("Solar Flare")))
        XCTAssertFalse(Visibility.truth(of: .string("")))
        XCTAssertTrue(Visibility.truth(of: .number(12.5)))
        XCTAssertFalse(Visibility.truth(of: .number(0)))
    }

    func testUnknownPathHides() {
        // The safe direction: nil (no resolver, or a path it does not know)
        // is false, so a typo'd binding hides the node instead of crashing.
        XCTAssertFalse(Visibility.truth(of: nil))
        XCTAssertFalse(Visibility.truth(of: .binding("player.hasTrack")))
    }

    // MARK: action registry

    func testRegistryInvokesRegisteredHandler() {
        let registry = ActionRegistry()
        var fired: [String] = []
        registry.register("player.next") { fired.append("next") }
        XCTAssertTrue(registry.invoke("player.next"))
        XCTAssertEqual(fired, ["next"])
    }

    func testUnknownActionReturnsFalse() {
        let registry = ActionRegistry()
        registry.register("player.next") {}
        // A typo'd name reports false rather than throwing: the screen keeps
        // rendering, the caller logs, nothing happens visibly.
        XCTAssertFalse(registry.invoke("player.nex"))
    }

    func testRegisterOverwritesHandler() {
        let registry = ActionRegistry()
        var count = 0
        registry.register("player.next") { count += 1 }
        registry.register("player.next") { count += 100 }
        XCTAssertTrue(registry.invoke("player.next"))
        XCTAssertEqual(count, 100)
    }

    // MARK: the button primitive

    func testButtonRegisteredAsComponent() {
        // `register()` is what app startup calls; re-registering replaces,
        // so the test can call it itself without depending on a host app.
        BuiltinComponents.register()
        XCTAssertNotNil(ComponentRegistry.resolve("Button"))
    }

    func testButtonWithoutNameOrDispatcherIsInert() {
        // A button with no action prop, and no dispatcher in the environment
        // (no host): it renders its label but stays inert, never a crash.
        BuiltinComponents.register()
        let node = Node(type: "Button", children: [
            Node(type: "Text", props: ["text": .string("▶")]),
        ])
        guard let builder = ComponentRegistry.resolve("Button") else {
            return XCTFail("Button not registered")
        }
        let context = ComponentContext(
            style: [:], children: node.children, resolver: nil) { _ in AnyView(EmptyView()) }
        XCTAssertNotNil(builder(node, context))
    }

    // MARK: actions with an argument

    func testParameterizedInvokeCarriesArgument() {
        let registry = ActionRegistry()
        var seen: [Double] = []
        registry.register("player.seek") { argument in
            seen.append(argument?.numberValue ?? -1)
        }
        XCTAssertTrue(registry.invoke("player.seek", with: .number(41.5)))
        XCTAssertEqual(seen, [41.5])
    }

    func testParameterlessInvokeDeliversNil() {
        let registry = ActionRegistry()
        var arguments: [Prop?] = [.number(1)]
        registry.register("player.next") { argument in arguments.append(argument) }
        // The no-argument form (the one buttons use) reaches the handler
        // as nil, so a verb registered for sliders still works for taps.
        XCTAssertTrue(registry.invoke("player.next"))
        XCTAssertEqual(arguments, [.number(1), nil])
    }

    func testArgumentFallsThroughUnknownAction() {
        let registry = ActionRegistry()
        XCTAssertFalse(registry.invoke("player.nex", with: .number(1)))
    }

    // MARK: the new components

    func testProgressSliderRegisteredAsComponent() {
        BuiltinComponents.register()
        XCTAssertNotNil(ComponentRegistry.resolve("ProgressSlider"))
        XCTAssertNotNil(ComponentRegistry.resolve("Artwork"))
    }

    func testProgressSliderInertWithoutDurationOrAction() {
        // No track (duration 0), no action name, no host: the builder still
        // returns a view — disabled inside, never a crash.
        BuiltinComponents.register()
        guard let builder = ComponentRegistry.resolve("ProgressSlider") else {
            return XCTFail("ProgressSlider not registered")
        }
        let node = Node(type: "ProgressSlider", props: [
            "value": .number(0), "duration": .number(0)],
        )
        let context = ComponentContext(
            style: [:], children: [], resolver: nil) { _ in AnyView(EmptyView()) }
        XCTAssertNotNil(builder(node, context))
    }

    func testArtworkBuildsWithAndWithoutURL() {
        BuiltinComponents.register()
        guard let builder = ComponentRegistry.resolve("Artwork") else {
            return XCTFail("Artwork not registered")
        }
        for url in ["https://example/x.jpg", ""] {
            let node = Node(type: "Artwork", props: ["url": .string(url), "size": .number(48)])
            let context = ComponentContext(
                style: [:], children: [], resolver: nil) { _ in AnyView(EmptyView()) }
            XCTAssertNotNil(builder(node, context))
        }
    }

    func testVisibleBindingForSliderProps() throws {
        // A slider node points its value at a path the app registered — the
        // mini-player screen's shape, end to end.
        let yaml = """
        root:
          type: ProgressSlider
          value: ${player.progress}
          duration: ${player.duration}
          action: player.seek
        """
        let node = try ConfigParser.screen(from: yaml)
        XCTAssertEqual(node.props["value"], .binding("player.progress"))
        XCTAssertEqual(node.props["duration"], .binding("player.duration"))
        XCTAssertEqual(node.props["action"], .string("player.seek"))
    }

    // MARK: buttons with an argument

    func testButtonArgumentParsesAsLiteral() throws {
        // The argument a verb receives (`app.presentScreen` takes a screen
        // name) is a plain prop, so it parses like any other.
        let yaml = """
        root:
          type: Button
          action: app.presentScreen
          argument: mini
        """
        let node = try ConfigParser.screen(from: yaml)
        XCTAssertEqual(node.props["action"], .string("app.presentScreen"))
        XCTAssertEqual(node.props["argument"], .string("mini"))
    }

    func testButtonArgumentMayBeABinding() throws {
        let yaml = """
        root:
          type: Button
          action: player.jumpTo
          argument: ${player.title}
        """
        let node = try ConfigParser.screen(from: yaml)
        XCTAssertEqual(node.props["argument"], .binding("player.title"))
    }

    func testStringArgumentReachesTheHandler() {
        let registry = ActionRegistry()
        var received: [String] = []
        registry.register("app.presentScreen") { argument in
            if case .string(let name) = argument { received.append(name) }
        }
        XCTAssertTrue(registry.invoke("app.presentScreen", with: .string("mini")))
        XCTAssertEqual(received, ["mini"])
    }

    func testButtonArgumentUnsetIsNil() throws {
        // A button with no argument still parses; nil travels to the verb.
        let yaml = """
        root:
          type: Button
          action: player.next
        """
        let node = try ConfigParser.screen(from: yaml)
        XCTAssertNil(node.props["argument"])
    }
}
