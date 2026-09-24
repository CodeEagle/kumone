import Foundation

/// Typed NetEase Cloud Music API surface, mapped to real weapi/eapi endpoints.
public enum NeteaseAPI {
    private static var client: NeteaseClient { .shared }

    private static func weapi<T: Decodable>(
        _ type: T.Type, _ path: String, _ payload: [String: Any] = [:],
        cookieOverrides: [String: String] = [:]
    ) async throws -> T {
        let data = try await client.weapi(path, payload, cookieOverrides: cookieOverrides)
        return try client.decoded(T.self, from: data)
    }

    private static func eapi<T: Decodable>(
        _ type: T.Type, _ path: String, _ payload: [String: Any] = [:]
    ) async throws -> T {
        let data = try await client.eapi(path, payload)
        return try client.decoded(T.self, from: data)
    }

    public struct CodeOnly: Decodable {
        public let code: Int
    }

    // MARK: - Auth

    public struct QRKeyResponse: Decodable {
        public let code: Int
        public let unikey: String
    }

    public static func qrKey() async throws -> String {
        try await weapi(QRKeyResponse.self, "/login/qrcode/unikey", ["type": 1]).unikey
    }

    public static func qrLoginURL(unikey: String) -> String {
        "https://music.163.com/login?codekey=\(unikey)"
    }

    public struct QRCheckResponse: Decodable, Equatable, Sendable {
        public let code: Int
        public let message: String?
        public let nickname: String?
        public let avatarUrl: String?

        public init(code: Int, message: String?, nickname: String?, avatarUrl: String?) {
            self.code = code
            self.message = message
            self.nickname = nickname
            self.avatarUrl = avatarUrl
        }
    }

    /// Codes: 800 expired · 801 waiting · 802 scanned · 803 success.
    /// On 803 the auth cookies arrive via Set-Cookie and are absorbed by the client.
    public static func qrCheck(unikey: String) async throws -> QRCheckResponse {
        let data = try await client.weapi("/login/qrcode/client/login", ["key": unikey, "type": 1])
        return try JSONDecoder().decode(QRCheckResponse.self, from: data)
    }

    /// Sends an SMS verification code for phone-number login
    /// (upstream: `/api/sms/captcha/sent`).
    public static func sendSMSCode(phone: String, countryCode: String = "86") async throws {
        let data = try await client.weapi("/sms/captcha/sent",
                                          ["ctcode": countryCode, "cellphone": phone,
                                           "secrete": "music_middleuser_pclogin"])
        _ = try client.decoded(CodeOnly.self, from: data)
    }

    /// Phone-number login with an SMS code (upstream: `/api/w/login/cellphone`).
    /// Auth cookies arrive via Set-Cookie.
    public static func loginCellphone(phone: String, captcha: String, countryCode: String = "86") async throws {
        let data = try await client.weapi("/w/login/cellphone",
                                          ["type": "1", "https": "true",
                                           "phone": phone, "countrycode": countryCode,
                                           "captcha": captcha, "remember": "true",
                                           "secureCaptcha": ""])
        _ = try client.decoded(CodeOnly.self, from: data)
        guard client.isLoggedIn else {
            throw NeteaseAPIError.business(code: -1, message: String(localized: "登录失败，请重试"))
        }
    }

    public static func logout() async {
        _ = try? await client.weapi("/logout")
        client.clearAuthCookies()
    }

    public static func refreshLogin() async {
        _ = try? await client.weapi("/login/token/refresh")
    }

    public struct AccountResponse: Decodable {
        public let code: Int
        public let profile: UserProfile?
    }

    public static func userAccount() async throws -> UserProfile? {
        try await weapi(AccountResponse.self, "/w/nuser/account/get").profile
    }

    // MARK: - User library

    public struct UserPlaylistsResponse: Decodable {
        public let playlist: [PlaylistSummary]
        public let more: Bool?
    }

    public static func userPlaylists(uid: Int, limit: Int = 2000, offset: Int = 0) async throws -> [PlaylistSummary] {
        try await weapi(UserPlaylistsResponse.self, "/user/playlist",
                        ["uid": uid, "limit": limit, "offset": offset, "includeVideo": true]).playlist
    }

    public struct LikelistResponse: Decodable {
        public let ids: [Int]
    }

    public static func likedTrackIDs(uid: Int) async throws -> [Int] {
        try await weapi(LikelistResponse.self, "/song/like/get", ["uid": uid]).ids
    }

    public static func likeTrack(id: Int, like: Bool) async throws {
        let resp = try await weapi(CodeOnly.self, "/radio/like?alg=itembased&trackId=\(id)&time=3",
                                   ["trackId": id, "like": like])
        guard resp.code == 200 else {
            throw NeteaseAPIError.business(code: resp.code, message: String(localized: "操作失败，专辑下架或版权锁定"))
        }
    }

    public struct SublistResponse<Item: Decodable>: Decodable {
        public let data: [Item]
        public let count: Int?
        public let hasMore: Bool?
    }

    public static func likedAlbums(limit: Int = 500, offset: Int = 0) async throws -> [AlbumSummary] {
        try await weapi(SublistResponse<AlbumSummary>.self, "/album/sublist",
                        ["limit": limit, "offset": offset, "total": true]).data
    }

    public static func likedArtists(limit: Int = 500, offset: Int = 0) async throws -> [ArtistSummary] {
        try await weapi(SublistResponse<ArtistSummary>.self, "/artist/sublist",
                        ["limit": limit, "offset": offset, "total": true]).data
    }

    public struct PlayRecordResponse: Decodable {
        public let weekData: [PlayRecordItem]?
        public let allData: [PlayRecordItem]?
    }

    public static func playRecords(uid: Int, week: Bool) async throws -> [PlayRecordItem] {
        let resp = try await weapi(PlayRecordResponse.self, "/v1/play/record",
                                   ["uid": uid, "type": week ? 1 : 0])
        return (week ? resp.weekData : resp.allData) ?? []
    }

    public struct CloudResponse: Decodable {
        public let data: [CloudSongItem]?
        public let hasMore: Bool?
        /// Bytes; served as a number or a numeric string depending on account age.
        public let size: Int64?
        public let maxSize: Int64?

        private enum CodingKeys: String, CodingKey {
            case data, hasMore, size, maxSize
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            data = try? c.decode([CloudSongItem].self, forKey: .data)
            hasMore = try? c.decode(Bool.self, forKey: .hasMore)
            size = (try? c.decode(Int64.self, forKey: .size))
                ?? (try? c.decode(String.self, forKey: .size)).flatMap(Int64.init)
            maxSize = (try? c.decode(Int64.self, forKey: .maxSize))
                ?? (try? c.decode(String.self, forKey: .maxSize)).flatMap(Int64.init)
        }
    }

    public static func cloudSongs(limit: Int = 1000, offset: Int = 0) async throws -> CloudResponse {
        try await weapi(CloudResponse.self, "/v1/cloud/get", ["limit": limit, "offset": offset])
    }

    public static func cloudDelete(id: Int) async throws {
        _ = try await weapi(CodeOnly.self, "/cloud/del", ["songIds": "[\(id)]"])
    }

    /// `startplay` weblog — writes the song into the 最近播放 (recent-plays)
    /// list. NetEase needs this *and* the `play` weblog; sending only `play`
    /// (as before) bumped the listening ranking but never wrote 最近播放 (#33).
    public static func scrobbleStart(trackID: Int, sourceID: Int) async {
        await sendWeblog([[
            "action": "startplay",
            "json": [
                "id": trackID, "type": "song",
                "mainsite": "1", "mainsiteWeb": "1",
                "content": "id=\(sourceID)",
            ],
        ]])
    }

    /// `play` weblog — increments the listening-ranking play count and time.
    public static func scrobbleFinish(trackID: Int, sourceID: Int, seconds: Int) async {
        await sendWeblog([[
            "action": "play",
            "json": [
                "download": 0, "end": "playend", "id": trackID,
                "sourceId": String(sourceID), "time": seconds,
                "type": "song", "wifi": 0, "source": "list",
                "mainsite": "1", "mainsiteWeb": "1",
                "content": "id=\(sourceID)",
            ],
        ]])
    }

    /// Routed via eapi with the desktop-client cookie (`os=osx`) to match the
    /// reference scrobble implementation.
    private static func sendWeblog(_ log: [[String: Any]]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: log),
              let logs = String(data: data, encoding: .utf8) else { return }
        _ = try? await client.eapi("/feedback/weblog", ["logs": logs],
                                   cookieOverrides: ["os": "osx"])
    }

    // MARK: - Playlists

    public struct PersonalizedResponse: Decodable {
        public let result: [PlaylistSummary]
    }

    public static func personalizedPlaylists(limit: Int = 30) async throws -> [PlaylistSummary] {
        try await weapi(PersonalizedResponse.self, "/personalized/playlist",
                        ["limit": limit, "total": true, "n": 1000]).result
    }

    public struct RecommendResourceResponse: Decodable {
        public let recommend: [PlaylistSummary]
    }

    /// Logged-in daily recommended playlists.
    public static func recommendResource() async throws -> [PlaylistSummary] {
        try await weapi(RecommendResourceResponse.self, "/v1/discovery/recommend/resource").recommend
    }

    public struct RecommendSongsResponse: Decodable {
        public struct Body: Decodable {
            public let dailySongs: [Track]?
        }

        // New accounts with no listening history get `"data": null`.
        public let data: Body?
    }

    public static func dailyRecommendSongs() async throws -> [Track] {
        let resp = try await weapi(RecommendSongsResponse.self, "/v3/discovery/recommend/songs")
        return resp.data?.dailySongs ?? []
    }

    public struct RecommendDislikeResponse: Decodable {
        public let data: Track

        private enum CodingKeys: String, CodingKey {
            case data
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let track = try container.decode(Track.self, forKey: .data)
            guard track.id > 0,
                  !track.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .data,
                    in: container,
                    debugDescription: "Recommendation replacement is incomplete"
                )
            }
            data = track
        }
    }

    public static func dislikeRecommendedSong(id: Int) async throws -> Track {
        try await weapi(
            RecommendDislikeResponse.self,
            "/v2/discovery/recommend/dislike",
            ["resId": id, "resType": 4, "sceneType": 1]
        ).data
    }

    public struct PlaylistDetailResponse: Decodable {
        public let playlist: PlaylistDetail
        public let privileges: [TrackPrivilege]?

        public init(playlist: PlaylistDetail, privileges: [TrackPrivilege]?) {
            self.playlist = playlist
            self.privileges = privileges
        }
    }

    public static func playlistDetail(id: Int) async throws -> PlaylistDetailResponse {
        try await weapi(PlaylistDetailResponse.self, "/v6/playlist/detail",
                        ["id": id, "n": 100_000, "s": 8])
    }

    public struct PlaylistBrief: Decodable {
        public struct Body: Decodable {
            public let id: Int
            public let name: String?
            public let coverImgUrl: String?
        }

        public let playlist: Body
    }

    /// Lightweight name + cover fetch (used for the personalized radar playlists,
    /// whose title/artwork are generated per account).
    public static func playlistBrief(id: Int) async throws -> PlaylistBrief.Body {
        try await weapi(PlaylistBrief.self, "/v6/playlist/detail", ["id": id, "n": 1, "s": 0]).playlist
    }

    public struct SongDetailResponse: Decodable {
        public let songs: [Track]
        public let privileges: [TrackPrivilege]?

        public init(songs: [Track], privileges: [TrackPrivilege]?) {
            self.songs = songs
            self.privileges = privileges
        }
    }

    public static func songDetails(ids: [Int]) async throws -> SongDetailResponse {
        guard !ids.isEmpty else { return SongDetailResponse(songs: [], privileges: []) }
        let c = "[" + ids.map { "{\"id\":\($0)}" }.joined(separator: ",") + "]"
        return try await weapi(SongDetailResponse.self, "/v3/song/detail", ["c": c])
    }

    public struct TopPlaylistResponse: Decodable {
        public let playlists: [PlaylistSummary]
        public let total: Int?
        public let more: Bool?

        public init(playlists: [PlaylistSummary], total: Int?, more: Bool?) {
            self.playlists = playlists
            self.total = total
            self.more = more
        }
    }

    public static func topPlaylists(category: String, order: String = "hot",
                             limit: Int = 50, offset: Int = 0) async throws -> TopPlaylistResponse {
        try await weapi(TopPlaylistResponse.self, "/playlist/list",
                        ["cat": category, "order": order, "limit": limit, "offset": offset, "total": true])
    }

    public struct HighQualityResponse: Decodable {
        public let playlists: [PlaylistSummary]
        public let lasttime: Int?
        public let more: Bool?

        public init(playlists: [PlaylistSummary], lasttime: Int?, more: Bool?) {
            self.playlists = playlists
            self.lasttime = lasttime
            self.more = more
        }
    }

    public static func highQualityPlaylists(category: String = "全部", limit: Int = 50,
                                     before: Int = 0) async throws -> HighQualityResponse {
        try await weapi(HighQualityResponse.self, "/playlist/highquality/list",
                        ["cat": category, "limit": limit, "lasttime": before, "total": true])
    }

    public struct ToplistResponse: Decodable {
        public let list: [ToplistItem]
    }

    public static func toplists() async throws -> [ToplistItem] {
        try await eapi(ToplistResponse.self, "/toplist").list
    }

    public struct PlaylistCreateResponse: Decodable {
        public let code: Int
        public let id: Int?
    }

    @discardableResult
    public static func createPlaylist(name: String, isPrivate: Bool) async throws -> Int? {
        try await weapi(PlaylistCreateResponse.self, "/playlist/create",
                        ["name": name, "privacy": isPrivate ? 10 : 0, "type": "NORMAL"]).id
    }

    public static func deletePlaylist(id: Int) async throws {
        _ = try await weapi(CodeOnly.self, "/playlist/remove", ["ids": "[\(id)]"])
    }

    public static func subscribePlaylist(id: Int, subscribe: Bool) async throws {
        _ = try await weapi(CodeOnly.self, "/playlist/\(subscribe ? "subscribe" : "unsubscribe")", ["id": id])
    }

    public struct ManipulateResponse: Decodable {
        public let code: Int?
    }

    public static func playlistTracks(op: String, playlistID: Int, trackIDs: [Int]) async throws {
        let ids = "[" + trackIDs.map(String.init).joined(separator: ",") + "]"
        let data = try await client.weapi("/playlist/manipulate/tracks",
                                          ["op": op, "pid": playlistID, "trackIds": ids, "imme": "true"])
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = obj["code"] as? Int, code != 200 {
            // 512: already-in-playlist quirk — retry with doubled ids like the reference impl
            if code == 512, op == "add" {
                let doubled = "[" + (trackIDs + trackIDs).map(String.init).joined(separator: ",") + "]"
                _ = try await client.weapi("/playlist/manipulate/tracks",
                                           ["op": op, "pid": playlistID, "trackIds": doubled, "imme": "true"])
                return
            }
            throw NeteaseAPIError.business(code: code, message: obj["message"] as? String)
        }
    }

    public struct IntelligenceResponse: Decodable {
        public struct Item: Decodable {
            public let songInfo: Track?
            public let id: Int?
        }

        public let data: [Item]?
    }

    /// 心动模式 — generates a heartbeat-mode queue from a seed song in a playlist.
    public static func intelligenceList(songID: Int, playlistID: Int) async throws -> [Track] {
        let resp = try await weapi(IntelligenceResponse.self, "/playmode/intelligence/list",
                                   ["songId": songID, "type": "fromPlayOne",
                                    "playlistId": playlistID, "startMusicId": songID, "count": 1])
        return (resp.data ?? []).compactMap(\.songInfo)
    }

    // MARK: - Tracks

    public struct SongURLResponse: Decodable {
        public let data: [SongURLData]
    }

    public static func songURL(ids: [Int], level: String) async throws -> [SongURLData] {
        let idString = "[" + ids.map(String.init).joined(separator: ",") + "]"
        var payload: [String: Any] = ["ids": idString, "level": level, "encodeType": "flac"]
        if level == "sky" { payload["immerseType"] = "c51" }
        return try await eapi(SongURLResponse.self, "/song/enhance/player/url/v1", payload).data
    }

    public static func lyric(id: Int) async throws -> LyricResponse {
        // `/song/lyric/v1` also returns verbatim (word-by-word) `yrc`. Fall back
        // to the classic endpoint if it yields nothing usable, so plain lyrics
        // never regress.
        if let v1 = try? await weapi(LyricResponse.self, "/song/lyric/v1",
            ["id": id, "cp": false,
             "lv": 0, "kv": 0, "tv": 0, "rv": 0, "yv": 0, "ytv": 0, "yrv": 0]),
            (v1.lrc?.lyric?.isEmpty == false) || (v1.yrc?.lyric?.isEmpty == false) {
            return v1
        }
        return try await weapi(LyricResponse.self, "/song/lyric",
                               ["id": id, "lv": -1, "kv": -1, "tv": -1, "rv": -1])
    }

    public struct FMResponse: Decodable {
        public let data: [Track]?
    }

    public static func personalFM() async throws -> [Track] {
        try await weapi(FMResponse.self, "/v1/radio/get").data ?? []
    }

    public static func fmTrash(id: Int) async throws {
        _ = try await weapi(CodeOnly.self, "/radio/trash/add?alg=RT&songId=\(id)&time=25",
                            ["songId": id])
    }

    public struct SimiSongResponse: Decodable {
        public let songs: [Track]
    }

    public static func similarSongs(id: Int, limit: Int = 30) async throws -> [Track] {
        try await weapi(SimiSongResponse.self, "/v1/discovery/simiSong",
                        ["songid": id, "limit": limit, "offset": 0]).songs
    }

    // MARK: - Albums

    public static func album(id: Int) async throws -> AlbumDetailResponse {
        try await weapi(AlbumDetailResponse.self, "/v1/album/\(id)")
    }

    public struct NewAlbumsResponse: Decodable {
        public let albums: [AlbumSummary]
    }

    public static func newAlbums(area: String = "ALL", limit: Int = 30, offset: Int = 0) async throws -> [AlbumSummary] {
        try await weapi(NewAlbumsResponse.self, "/album/new",
                        ["area": area, "limit": limit, "offset": offset, "total": true]).albums
    }

    public struct AlbumDynamicResponse: Decodable {
        public let isSub: Bool?
        public let subCount: Int?

        public init(isSub: Bool?, subCount: Int?) {
            self.isSub = isSub
            self.subCount = subCount
        }
    }

    public static func albumDynamic(id: Int) async throws -> AlbumDynamicResponse {
        try await eapi(AlbumDynamicResponse.self, "/album/detail/dynamic", ["id": id])
    }

    public static func subscribeAlbum(id: Int, subscribe: Bool) async throws {
        _ = try await weapi(CodeOnly.self, "/album/\(subscribe ? "sub" : "unsub")", ["id": id])
    }

    // MARK: - Artists

    public struct ArtistResponse: Decodable {
        public let artist: ArtistSummary
        public let hotSongs: [Track]

        public init(artist: ArtistSummary, hotSongs: [Track]) {
            self.artist = artist
            self.hotSongs = hotSongs
        }
    }

    public static func artist(id: Int) async throws -> ArtistResponse {
        let data = try await client.weapi("/v1/artist/\(id)")
        // The artist object repeats `followed`: an anonymous cached value first,
        // the session-specific value last. JSONDecoder keeps the first occurrence
        // (always false), so drop the earlier ones like the web player's JSON.parse.
        return try client.decoded(ArtistResponse.self, from: data.keepingLastJSONValue(ofKey: "followed"))
    }

    public struct ArtistAlbumsResponse: Decodable {
        public let hotAlbums: [AlbumSummary]
        public let more: Bool?

        public init(hotAlbums: [AlbumSummary], more: Bool?) {
            self.hotAlbums = hotAlbums
            self.more = more
        }
    }

    public static func artistAlbums(id: Int, limit: Int = 100, offset: Int = 0) async throws -> ArtistAlbumsResponse {
        try await weapi(ArtistAlbumsResponse.self, "/artist/albums/\(id)",
                        ["limit": limit, "offset": offset, "total": true])
    }

    public static func subscribeArtist(id: Int, subscribe: Bool) async throws {
        // `os=pc` makes NetEase validate this write against the desktop-client
        // schema and reject it (code 250); the web API sends no `os` cookie.
        _ = try await weapi(CodeOnly.self, "/artist/\(subscribe ? "sub" : "unsub")",
                            ["artistId": id, "artistIds": "[\(id)]"],
                            cookieOverrides: ["os": ""])
    }

    public struct ToplistArtistResponse: Decodable {
        public struct Body: Decodable {
            public let artists: [ArtistSummary]
        }

        public let list: Body
    }

    public static func topArtists(limit: Int = 100) async throws -> [ArtistSummary] {
        try await weapi(ToplistArtistResponse.self, "/toplist/artist",
                        ["type": 1, "limit": limit, "offset": 0, "total": true]).list.artists
    }

    public struct SimiArtistResponse: Decodable {
        public let artists: [ArtistSummary]
    }

    public static func similarArtists(id: Int) async throws -> [ArtistSummary] {
        try await weapi(SimiArtistResponse.self, "/discovery/simiArtist", ["artistid": id]).artists
    }

    // MARK: - Search

    public enum SearchType: Int {
        case songs = 1
        case albums = 10
        case artists = 100
        case playlists = 1000
    }

    public struct SearchResult: Decodable {
        public let songs: [Track]?
        public let albums: [AlbumSummary]?
        public let artists: [ArtistSummary]?
        public let playlists: [PlaylistSummary]?
        public let songCount: Int?
        public let albumCount: Int?
        public let artistCount: Int?
        public let playlistCount: Int?
    }

    public struct SearchResponse: Decodable {
        public let result: SearchResult?
    }

    public static func search(_ keywords: String, type: SearchType,
                       limit: Int = 30, offset: Int = 0) async throws -> SearchResult {
        let resp = try await eapi(SearchResponse.self, "/cloudsearch/pc",
                                  ["s": keywords, "type": type.rawValue,
                                   "limit": limit, "offset": offset, "total": true])
        return resp.result ?? SearchResult(songs: nil, albums: nil, artists: nil, playlists: nil,
                                           songCount: nil, albumCount: nil, artistCount: nil, playlistCount: nil)
    }

    public struct SearchSuggestResponse: Decodable {
        public struct Body: Decodable {
            public let songs: [Track]?
            public let artists: [ArtistSummary]?
            public let albums: [AlbumSummary]?
            public let playlists: [PlaylistSummary]?
        }

        public let result: Body?
    }

    public static func searchSuggest(_ keywords: String) async throws -> SearchSuggestResponse.Body? {
        try await weapi(SearchSuggestResponse.self, "/search/suggest/web", ["s": keywords]).result
    }

    public struct SearchDefaultResponse: Decodable {
        public struct Body: Decodable {
            public let showKeyword: String?
            public let realkeyword: String?
        }

        public let data: Body?
    }

    public static func searchDefaultKeyword() async throws -> String? {
        try await eapi(SearchDefaultResponse.self, "/search/defaultkeyword/get").data?.showKeyword
    }

    // MARK: - Personalized extras

    public struct PersonalizedNewsongResponse: Decodable {
        public struct Item: Decodable {
            public let id: Int
            public let name: String?
            public let song: Track?
        }

        public let result: [Item]
    }

    public static func personalizedNewSongs(limit: Int = 10) async throws -> [Track] {
        let resp = try await weapi(PersonalizedNewsongResponse.self, "/personalized/newsong",
                                   ["type": "recommend", "limit": limit, "areaId": 0])
        return resp.result.compactMap(\.song)
    }
}

private extension Data {
    /// Keeps only the last JSON occurrence of `key`, whose value is a boolean.
    /// NetEase emits some objects twice: a cached anonymous copy followed by the
    /// session-specific fields. Web clients implicitly take the last occurrence;
    /// `JSONDecoder` takes the first, so drop the earlier ones before decoding.
    func keepingLastJSONValue(ofKey key: String) -> Data {
        guard let text = String(data: self, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: "\"\(key)\"\\s*:\\s*(?:true|false)")
        else { return self }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count > 1 else { return self }
        var result = ""
        var cursor = text.startIndex
        for match in matches.dropLast() {
            let range = Range(match.range, in: text)!
            var lower = range.lowerBound
            var upper = range.upperBound
            // Swallow exactly one adjacent separator so the object stays valid.
            if cursor < lower, text[text.index(before: lower)] == "," {
                lower = text.index(before: lower)
            } else if upper < text.endIndex, text[upper] == "," {
                upper = text.index(after: upper)
            }
            result += text[cursor..<lower]
            cursor = upper
        }
        result += text[cursor...]
        return Data(result.utf8)
    }
}
