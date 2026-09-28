import Foundation

/// Stable identifiers for hero transitions. One id is shared by the source
/// anchor and the target anchor of a single transition, which is how the
/// flight pairs them up.
enum HeroID {
    /// PlayerBar artwork -> NowPlaying artwork.
    static let nowPlayingArtwork = "now-playing-artwork"

    /// Card cover -> detail-page header. One id per item so the source card and
    /// the destination header pair up; the id is the item's own id.
    static func album(_ id: Int) -> String { "hero-album-\(id)" }
    static func playlist(_ id: Int) -> String { "hero-playlist-\(id)" }
    static func artist(_ id: Int) -> String { "hero-artist-\(id)" }
}
