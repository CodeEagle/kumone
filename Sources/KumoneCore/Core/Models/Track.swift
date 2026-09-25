import Foundation

public struct ArtistRef: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
    }
}

public struct AlbumRef: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let picUrl: String?

    public init(id: Int, name: String, picUrl: String?) {
        self.id = id
        self.name = name
        self.picUrl = picUrl
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        picUrl = try? c.decode(String.self, forKey: .picUrl)
    }
}

/// A unified track model that decodes both the "v3" song shape (`ar`/`al`/`dt`)
/// and the legacy shape (`artists`/`album`/`duration`).
public struct Track: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let artists: [ArtistRef]
    public let album: AlbumRef
    public let durationMS: Int
    public let alias: [String]
    public let transNames: [String]
    public let fee: Int
    public let mvID: Int
    public let trackNo: Int
    public let disc: String?
    public let noCopyright: Bool
    /// Cloud-disk song marker (`pc` field present).
    public let isCloud: Bool
    /// Some endpoints (cloudsearch, FM) embed the privilege in the track itself.
    public var embeddedPrivilege: TrackPrivilege?

    public init(
        id: Int, name: String, artists: [ArtistRef], album: AlbumRef,
        durationMS: Int, alias: [String], transNames: [String],
        fee: Int, mvID: Int, trackNo: Int,
        disc: String?, noCopyright: Bool, isCloud: Bool,
        embeddedPrivilege: TrackPrivilege?
    ) {
        self.id = id
        self.name = name
        self.artists = artists
        self.album = album
        self.durationMS = durationMS
        self.alias = alias
        self.transNames = transNames
        self.fee = fee
        self.mvID = mvID
        self.trackNo = trackNo
        self.disc = disc
        self.noCopyright = noCopyright
        self.isCloud = isCloud
        self.embeddedPrivilege = embeddedPrivilege
    }

    public var artistNames: String { artists.map(\.name).joined(separator: " / ") }
    public var duration: TimeInterval { TimeInterval(durationMS) / 1000 }
    public var subtitle: String? { transNames.first ?? alias.first }

    private enum CodingKeys: String, CodingKey {
        case id, name
        case ar, artists
        case al, album
        case dt, duration
        case alia, alias
        case tns, fee, mv, no, cd, noCopyrightRcmd, pc, privilege
    }

}

// MARK: - Codable

extension Track {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        artists = (try? c.decode([ArtistRef].self, forKey: .ar))
            ?? (try? c.decode([ArtistRef].self, forKey: .artists)) ?? []
        album = (try? c.decode(AlbumRef.self, forKey: .al))
            ?? (try? c.decode(AlbumRef.self, forKey: .album))
            ?? AlbumRef(id: 0, name: "", picUrl: nil)
        durationMS = (try? c.decode(Int.self, forKey: .dt))
            ?? (try? c.decode(Int.self, forKey: .duration)) ?? 0
        alias = (try? c.decode([String].self, forKey: .alia))
            ?? (try? c.decode([String].self, forKey: .alias)) ?? []
        transNames = (try? c.decode([String].self, forKey: .tns)) ?? []
        fee = (try? c.decode(Int.self, forKey: .fee)) ?? 0
        mvID = (try? c.decode(Int.self, forKey: .mv)) ?? 0
        trackNo = (try? c.decode(Int.self, forKey: .no)) ?? 0
        disc = try? c.decode(String.self, forKey: .cd)
        noCopyright = c.contains(.noCopyrightRcmd)
            && (try? c.decodeNil(forKey: .noCopyrightRcmd)) == false
        isCloud = c.contains(.pc) && (try? c.decodeNil(forKey: .pc)) == false
        embeddedPrivilege = try? c.decode(TrackPrivilege.self, forKey: .privilege)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(artists, forKey: .ar)
        try c.encode(album, forKey: .al)
        try c.encode(durationMS, forKey: .dt)
        try c.encode(alias, forKey: .alia)
        try c.encode(transNames, forKey: .tns)
        try c.encode(fee, forKey: .fee)
        try c.encode(mvID, forKey: .mv)
        try c.encode(trackNo, forKey: .no)
        try c.encodeIfPresent(disc, forKey: .cd)
    }
}

/// Playability flags per track, returned in parallel `privileges` arrays.
public struct TrackPrivilege: Codable, Hashable, Sendable {
    public let id: Int
    public let fee: Int?
    public let pl: Int?
    public let st: Int?
    public let cs: Bool?
    public let maxbr: Int?
}

public enum TrackPlayability: Hashable {
    case playable
    case vipOnly
    case paidAlbum
    case noCopyright
    case delisted

    public var reason: String? {
        switch self {
        case .playable: return nil
        case .vipOnly: return String(localized: "VIP 专属")
        case .paidAlbum: return String(localized: "付费专辑")
        case .noCopyright: return String(localized: "无版权")
        case .delisted: return String(localized: "已下架")
        }
    }
}

extension Track {
    /// Mirrors YesPlayMusic's `isTrackPlayable` decision chain,
    /// with the VIP check widened to cover 黑胶 SVIP (vipType 110 etc).
    public func playability(privilege: TrackPrivilege?, isLoggedIn: Bool, vipType: Int) -> TrackPlayability {
        let privilege = privilege ?? embeddedPrivilege
        if let pl = privilege?.pl, pl > 0 { return .playable }
        if isLoggedIn, privilege?.cs == true { return .playable }
        let effectiveFee = privilege?.fee ?? fee
        if effectiveFee == 1 {
            return vipType > 0 ? .playable : .vipOnly
        }
        if effectiveFee == 4 { return .paidAlbum }
        if noCopyright { return .noCopyright }
        if let st = privilege?.st, st < 0, isLoggedIn { return .delisted }
        return .playable
    }
}

extension Array where Element == Track {
    @discardableResult
    public mutating func replaceRecommendation(_ rejected: Track, with replacement: Track) -> Bool {
        guard let index = firstIndex(where: { $0.id == rejected.id }),
              replacement.id != rejected.id,
              !contains(where: { $0.id == replacement.id }) else { return false }
        self[index] = replacement
        return true
    }
}
