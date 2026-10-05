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
            // Playback state. isPaused exists so a play/pause pair of buttons
            // can be expressed with only truthy bindings — no expression
            // language needed in the screens.
            "player.isPlaying": { .flag(player().isPlaying) },
            "player.isPaused": { .flag(player().hasCurrentTrack && !player().isPlaying) },
            "player.hasTrack": { .flag(player().hasCurrentTrack) },
            "player.progress": { .number(player().progress) },
            "player.duration": { .number(player().duration) },
            "player.artworkURL": { .string(player().currentTrack?.album.picUrl ?? "") },
            "player.volume": { .number(Double(player().volume)) },
            "player.shuffleEnabled": { .flag(player().shuffleEnabled) },
            "player.repeatMode": { .string(player().repeatMode.rawValue) },
            "player.isBuffering": { .flag(player().isBuffering) },
            // What is coming: a list of mappings, so a row template binds
            // `${item.title}` / `${item.artist}` / `${item.artworkURL}`.
            // Capped at 50 — a queue screen shows the near future, not the
            // whole library.
            "player.upcomingTracks": {
                .list(player().upcomingTracks.prefix(50).map { track in
                    .mapping([
                        "title": .string(track.name),
                        "artist": .string(track.artists.first?.name ?? ""),
                        "artworkURL": .string(track.album.picUrl ?? ""),
                        "duration": .number(Double(track.durationMS) / 1000.0),
                    ])
                })
            },

            // The ambient lyric the desktop sheet shows, one line: the
            // simplest way for a screen to carry the current words.
            "lyrics.currentLine": {
                let lines = player().lyrics?.lines ?? []
                let index = player().lyricsCursorIndex ?? 0
                guard index >= 0, index < lines.count else { return .string("") }
                return .string(lines[index].text)
            },
            "lyrics.lineCount": { .number(Double(player().lyrics?.lines.count ?? 0)) },
            // The whole lyric, one string per line: for a ForEach that lays
            // them out as a column of Texts.
            "lyrics.lines": {
                .list(player().lyrics?.lines.map { .string($0.text) } ?? [])
            },

            // Window-level state
            "app.nowPlayingOpen": { .flag(store.isNowPlayingPresented) },
            "app.shaderName": { .string(store.shaderID ?? "") },
        ])
    }
}
