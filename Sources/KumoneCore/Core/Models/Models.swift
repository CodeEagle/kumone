import Foundation

// MARK: - User

public struct UserProfile: Decodable, Hashable {
    public let userId: Int
    public let nickname: String
    public let avatarUrl: String?
    public let backgroundUrl: String?
    public let signature: String?
    public let vipType: Int

    private enum CodingKeys: String, CodingKey {
        case userId, nickname, avatarUrl, backgroundUrl, signature, vipType
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(Int.self, forKey: .userId)
        nickname = (try? c.decode(String.self, forKey: .nickname)) ?? ""
        avatarUrl = try? c.decode(String.self, forKey: .avatarUrl)
        backgroundUrl = try? c.decode(String.self, forKey: .backgroundUrl)
        signature = try? c.decode(String.self, forKey: .signature)
        vipType = (try? c.decode(Int.self, forKey: .vipType)) ?? 0
    }
}

// MARK: - Playlist

public struct PlaylistCreator: Decodable, Hashable, Sendable {
    public let userId: Int
    public let nickname: String
    public let avatarUrl: String?

    private enum CodingKeys: String, CodingKey {
        case userId, nickname, avatarUrl
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = (try? c.decode(Int.self, forKey: .userId)) ?? 0
        nickname = (try? c.decode(String.self, forKey: .nickname)) ?? ""
        avatarUrl = try? c.decode(String.self, forKey: .avatarUrl)
    }
}

/// A playlist as it appears in grids and sidebars. Tolerates the several cover
/// field names and numeric types NetEase uses across endpoints.
public struct PlaylistSummary: Decodable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let coverURL: String?
    public let playCount: Int
    public let trackCount: Int
    public let copywriter: String?
    public let creator: PlaylistCreator?
    public let specialType: Int
    public let privacy: Int
    public let subscribed: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, picUrl, coverImgUrl, playCount, playcount, trackCount
        case copywriter, creator, specialType, privacy, subscribed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        coverURL = (try? c.decode(String.self, forKey: .picUrl))
            ?? (try? c.decode(String.self, forKey: .coverImgUrl))
        let count = (try? c.decode(Double.self, forKey: .playCount))
            ?? (try? c.decode(Double.self, forKey: .playcount)) ?? 0
        playCount = Int(count)
        trackCount = (try? c.decode(Int.self, forKey: .trackCount)) ?? 0
        copywriter = try? c.decode(String.self, forKey: .copywriter)
        creator = try? c.decode(PlaylistCreator.self, forKey: .creator)
        specialType = (try? c.decode(Int.self, forKey: .specialType)) ?? 0
        privacy = (try? c.decode(Int.self, forKey: .privacy)) ?? 0
        subscribed = (try? c.decode(Bool.self, forKey: .subscribed)) ?? false
    }

    /// The auto-created "我喜欢的音乐" playlist.
    public var isLikedSongsList: Bool { specialType == 5 }
}

public struct TrackIDRef: Codable, Hashable {
    public let id: Int
}

public struct PlaylistDetail: Decodable, Hashable {
    public let id: Int
    public let name: String
    public let coverImgUrl: String?
    public let creator: PlaylistCreator?
    public let description: String?
    public let trackCount: Int
    public let playCount: Int
    public let subscribedCount: Int
    public var subscribed: Bool
    public let trackIds: [TrackIDRef]
    public let tracks: [Track]
    public let specialType: Int
    public let updateTime: Int

    public let privileges: [TrackPrivilege]?

    private enum CodingKeys: String, CodingKey {
        case privileges
        case id, name, coverImgUrl, creator, description, trackCount, playCount
        case subscribedCount, subscribed, trackIds, tracks, specialType, updateTime
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        privileges = try? c.decode([TrackPrivilege].self, forKey: .privileges)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        coverImgUrl = try? c.decode(String.self, forKey: .coverImgUrl)
        creator = try? c.decode(PlaylistCreator.self, forKey: .creator)
        description = try? c.decode(String.self, forKey: .description)
        trackCount = (try? c.decode(Int.self, forKey: .trackCount)) ?? 0
        playCount = Int((try? c.decode(Double.self, forKey: .playCount)) ?? 0)
        subscribedCount = (try? c.decode(Int.self, forKey: .subscribedCount)) ?? 0
        subscribed = (try? c.decode(Bool.self, forKey: .subscribed)) ?? false
        trackIds = (try? c.decode([TrackIDRef].self, forKey: .trackIds)) ?? []
        tracks = (try? c.decode([Track].self, forKey: .tracks)) ?? []
        specialType = (try? c.decode(Int.self, forKey: .specialType)) ?? 0
        updateTime = (try? c.decode(Int.self, forKey: .updateTime)) ?? 0
    }

    /// Preserves detail metadata while attaching data from the response envelope.
    init(detail: PlaylistDetail, privileges: [TrackPrivilege]?) {
        self.id = detail.id
        self.name = detail.name
        self.coverImgUrl = detail.coverImgUrl
        self.creator = detail.creator
        self.description = detail.description
        self.trackCount = detail.trackCount
        self.playCount = detail.playCount
        self.subscribedCount = detail.subscribedCount
        self.subscribed = detail.subscribed
        self.trackIds = detail.trackIds
        self.tracks = detail.tracks
        self.specialType = detail.specialType
        self.updateTime = detail.updateTime
        self.privileges = privileges
    }
}

// MARK: - Album / Artist

public struct AlbumSummary: Decodable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let picUrl: String?
    public let artistName: String
    public let publishTime: Int
    public let size: Int
    public let subType: String?
    public let alias: [String]

    private enum CodingKeys: String, CodingKey {
        case id, name, picUrl, cover, artist, artists, publishTime, size, subType, alia, alias
    }

    private struct ArtistName: Codable {
        let name: String?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        picUrl = (try? c.decode(String.self, forKey: .picUrl))
            ?? (try? c.decode(String.self, forKey: .cover))
        if let artist = try? c.decode(ArtistName.self, forKey: .artist), let n = artist.name {
            artistName = n
        } else if let list = try? c.decode([ArtistName].self, forKey: .artists) {
            artistName = list.compactMap(\.name).joined(separator: " / ")
        } else {
            artistName = ""
        }
        publishTime = (try? c.decode(Int.self, forKey: .publishTime)) ?? 0
        size = (try? c.decode(Int.self, forKey: .size)) ?? 0
        subType = try? c.decode(String.self, forKey: .subType)
        alias = (try? c.decode([String].self, forKey: .alia))
            ?? (try? c.decode([String].self, forKey: .alias)) ?? []
    }

    public var publishYear: String {
        guard publishTime > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(publishTime) / 1000)
        return String(Calendar.current.component(.year, from: date))
    }
}

public struct AlbumDetailResponse: Decodable {
    public let album: AlbumDetail
    public let songs: [Track]

    public init(album: AlbumDetail, songs: [Track]) {
        self.album = album
        self.songs = songs
    }
}

public struct AlbumDetail: Decodable, Hashable {
    public let id: Int
    public let name: String
    public let picUrl: String?
    public let artist: ArtistSummary?
    public let publishTime: Int
    public let description: String?
    public let company: String?
    public let size: Int
    public let subType: String?

    public let songs: [Track]

    private enum CodingKeys: String, CodingKey {
        case songs
        case id, name, picUrl, artist, publishTime, description, company, size, subType
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        songs = (try? c.decode([Track].self, forKey: .songs)) ?? []
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        picUrl = try? c.decode(String.self, forKey: .picUrl)
        artist = try? c.decode(ArtistSummary.self, forKey: .artist)
        publishTime = (try? c.decode(Int.self, forKey: .publishTime)) ?? 0
        description = try? c.decode(String.self, forKey: .description)
        company = try? c.decode(String.self, forKey: .company)
        size = (try? c.decode(Int.self, forKey: .size)) ?? 0
        subType = try? c.decode(String.self, forKey: .subType)
    }

    /// Preserves detail metadata while attaching data from the response envelope.
    init(detail: AlbumDetail, songs: [Track]) {
        self.id = detail.id
        self.name = detail.name
        self.picUrl = detail.picUrl
        self.artist = detail.artist
        self.publishTime = detail.publishTime
        self.description = detail.description
        self.company = detail.company
        self.size = detail.size
        self.subType = detail.subType
        self.songs = songs
    }
}

public struct ArtistSummary: Decodable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let picUrl: String?
    public let albumSize: Int
    public let musicSize: Int
    public let briefDesc: String?
    public let alias: [String]
    public let followed: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, picUrl, img1v1Url, cover, avatar, albumSize, musicSize, briefDesc, alias, followed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        picUrl = (try? c.decode(String.self, forKey: .picUrl))
            ?? (try? c.decode(String.self, forKey: .cover))
            ?? (try? c.decode(String.self, forKey: .avatar))
            ?? (try? c.decode(String.self, forKey: .img1v1Url))
        albumSize = (try? c.decode(Int.self, forKey: .albumSize)) ?? 0
        musicSize = (try? c.decode(Int.self, forKey: .musicSize)) ?? 0
        briefDesc = try? c.decode(String.self, forKey: .briefDesc)
        alias = (try? c.decode([String].self, forKey: .alias)) ?? []
        followed = (try? c.decode(Bool.self, forKey: .followed)) ?? false
    }
}

// MARK: - Toplist

public struct ToplistItem: Decodable, Hashable, Identifiable {
    public let id: Int
    public let name: String
    public let coverImgUrl: String?
    public let updateFrequency: String?
    public let tracks: [ToplistTrackPreview]
    public let playCount: Int

    private enum CodingKeys: String, CodingKey {
        case id, name, coverImgUrl, updateFrequency, tracks, playCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        coverImgUrl = try? c.decode(String.self, forKey: .coverImgUrl)
        updateFrequency = try? c.decode(String.self, forKey: .updateFrequency)
        tracks = (try? c.decode([ToplistTrackPreview].self, forKey: .tracks)) ?? []
        playCount = Int((try? c.decode(Double.self, forKey: .playCount)) ?? 0)
    }
}

public struct ToplistTrackPreview: Codable, Hashable {
    public let first: String
    public let second: String
}

// MARK: - Lyrics

public struct LyricResponse {
    public struct LyricBody: Decodable {
        public let lyric: String?

        public init(lyric: String?) {
            self.lyric = lyric
        }
    }

    public let lrc: LyricBody?
    public let tlyric: LyricBody?
    public let romalrc: LyricBody?
    /// Verbatim (word-by-word) lyrics for karaoke highlighting; only present
    /// on the `/song/lyric/v1` endpoint and only for songs that have them.
    public let yrc: LyricBody?
    public let ytlrc: LyricBody?
    public let yromalrc: LyricBody?
    public let lyricUser: LyricContributor?
    public let transUser: LyricContributor?
    public let nolyric: Bool?
    public let uncollected: Bool?

    public init(
        lrc: LyricBody?, tlyric: LyricBody?, romalrc: LyricBody?,
        yrc: LyricBody?, ytlrc: LyricBody?, yromalrc: LyricBody?,
        lyricUser: LyricContributor?, transUser: LyricContributor?,
        nolyric: Bool?, uncollected: Bool?
    ) {
        self.lrc = lrc
        self.tlyric = tlyric
        self.romalrc = romalrc
        self.yrc = yrc
        self.ytlrc = ytlrc
        self.yromalrc = yromalrc
        self.lyricUser = lyricUser
        self.transUser = transUser
        self.nolyric = nolyric
        self.uncollected = uncollected
    }
}

extension LyricResponse: Decodable {
}

public struct LyricContributor: Decodable {
    public let nickname: String?
}

// MARK: - Song URL

public struct SongURLData: Decodable, Hashable {
    public let id: Int
    public let url: String?
    public let br: Int
    public let size: Int
    public let type: String?
    public let level: String?
    public let fee: Int
    public let freeTrialInfo: FreeTrialInfo?
    public let time: Int

    public init(
        id: Int, url: String?, br: Int, size: Int, type: String?, level: String?,
        fee: Int, freeTrialInfo: FreeTrialInfo?, time: Int
    ) {
        self.id = id
        self.url = url
        self.br = br
        self.size = size
        self.type = type
        self.level = level
        self.fee = fee
        self.freeTrialInfo = freeTrialInfo
        self.time = time
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, br, size, type, level, fee, freeTrialInfo, time
    }

}

extension SongURLData {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        url = try? c.decode(String.self, forKey: .url)
        br = (try? c.decode(Int.self, forKey: .br)) ?? 0
        size = (try? c.decode(Int.self, forKey: .size)) ?? 0
        type = try? c.decode(String.self, forKey: .type)
        level = try? c.decode(String.self, forKey: .level)
        fee = (try? c.decode(Int.self, forKey: .fee)) ?? 0
        freeTrialInfo = try? c.decode(FreeTrialInfo.self, forKey: .freeTrialInfo)
        time = (try? c.decode(Int.self, forKey: .time)) ?? 0
    }
}

public struct FreeTrialInfo: Codable, Hashable {
    public let start: Int?
    public let end: Int?
}

// MARK: - Cloud disk

/// A cloud-disk entry. The real payload nests metadata under `privateCloud`
/// and the playable track under `simpleSong`; older docs show flat fields,
/// so both shapes are tolerated.
public struct CloudSongItem: Decodable, Hashable, Identifiable, Sendable {
    public let songId: Int
    public let songName: String?
    public let artist: String?
    public let fileSize: Int
    public let simpleSong: Track?

    public var id: Int { songId }

    private enum CodingKeys: String, CodingKey {
        case songId, songName, artist, fileSize, simpleSong, privateCloud
    }

    private struct PrivateCloud: Decodable {
        let songId: Int?
        let song: String?
        let artist: String?
        let fileSize: Int?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try? c.decode(PrivateCloud.self, forKey: .privateCloud)
        simpleSong = try? c.decode(Track.self, forKey: .simpleSong)
        songId = (try? c.decode(Int.self, forKey: .songId))
            ?? nested?.songId ?? simpleSong?.id ?? 0
        songName = (try? c.decode(String.self, forKey: .songName))
            ?? nested?.song ?? simpleSong?.name
        artist = (try? c.decode(String.self, forKey: .artist)) ?? nested?.artist
        fileSize = (try? c.decode(Int.self, forKey: .fileSize)) ?? nested?.fileSize ?? 0
    }
}

// MARK: - Play record

public struct PlayRecordItem: Decodable, Hashable {
    public let playCount: Int
    public let score: Int
    public let song: Track

    private enum CodingKeys: String, CodingKey {
        case playCount, score, song
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playCount = (try? c.decode(Int.self, forKey: .playCount)) ?? 0
        score = (try? c.decode(Int.self, forKey: .score)) ?? 0
        song = try c.decode(Track.self, forKey: .song)
    }
}

// MARK: - Formatting helpers

public enum Formatters {
    private static var usesChineseUnits: Bool {
        Locale.current.language.languageCode?.identifier == "zh"
    }

    public static func playCount(_ count: Int) -> String {
        if usesChineseUnits {
            switch count {
            case 100_000_000...:
                return String(format: "%.1f亿", Double(count) / 100_000_000)
            case 10_000...:
                return String(format: "%.1f万", Double(count) / 10_000)
            default:
                return String(count)
            }
        }
        switch count {
        case 1_000_000_000...:
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", Double(count) / 1_000_000)
        case 10_000...:
            return String(format: "%.1fK", Double(count) / 1_000)
        default:
            return String(count)
        }
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    public static func longDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total >= 3600 {
            return String(localized: "\(total / 3600) 小时 \((total % 3600) / 60) 分钟")
        }
        return String(localized: "\(total / 60) 分钟")
    }

    public static func date(fromMS ms: Int) -> String {
        guard ms > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }
}

extension String {
    /// NetEase image CDN resize convention: `<picUrl>?param=<W>y<H>`.
    /// Also upgrades `http:` to `https:`.
    public func resizedImageURL(_ size: Int) -> URL? {
        var s = replacingOccurrences(of: "http://", with: "https://")
        s += s.contains("?") ? "&param=\(size)y\(size)" : "?param=\(size)y\(size)"
        return URL(string: s)
    }
}
