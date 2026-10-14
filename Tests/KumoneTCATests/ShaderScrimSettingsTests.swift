import ComposableArchitecture
import Foundation
import Testing
@testable import KumoneTCA

@Suite("Shader scrim transparency persistence")
@MainActor
struct ShaderScrimSettingsTests {
    @Test func explicitZeroAndHundredPercentSurviveReload() {
        nonisolated(unsafe) var saved: Double?
        func makeStore() -> StoreOf<SettingsFeature> {
            Store(initialState: SettingsFeature.State()) { SettingsFeature() } withDependencies: {
                $0.persistence.stringForKey = { key in
                    key == SettingsFeature.Keys.shaderScrimTransparency ? saved.map(String.init(describing:)) : nil
                }
                $0.persistence.doubleForKey = { key in
                    key == SettingsFeature.Keys.shaderScrimTransparency ? saved ?? 0 : 0
                }
                $0.persistence.boolForKey = { _ in false }
                $0.persistence.setDouble = { value, key in
                    if key == SettingsFeature.Keys.shaderScrimTransparency { saved = value }
                }
            }
        }
        let store = makeStore()
        store.send(.onAppear)
        #expect(store.shaderScrimTransparency == 1)
        for value in [0.0, 0.43, 1.0] {
            store.send(.setShaderScrimTransparency(value))
            #expect(store.shaderScrimTransparency == value)
            #expect(saved == value)
            let restored = makeStore()
            restored.send(.onAppear)
            #expect(restored.shaderScrimTransparency == value)
        }
    }

    @Test func invalidValuesCannotProduceInvalidOpacity() {
        let store = Store(initialState: SettingsFeature.State()) { SettingsFeature() } withDependencies: {
            $0.persistence.setDouble = { _, _ in }
        }
        store.send(.setShaderScrimTransparency(-1))
        #expect(store.shaderScrimTransparency == 0)
        store.send(.setShaderScrimTransparency(2))
        #expect(store.shaderScrimTransparency == 1)
        store.send(.setShaderScrimTransparency(.nan))
        #expect(store.shaderScrimTransparency == 1)
    }
}
