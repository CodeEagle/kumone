import Foundation

/// Subscription state of an album (NetEase `/album/detail/dynamic` →
/// `AlbumDynamicResponse{isSub, subCount}`).
public struct AlbumDynamic: Codable, Hashable, Sendable {
    public let isSubscribed: Bool
    public let subscriberCount: Int
}

/// An artist page: the profile plus the songs NetEase surfaces as hot
/// (`ArtistResponse{artist, hotSongs}`).
public struct ArtistDetail: Decodable, Hashable, Sendable, Identifiable {
    public let artist: ArtistSummary
    public let hotSongs: [Track]

    public var id: Int { artist.id }
}

/// A page of an artist's albums (`ArtistAlbumsResponse{hotAlbums, more}`).
public struct ArtistAlbums: Decodable, Hashable, Sendable {
    public let albums: [AlbumSummary]
    public let hasMore: Bool
}

/// A chart (toplist) entry, generalized from `ToplistItem`; the NetEase-only
/// track preview is dropped here and fetched on demand instead.
public struct Chart: Codable, Hashable, Sendable, Identifiable {
    public let id: MusicID
    public let name: String
    public let coverURL: URL?
    public let updateFrequency: String?
    public let playCount: Int
}

/// The list of available charts (`ToplistResponse`).
public struct ChartList: Codable, Hashable, Sendable {
    public let charts: [Chart]
    public let total: Int
    public let hasMore: Bool
}

/// A page of high-quality playlists (`HighQualityResponse`).
public struct HighQualityList: Decodable, Hashable, Sendable {
    public let playlists: [PlaylistSummary]
    /// Paging cursor: a millisecond timestamp on NetEase, opaque elsewhere.
    public let lastTime: Int?
    public let hasMore: Bool
}

/// One page of the user's cloud disk (`CloudResponse`).
public struct CloudStoragePage: Decodable, Hashable, Sendable {
    public let items: [CloudSongItem]
    public let hasMore: Bool
    public let usedBytes: Int64
    public let maxBytes: Int64
}

/// Lightweight playlist identity (name + artwork) without the full detail
/// fetch; NetEase's private `PlaylistBrief` shell stays in the provider.
public struct PlaylistBriefInfo: Codable, Hashable, Sendable {
    public let id: MusicID
    public let name: String
    public let coverURL: URL?
}

/// QR / SMS login probe result (`QRCheckResponse`).
public struct LoginCheck: Codable, Hashable, Sendable {
    public let code: Int
    public let message: String?
    public let nickname: String?
    public let avatar: URL?
}

/// A recent-play entry (`PlayRecordItem`).
public struct PlayRecord: Codable, Hashable, Sendable {
    public let playCount: Int
    public let score: Int
    public let song: Track
}

/// Per-category hit counts accompanying a search
/// (`SearchResult`'s `songCount`/`albumCount`/…).
public struct SearchCounts: Codable, Hashable, Sendable {
    public let songs: Int
    public let albums: Int
    public let artists: Int
    public let playlists: Int

    public init(songs: Int, albums: Int, artists: Int, playlists: Int) {
        self.songs = songs
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
    }
}

/// Provider-agnostic search results (`NeteaseAPI.SearchResult`, mapped up).
/// Note: this top-level type does not collide with the nested
/// `NeteaseAPI.SearchResult`; Phase 1 mapping qualifies the API-side name.
public struct SearchResult: Decodable, Hashable, Sendable {
    public let songs: [Track]
    public let albums: [AlbumSummary]
    public let artists: [ArtistSummary]
    public let playlists: [PlaylistSummary]
    public let counts: SearchCounts

    public init(songs: [Track], albums: [AlbumSummary], artists: [ArtistSummary], playlists: [PlaylistSummary], counts: SearchCounts) {
        self.songs = songs
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
        self.counts = counts
    }

    /// Empty result — every section empty, every count zero.
    public init() {
        self.init(songs: [], albums: [], artists: [], playlists: [], counts: SearchCounts(songs: 0, albums: 0, artists: 0, playlists: 0))
    }
}

/// Search-suggest (autocomplete) results (`SearchSuggestResponse.Body`).
public struct SearchSuggestion: Decodable, Hashable, Sendable {
    public let songs: [Track]
    public let artists: [ArtistSummary]
    public let albums: [AlbumSummary]
    public let playlists: [PlaylistSummary]
}
