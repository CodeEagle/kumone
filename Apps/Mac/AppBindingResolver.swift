import ComposableArchitecture
import KumoneCore
import KumoneTCA
import KumoneUI

/// The app's answer to `${path}` bindings: a flat registry of named paths
/// into the TCA store.
///
/// Why a table and not a generic key-path interpreter: the set of paths a
/// screen may read is the *public* surface of the app's state, and a table
/// makes that surface explicit and versionable. Registering a new binding
/// is one line; an unregistered path renders as empty, not a crash, so a
/// screen referencing something newer than the app just loses that prop.
///
/// Every getter reads the store at call time, inside the component's body
/// observation frame — so a change to the underlying state rebuilds the
/// view that bound it, exactly like an @State read.
@MainActor
final class AppBindingResolver: PathBindingResolver {
    init(store: StoreOf<AppFeature>) {
        let player = { store.player }
        super.init([
            // Track identity
            "player.title": { .string(player().currentTrack?.name ?? "") },
            "player.artist": { .string(player().currentTrack?.artists.first?.name ?? "") },
            "player.album": { .string(player().currentTrack?.album.name ?? "") },
            // Playback state
            "player.isPlaying": { .flag(player().isPlaying) },
            "player.hasTrack": { .flag(player().hasCurrentTrack) },
            "player.progress": { .number(player().progress) },
            "player.duration": { .number(player().duration) },

            // The ambient lyric the desktop sheet shows, one line: the
            // simplest way for a screen to carry the current words.
            "lyrics.currentLine": {
                let lines = player().lyrics?.lines ?? []
                let index = player().lyricsCursorIndex ?? 0
                guard index >= 0, index < lines.count else { return .string("") }
                return .string(lines[index].text)
            },
            "lyrics.lineCount": { .number(Double(player().lyrics?.lines.count ?? 0)) },

            // Window-level state
            "app.nowPlayingOpen": { .flag(store.isNowPlayingPresented) },
            "app.shaderName": { .string(store.shaderID ?? "") },
        ])
    }
}
