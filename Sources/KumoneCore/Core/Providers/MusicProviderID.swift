import Foundation

/// A source-agnostic identifier for any music entity (song, playlist, album, artist).
/// It round-trips through `RawRepresentable` so identifiers stay stable across
/// launches and can be persisted as plain strings.
public enum MusicID: RawRepresentable, Hashable, Sendable, Codable {
    /// The provider-native identifier plus the provider that issued it.
    case source(id: String, provider: MusicProviderID)

    public var rawValue: String {
        switch self {
        case let .source(id, provider):
            return "\(provider.rawValue)://\(id)"
        }
    }

    /// 该实体在所属 provider 处的原生标识（用于调 provider 原生 API）。
    public var sourceID: String {
        switch self {
        case let .source(id, _): return id
        }
    }

    public init?(rawValue: String) {
        // Split on the first separator only; the identifier itself is free to
        // contain "://" (it never does today, but the parse stays unambiguous).
        guard let separator = rawValue.range(of: "://") else { return nil }
        let providerPart = rawValue[..<separator.lowerBound]
        let idPart = rawValue[separator.upperBound...]
        guard let provider = MusicProviderID(rawValue: String(providerPart)) else { return nil }
        self = .source(id: String(idPart), provider: provider)
    }
}

/// The music sources the app can talk to.
public enum MusicProviderID: String, Hashable, Sendable, Codable {
    case netease
    case qq
    case kuwo
}

/// Coarse search categories shared by every provider.
public enum SearchCategory: Hashable, Sendable {
    case songs
    case albums
    case artists
    case playlists

    /// Matches `NeteaseAPI.SearchType`'s raw values (1/10/100/1000).
    public var neteaseRawValue: Int {
        switch self {
        case .songs: return 1
        case .albums: return 10
        case .artists: return 100
        case .playlists: return 1000
        }
    }
}

/// Playback quality tiers, provider-agnostic.
public enum SongQuality: Hashable, Sendable {
    case standard
    case high
    case lossless
    case immersive

    /// Aligns with the `level` strings NetEase accepts and echoes back in
    /// `SongURLData.level`; `sky` is NetEase's immersive (spatial audio) tier.
    public var neteaseLevel: String {
        switch self {
        case .standard: return "standard"
        case .high: return "exhigh"
        case .lossless: return "lossless"
        case .immersive: return "sky"
        }
    }
}

/// Core-layer storage for the currently active provider.
///
/// Phase 0 keeps this as plain static storage with no upper-layer dependencies
/// (no ComposableArchitecture import — that would be a reverse dependency).
/// The Phase 1 TCA `DependencyKey` wrapper will read and write this property,
/// keeping a single source of truth for the active provider.
public enum MusicProviderStorage {
    public static var activeProviderID: MusicProviderID = .netease
}

extension MusicID {
    /// Convenience initializer for the numeric identifiers the existing NetEase
    /// call sites use (`MusicID(track.id)`), resolved against the active
    /// provider so legacy call sites need no other change.
    public init(_ raw: Int) {
        self = .source(id: String(raw), provider: MusicProviderStorage.activeProviderID)
    }
}
