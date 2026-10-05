import ComposableArchitecture
import KumoneCore
import KumoneTCA
import KumoneUI

/// The app's answer to named actions: the counterpart of
/// `AppBindingResolver`'s path table — bindings read state, this mutates it.
///
/// Registering a handler is the act of publishing a verb from the app; a
/// screen names it (`action: player.next`) and nothing more. Composition,
/// not inheritance: the engine's `ActionRegistry` is filled here and handed
/// to the preview window, the same way the binding resolver is. Unknown
/// names are reported back as `false`, so a typo'd action does nothing
/// visibly rather than throwing.
@MainActor
enum AppActions {
    static func dispatcher(store: StoreOf<AppFeature>) -> ActionRegistry {
        let registry = ActionRegistry()
        registry.register("player.togglePlayPause") { store.send(.player(.togglePlayPause)) }
        registry.register("player.next") { store.send(.player(.next)) }
        registry.register("player.previous") { store.send(.player(.previous)) }
        registry.register("player.toggleLyricsPanel") { store.send(.player(.togglePanel(.lyrics))) }
        registry.register("player.toggleQueuePanel") { store.send(.player(.togglePanel(.queue))) }

        registry.register("app.presentNowPlaying") { store.send(.presentNowPlaying) }
        registry.register("app.dismissNowPlaying") { store.send(.dismissNowPlaying) }
        return registry
    }
}
