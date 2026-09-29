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

    static let nowPlayingPrevious = "now-playing-previous"
    static let nowPlayingPreviousTarget = "now-playing-previous-target"

    static let nowPlayingNext = "now-playing-next"
    static let nowPlayingNextTarget = "now-playing-next-target"

    static let nowPlayingLike = "now-playing-like"
    static let nowPlayingLikeTarget = "now-playing-like-target"

    static let nowPlayingShuffle = "now-playing-shuffle"
    static let nowPlayingShuffleTarget = "now-playing-shuffle-target"

    static let nowPlayingRepeat = "now-playing-repeat"
    static let nowPlayingRepeatTarget = "now-playing-repeat-target"

    static let nowPlayingFMTrash = "now-playing-fm-trash"
    static let nowPlayingFMTrashTarget = "now-playing-fm-trash-target"

    /// Song title and artist: shared pure-text elements between the mini bar
    /// and the Now Playing page. The stand-in carries the destination end's
    /// string and styling (see `HeroContent.text`), so a present flight grows
    /// the small bar text into the page headline and the return flight shrinks
    /// it back.
    static let nowPlayingTitle = "now-playing-title"
    static let nowPlayingTitleTarget = "now-playing-title-target"

    static let nowPlayingVIP = "now-playing-vip"
    static let nowPlayingVIPTarget = "now-playing-vip-target"

    static let nowPlayingArtist = "now-playing-artist"
    static let nowPlayingArtistTarget = "now-playing-artist-target"

    static let nowPlayingPairs: [(source: String, target: String)] = [
        (nowPlayingArtwork, nowPlayingArtworkTarget),
        (nowPlayingPlayPause, nowPlayingPlayPauseTarget),
        (nowPlayingPrevious, nowPlayingPreviousTarget),
        (nowPlayingNext, nowPlayingNextTarget),
        (nowPlayingLike, nowPlayingLikeTarget),
        (nowPlayingShuffle, nowPlayingShuffleTarget),
        (nowPlayingRepeat, nowPlayingRepeatTarget),
        (nowPlayingFMTrash, nowPlayingFMTrashTarget),
        (nowPlayingTitle, nowPlayingTitleTarget),
        (nowPlayingVIP, nowPlayingVIPTarget),
        (nowPlayingArtist, nowPlayingArtistTarget),
    ]

    /// Card cover -> detail-page header. One id per item so the source card and
    /// the destination header pair up; the id is the item's own id.
    static func album(_ id: Int) -> String { "hero-album-\(id)" }
    static func playlist(_ id: Int) -> String { "hero-playlist-\(id)" }
    static func artist(_ id: Int) -> String { "hero-artist-\(id)" }
}
