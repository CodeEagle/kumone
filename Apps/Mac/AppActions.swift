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
        // Parameterless verbs — the button-shaped ones.
        registry.register("player.togglePlayPause") { store.send(.player(.togglePlayPause)) }
        registry.register("player.next") { store.send(.player(.next)) }
        registry.register("player.previous") { store.send(.player(.previous)) }
        registry.register("player.toggleShuffle") { store.send(.player(.toggleShuffle)) }
        registry.register("player.cycleRepeatMode") { store.send(.player(.cycleRepeatMode)) }
        registry.register("player.toggleLyricsPanel") { store.send(.player(.togglePanel(.lyrics))) }
        registry.register("player.toggleQueuePanel") { store.send(.player(.togglePanel(.queue))) }

        registry.register("app.presentNowPlaying") { store.send(.presentNowPlaying) }
        registry.register("app.dismissNowPlaying") { store.send(.dismissNowPlaying) }

        // Volume steps: media keys give relative intent (volumeup), the
        // store only knows absolute levels, so the step lands here.
        registry.register("player.volumeUp") { [store] in
            store.send(.player(.setVolume(min(1, store.player.volume + 0.05))))
        }
        registry.register("player.volumeDown") { [store] in
            store.send(.player(.setVolume(max(0, store.player.volume - 0.05))))
        }

        // Verbs with an argument: the value is whatever the interaction
        // produced (a slider position), not anything the screen could
        // hardcode. Unreadable arguments are ignored rather than fatal.
        registry.register("player.seek") { argument in
            guard let seconds = argument?.numberValue else { return }
            store.send(.player(.seek(seconds)))
        }
        registry.register("player.setVolume") { argument in
            guard case .number(let level) = argument else { return }
            store.send(.player(.setVolume(Float(level))))
        }
        return registry
    }
}
