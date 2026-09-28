import Foundation

/// Stable identifiers for hero transitions. One id is shared by the source
/// anchor and the target anchor of a single transition, which is how the
/// flight pairs them up.
enum HeroID {
    /// PlayerBar artwork -> NowPlaying artwork. Two ids: the mini artwork and
    /// the page artwork each report to the frame store under their own key, so
    /// a dismiss can read both ends even after the page is gone.
    static let nowPlayingArtwork = "now-playing-artwork"
    static let nowPlayingArtworkTarget = "now-playing-artwork-target"

    static let nowPlayingPlayPause = "now-playing-play-pause"
    static let nowPlayingPlayPauseTarget = "now-playing-play-pause-target"

    static let nowPlayingPairs: [(source: String, target: String)] = [
        (nowPlayingArtwork, nowPlayingArtworkTarget),
        (nowPlayingPlayPause, nowPlayingPlayPauseTarget),
    ]

    /// Card cover -> detail-page header. One id per item so the source card and
    /// the destination header pair up; the id is the item's own id.
    static func album(_ id: Int) -> String { "hero-album-\(id)" }
    static func playlist(_ id: Int) -> String { "hero-playlist-\(id)" }
    static func artist(_ id: Int) -> String { "hero-artist-\(id)" }
}
