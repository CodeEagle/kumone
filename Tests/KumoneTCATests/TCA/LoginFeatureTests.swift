import ComposableArchitecture
import Dependencies
import Foundation
import KumoneCore
@testable import KumoneTCA
import XCTest

@MainActor
final class LoginFeatureTests: XCTestCase {
    nonisolated private static let success = NeteaseAPI.QRCheckResponse(
        code: 803, message: nil, nickname: "tester", avatarUrl: nil
    )

    // Start from a state that already has a key so no polling is needed, then
    // drive reducer responses directly.

    func testQRSuccessLeadsToLoginSucceeded() async {
        let store = TestStore(initialState: LoginFeature.State(
            phase: .waiting,
            qrLoginURL: "url",
            unikey: "UNIKEY"
        )) {
            LoginFeature()
        }
        await store.send(.qrCheckResponse(.success(Self.success))) {
            $0.phase = .success
        }
        await store.receive(\.stopPolling)
        await store.receive(\.loginSucceeded)
    }

    func testQRExpiredClearsKey() async {
        let expired = NeteaseAPI.QRCheckResponse(code: 800, message: nil, nickname: nil, avatarUrl: nil)
        let store = TestStore(initialState: LoginFeature.State(
            phase: .waiting,
            qrLoginURL: "url",
            unikey: "UNIKEY"
        )) {
            LoginFeature()
        }
        await store.send(.qrCheckResponse(.success(expired))) {
            $0.phase = .expired
            $0.unikey = nil
        }
        await store.receive(\.stopPolling)
    }

    func testQRScannedShowsNickname() async {
        let scanned = NeteaseAPI.QRCheckResponse(
            code: 802, message: nil, nickname: "Alice", avatarUrl: nil
        )
        let store = TestStore(initialState: LoginFeature.State(
            phase: .waiting,
            qrLoginURL: "url",
            unikey: "UNIKEY"
        )) {
            LoginFeature()
        }
        // 802 shows the nickname; state changes so the poll loop keeps going.
        await store.send(.qrCheckResponse(.success(scanned))) {
            $0.phase = .scanned("Alice")
        }
        await store.send(.stopPolling)
    }

    func testQRWaitingStaysWaiting() async {
        let waiting = NeteaseAPI.QRCheckResponse(code: 801, message: nil, nickname: nil, avatarUrl: nil)
        let store = TestStore(initialState: LoginFeature.State(
            phase: .waiting,
            qrLoginURL: "url",
            unikey: "UNIKEY"
        )) {
            LoginFeature()
        }
        // Already waiting: no observable change.
        await store.send(.qrCheckResponse(.success(waiting)))
        await store.send(.stopPolling)
    }

    func testSMSCodeSentStartsCooldown() async {
        let store = TestStore(initialState: LoginFeature.State(mode: .sms)) {
            LoginFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            $0.netease.sendSMSCode = { _, _ in }
        }
        await store.send(.sendCode) {
            $0.isSendingCode = true
            $0.statusMessage = nil
        }
        await store.receive(\.sendCodeResponse) {
            $0.isSendingCode = false
            $0.statusMessage = "验证码已发送"
            $0.smsCooldown = 60
        }
        // The 60s cooldown ticks down to zero under an immediate clock.
        for remaining in stride(from: 59, through: 0, by: -1) {
            await store.receive(\.codeCooldownTick) {
                $0.smsCooldown = remaining
            }
        }
    }

    func testSMSLoginSucceeds() async {
        let store = TestStore(initialState: LoginFeature.State(mode: .sms)) {
            LoginFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            $0.netease.loginCellphone = { _, _, _ in }
        }
        await store.send(.loginWithCode) {
            $0.isLoggingIn = true
            $0.statusMessage = nil
        }
        await store.receive(\.loginResponse) {
            $0.isLoggingIn = false
        }
        await store.receive(\.stopPolling)
        await store.receive(\.loginSucceeded) {
            $0.phase = .success
        }
    }

    func testSMSFailureShowsMessage() async {
        let store = TestStore(initialState: LoginFeature.State(mode: .sms)) {
            LoginFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            $0.netease.loginCellphone = { _, _, _ in throw URLError(.badServerResponse) }
        }
        await store.send(.loginWithCode) {
            $0.isLoggingIn = true
            $0.statusMessage = nil
        }
        await store.receive(\.loginResponse) {
            $0.isLoggingIn = false
            $0.statusMessage = AppError(wrapping: URLError(.badServerResponse)).message
        }
    }

    func testModeIdentityAndSwitchingWithoutRestartingReadyQR() async {
        XCTAssertEqual(LoginFeature.Mode.qr.id, LoginFeature.Mode.qr.rawValue)
        XCTAssertEqual(LoginFeature.Mode.sms.id, LoginFeature.Mode.sms.rawValue)
        let store = TestStore(initialState: LoginFeature.State(phase: .waiting)) {
            LoginFeature()
        }
        await store.send(.switchMode(.sms)) { $0.mode = .sms }
        await store.receive(.stopPolling)
        await store.send(.switchMode(.qr)) { $0.mode = .qr }
        await store.send(.onAppear)
    }

    func testFreshQRFetchStopsAfterFifteenConsecutiveCheckErrors() async {
        let failure = URLError(.notConnectedToInternet)
        let error = AppError(wrapping: failure)
        nonisolated(unsafe) var checks = 0
        let store = TestStore(initialState: LoginFeature.State(qrLoginURL: "stale")) {
            LoginFeature()
        } withDependencies: {
            $0.musicProvider = MockMusicProvider()
            $0.continuousClock = ImmediateClock()
            $0.netease.qrLoginURL = { "qr:\($0)" }
            $0.netease.qrCheck = { key in
                XCTAssertEqual(key, "")
                checks += 1
                throw failure
            }
        }
        await store.send(.onAppear)
        await store.receive(.startQR) { $0.qrLoginURL = nil }
        await store.receive(.qrKeyResponse(.success(""))) {
            $0.unikey = ""
            $0.qrLoginURL = "qr:"
            $0.phase = .waiting
        }
        await store.receive(.qrCheckResponse(.failure(error))) { $0.phase = .failed(error.message) }
        await store.finish()
        XCTAssertEqual(checks, 15)
    }

    func testFailedAppearanceRetriesExistingKeyAndResetsErrorStreak() async {
        let failure = URLError(.notConnectedToInternet)
        let error = AppError(wrapping: failure)
        let waiting = NeteaseAPI.QRCheckResponse(code: 801, message: nil, nickname: nil, avatarUrl: nil)
        nonisolated(unsafe) var checks = 0
        let store = TestStore(initialState: LoginFeature.State(
            phase: .failed("old"), qrLoginURL: "qr:key", unikey: "key"
        )) { LoginFeature() } withDependencies: {
            $0.continuousClock = ImmediateClock()
            $0.netease.qrCheck = { key in
                XCTAssertEqual(key, "key")
                checks += 1
                if checks == 3 { return waiting }
                throw failure
            }
        }
        await store.send(.onAppear)
        await store.receive(.startQR) { $0.phase = .waiting }
        await store.receive(.qrCheckResponse(.success(waiting)))
        await store.receive(.qrCheckResponse(.failure(error))) { $0.phase = .failed(error.message) }
        await store.finish()
        XCTAssertEqual(checks, 18)
    }

    func testSwitchingToLoadingQRStartsPolling() async {
        let failure = URLError(.notConnectedToInternet)
        let error = AppError(wrapping: failure)
        let store = TestStore(initialState: LoginFeature.State(mode: .sms, unikey: "key")) {
            LoginFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            $0.netease.qrCheck = { _ in throw failure }
        }
        await store.send(.switchMode(.qr)) { $0.mode = .qr }
        await store.receive(.startQR) { $0.phase = .waiting }
        await store.receive(.qrCheckResponse(.failure(error))) { $0.phase = .failed(error.message) }
        await store.finish()
    }

    func testQRResponseTransitionsAndUnknownCode() async {
        let store = TestStore(initialState: LoginFeature.State()) { LoginFeature() }
        await store.send(.qrKeyResponse(.failure(AppError("key failed")))) {
            $0.phase = .failed("key failed")
        }
        await store.send(.qrCheckResponse(.success(.init(code: 802, message: nil, nickname: nil, avatarUrl: nil)))) {
            $0.phase = .scanned("")
        }
        await store.send(.qrCheckResponse(.success(.init(code: 801, message: nil, nickname: nil, avatarUrl: nil)))) {
            $0.phase = .waiting
        }
        await store.send(.qrCheckResponse(.success(.init(code: 999, message: nil, nickname: nil, avatarUrl: nil))))
    }

    func testSMSInputAndSendFailureAndZeroCooldownGuard() async {
        let failure = URLError(.notConnectedToInternet)
        let error = AppError(wrapping: failure)
        let store = TestStore(initialState: LoginFeature.State(mode: .sms)) {
            LoginFeature()
        } withDependencies: {
            $0.netease.sendSMSCode = { phone, country in
                XCTAssertEqual(phone, "13800000000")
                XCTAssertEqual(country, "86")
                throw failure
            }
        }
        await store.send(.setPhone("13800000000")) { $0.phone = "13800000000" }
        await store.send(.setCode("123456")) { $0.code = "123456" }
        await store.send(.sendCode) { $0.isSendingCode = true }
        await store.receive(.sendCodeResponse(.failure(error))) {
            $0.isSendingCode = false
            $0.statusMessage = error.message
        }
        await store.send(.codeCooldownTick)
    }

    func testPollingSleepFailureBecomesQRKeyFailure() async {
        struct FailingClock: Clock {
            typealias Instant = ContinuousClock.Instant
            typealias Duration = Swift.Duration
            var now: Instant { ContinuousClock().now }
            var minimumResolution: Duration { .nanoseconds(1) }
            func sleep(until deadline: Instant, tolerance: Duration?) async throws {
                throw URLError(.timedOut)
            }
        }
        let failure = AppError(wrapping: URLError(.timedOut))
        let store = TestStore(initialState: LoginFeature.State(unikey: "existing")) {
            LoginFeature()
        } withDependencies: {
            $0.continuousClock = FailingClock()
        }
        await store.send(.startQR) { $0.phase = .waiting }
        await store.receive(.qrKeyResponse(.failure(failure))) { $0.phase = .failed(failure.message) }
        await store.finish()
    }

    func testSwitchingToSMSCancelsPendingQRPoll() async {
        let clock = TestClock()
        let store = TestStore(initialState: LoginFeature.State(unikey: "existing")) {
            LoginFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.netease.qrCheck = { _ in
                XCTFail("Switching modes must cancel the pending poll")
                return .init(code: 801, message: nil, nickname: nil, avatarUrl: nil)
            }
        }
        await store.send(.startQR) { $0.phase = .waiting }
        await store.send(.switchMode(.sms)) { $0.mode = .sms }
        await store.receive(.stopPolling)
        await clock.advance(by: .seconds(1.2))
        await store.finish()
    }

    func testQRKeyProviderFailureEndsPollingWithFailureResponse() async {
        struct FailingQRKeyProvider: MusicProvider {
            let base = MockMusicProvider()
            var isLoggedIn: Bool { base.isLoggedIn }
            var supportedMethods: [LoginMethod] { base.supportedMethods }
            func qrLoginURL(_ unikey: String) -> URL { base.qrLoginURL(unikey) }
            func logout() async { await base.logout() }
            func refreshLogin() async { await base.refreshLogin() }
            func qrKey() async throws -> String { throw URLError(.notConnectedToInternet) }
            func qrCheck(_ unikey: String) async throws -> LoginCheck { try await base.qrCheck(unikey) }
            func sendSMSCode(phone: String, countryCode: String) async throws { try await base.sendSMSCode(phone: phone, countryCode: countryCode) }
            func loginCellphone(phone: String, captcha: String, countryCode: String) async throws { try await base.loginCellphone(phone: phone, captcha: captcha, countryCode: countryCode) }
            func userAccount() async throws -> UserProfile { try await base.userAccount() }
            func userPlaylists(uid: MusicID, limit: Int, offset: Int) async throws -> [PlaylistSummary] { try await base.userPlaylists(uid: uid, limit: limit, offset: offset) }
            func likedTrackIDs(uid: MusicID) async throws -> [MusicID] { try await base.likedTrackIDs(uid: uid) }
            func likeTrack(_ id: MusicID, like: Bool) async throws { try await base.likeTrack(id, like: like) }
            func likedAlbums(limit: Int, offset: Int) async throws -> [AlbumSummary] { try await base.likedAlbums(limit: limit, offset: offset) }
            func likedArtists(limit: Int, offset: Int) async throws -> [ArtistSummary] { try await base.likedArtists(limit: limit, offset: offset) }
            func playlistDetail(id: MusicID) async throws -> PlaylistDetail { try await base.playlistDetail(id: id) }
            func playlistBrief(id: MusicID) async throws -> PlaylistBriefInfo { try await base.playlistBrief(id: id) }
            func createPlaylist(name: String, isPrivate: Bool) async throws -> MusicID? { try await base.createPlaylist(name: name, isPrivate: isPrivate) }
            func deletePlaylist(_ id: MusicID) async throws { try await base.deletePlaylist(id) }
            func subscribePlaylist(_ id: MusicID, subscribe: Bool) async throws { try await base.subscribePlaylist(id, subscribe: subscribe) }
            func playlistTracks(_ op: PlaylistOp, playlistID: MusicID, trackIDs: [MusicID]) async throws { try await base.playlistTracks(op, playlistID: playlistID, trackIDs: trackIDs) }
            func songURL(ids: [MusicID], quality: SongQuality) async throws -> [SongURLData] { try await base.songURL(ids: ids, quality: quality) }
            func songDetails(ids: [MusicID]) async throws -> [Track] { try await base.songDetails(ids: ids) }
            func lyric(id: MusicID) async throws -> LyricResponse { try await base.lyric(id: id) }
            func scrobbleStart(trackID: MusicID, sourceID: MusicID) async { await base.scrobbleStart(trackID: trackID, sourceID: sourceID) }
            func scrobbleFinish(trackID: MusicID, sourceID: MusicID, seconds: Int) async { await base.scrobbleFinish(trackID: trackID, sourceID: sourceID, seconds: seconds) }
            func similarSongs(id: MusicID, limit: Int) async throws -> [Track] { try await base.similarSongs(id: id, limit: limit) }
            func search(_ keywords: String, category: SearchCategory, limit: Int, offset: Int) async throws -> SearchResult { try await base.search(keywords, category: category, limit: limit, offset: offset) }
            func searchSuggest(_ keywords: String) async throws -> SearchSuggestion { try await base.searchSuggest(keywords) }
            func searchDefaultKeyword() async throws -> String? { try await base.searchDefaultKeyword() }
            func toplists() async throws -> [Chart] { try await base.toplists() }
            func topArtists(limit: Int) async throws -> [ArtistSummary] { try await base.topArtists(limit: limit) }
            func newAlbums(area: String, limit: Int, offset: Int) async throws -> [AlbumSummary] { try await base.newAlbums(area: area, limit: limit, offset: offset) }
            func personalizedNewSongs(limit: Int) async throws -> [Track] { try await base.personalizedNewSongs(limit: limit) }
            func dislikeRecommendedSong(_ id: MusicID) async throws -> Track { try await base.dislikeRecommendedSong(id) }
            func personalizedPlaylists(limit: Int) async throws -> [PlaylistSummary] { try await base.personalizedPlaylists(limit: limit) }
            func recommendResource() async throws -> [PlaylistSummary] { try await base.recommendResource() }
            func dailyRecommendSongs() async throws -> [Track] { try await base.dailyRecommendSongs() }
            func topPlaylists(category: String, order: String, limit: Int, offset: Int) async throws -> ChartList { try await base.topPlaylists(category: category, order: order, limit: limit, offset: offset) }
            func highQualityPlaylists(category: String, limit: Int, before: Int?) async throws -> HighQualityList { try await base.highQualityPlaylists(category: category, limit: limit, before: before) }
            func album(id: MusicID) async throws -> AlbumDetail { try await base.album(id: id) }
            func albumDynamic(id: MusicID) async throws -> AlbumDynamic { try await base.albumDynamic(id: id) }
            func subscribeAlbum(_ id: MusicID, subscribe: Bool) async throws { try await base.subscribeAlbum(id, subscribe: subscribe) }
            func artist(id: MusicID) async throws -> ArtistDetail { try await base.artist(id: id) }
            func artistAlbums(id: MusicID, limit: Int, offset: Int) async throws -> ArtistAlbums { try await base.artistAlbums(id: id, limit: limit, offset: offset) }
            func subscribeArtist(_ id: MusicID, subscribe: Bool) async throws { try await base.subscribeArtist(id, subscribe: subscribe) }
            func similarArtists(id: MusicID) async throws -> [ArtistSummary] { try await base.similarArtists(id: id) }
        }
        let failure = AppError(wrapping: URLError(.notConnectedToInternet))
        let store = TestStore(initialState: LoginFeature.State(qrLoginURL: "stale")) {
            LoginFeature()
        } withDependencies: {
            $0.musicProvider = FailingQRKeyProvider()
            $0.netease.qrCheck = { _ in
                XCTFail("A failed key request must not begin polling")
                return .init(code: 801, message: nil, nickname: nil, avatarUrl: nil)
            }
        }
        await store.send(.startQR) { $0.qrLoginURL = nil }
        await store.receive(.qrKeyResponse(.failure(failure))) {
            $0.phase = .failed(failure.message)
        }
        await store.finish()
    }

}
