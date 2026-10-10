import XCTest
import ComposableArchitecture
import KumoneCore
@testable import KumoneTCA

final class ShaderBackdropSelectionTests: XCTestCase {
    @MainActor
    func testBackgroundEnableRoutesRestoredShaderToWindowState() async throws {
        ShaderDiscovery.shared.reload()
        let shader = try XCTUnwrap(ShaderDiscovery.shared.availableDescriptors.first)
        let settings = ShaderSettings.shared
        let oldName = settings.pickedShaderName
        let oldDisabled = settings.shaderPickingDisabled
        defer { settings.pickedShaderName = oldName; settings.shaderPickingDisabled = oldDisabled }
        settings.pickedShaderName = shader.name
        settings.shaderPickingDisabled = true
        var initial = AppFeature.State()
        initial.settings.showMainWindowAmbientBackground = false
        let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
            $0.persistence.setBool = { _, _ in }
        }
        store.exhaustivity = .off
        await store.send(.settings(.setShowMainWindowAmbientBackground(true)))
        await store.receive(.setShader(shader.id))
        XCTAssertEqual(store.state.shaderID, shader.id)
        XCTAssertTrue(store.state.settings.showMainWindowAmbientBackground)
        XCTAssertFalse(settings.shaderPickingDisabled)
    }

    @MainActor
    func testEnablingRestoresLastPickAfterNone() throws {
        let domain = "ShaderBackdropSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = ShaderSettings(defaults: defaults)
        let first = ShaderDescriptor(id: "first", name: "First", origin: .bundled)
        let last = ShaderDescriptor(id: "last", name: "Last", origin: .bundled)
        settings.pickedShaderName = last.name
        settings.shaderPickingDisabled = true
        XCTAssertEqual(settings.enableBackdropSelection(from: [first, last], currentID: nil), last.id)
        XCTAssertFalse(settings.shaderPickingDisabled)
        XCTAssertFalse(ShaderSettings(defaults: defaults).shaderPickingDisabled)
    }

    @MainActor
    func testEnablingDoesNotOverwriteFreshPickerSelection() throws {
        let domain = "ShaderBackdropSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = ShaderSettings(defaults: defaults)
        let first = ShaderDescriptor(id: "first", name: "First", origin: .bundled)
        let selected = ShaderDescriptor(id: "selected", name: "Selected", origin: .bundled)
        settings.pickedShaderName = first.name
        XCTAssertEqual(settings.enableBackdropSelection(from: [first, selected], currentID: selected.id), selected.id)
    }

    @MainActor
    func testStartupStillRespectsExplicitNone() throws {
        let domain = "ShaderBackdropSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        ShaderSettings(defaults: defaults).shaderPickingDisabled = true
        XCTAssertTrue(ShaderSettings(defaults: defaults).shaderPickingDisabled)
    }
}
