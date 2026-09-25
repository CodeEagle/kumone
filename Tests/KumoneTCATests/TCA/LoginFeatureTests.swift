import ComposableArchitecture
import Dependencies
import Foundation
@testable import KumoneCore
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
        var provider = MockMusicProvider()
        provider.sendSMSCodeHandler = { _, _ in }
        let store = TestStore(initialState: LoginFeature.State(mode: .sms)) {
            LoginFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            $0.musicProvider = provider
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
        var provider = MockMusicProvider()
        provider.loginCellphoneHandler = { _, _, _ in }
        let store = TestStore(initialState: LoginFeature.State(mode: .sms)) {
            LoginFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            $0.musicProvider = provider
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
        var provider = MockMusicProvider()
        provider.loginCellphoneHandler = { _, _, _ in throw URLError(.badServerResponse) }
        let store = TestStore(initialState: LoginFeature.State(mode: .sms)) {
            LoginFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            $0.musicProvider = provider
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
        var provider = MockMusicProvider()
        provider.qrLoginURLHandler = { URL(string: "qr:\($0)")! }
        provider.qrCheckHandler = { key in
            XCTAssertEqual(key, "")
            checks += 1
            throw failure
        }
        let store = TestStore(initialState: LoginFeature.State(qrLoginURL: "stale")) {
            LoginFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            $0.musicProvider = provider
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
        var provider = MockMusicProvider()
        provider.qrCheckHandler = { key in
            XCTAssertEqual(key, "key")
            checks += 1
            if checks == 3 {
                return LoginCheck(code: waiting.code, message: waiting.message, nickname: waiting.nickname, avatar: nil)
            }
            throw failure
        }
        let store = TestStore(initialState: LoginFeature.State(
            phase: .failed("old"), qrLoginURL: "qr:key", unikey: "key"
        )) { LoginFeature() } withDependencies: {
            $0.continuousClock = ImmediateClock()
            $0.musicProvider = provider
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
        var provider = MockMusicProvider()
        provider.qrCheckHandler = { _ in throw failure }
        let store = TestStore(initialState: LoginFeature.State(mode: .sms, unikey: "key")) {
            LoginFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            $0.musicProvider = provider
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
        var provider = MockMusicProvider()
        provider.sendSMSCodeHandler = { phone, country in
            XCTAssertEqual(phone, "13800000000")
            XCTAssertEqual(country, "86")
            throw failure
        }
        let store = TestStore(initialState: LoginFeature.State(mode: .sms)) {
            LoginFeature()
        } withDependencies: {
            $0.musicProvider = provider
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
        var provider = MockMusicProvider()
        provider.qrCheckHandler = { _ in
            XCTFail("Switching modes must cancel the pending poll")
            return LoginCheck(code: 801, message: nil, nickname: nil, avatar: nil)
        }
        let store = TestStore(initialState: LoginFeature.State(unikey: "existing")) {
            LoginFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.musicProvider = provider
        }
        await store.send(.startQR) { $0.phase = .waiting }
        await store.send(.switchMode(.sms)) { $0.mode = .sms }
        await store.receive(.stopPolling)
        await clock.advance(by: .seconds(1.2))
        await store.finish()
    }

    func testQRKeyProviderFailureEndsPollingWithFailureResponse() async {
        let failure = AppError(wrapping: URLError(.notConnectedToInternet))
        var provider = MockMusicProvider()
        provider.qrKeyHandler = { throw URLError(.notConnectedToInternet) }
        provider.qrCheckHandler = { _ in
            XCTFail("A failed key request must not begin polling")
            return LoginCheck(code: 801, message: nil, nickname: nil, avatar: nil)
        }
        let store = TestStore(initialState: LoginFeature.State(qrLoginURL: "stale")) {
            LoginFeature()
        } withDependencies: {
            $0.musicProvider = provider
        }
        await store.send(.startQR) { $0.qrLoginURL = nil }
        await store.receive(.qrKeyResponse(.failure(failure))) {
            $0.phase = .failed(failure.message)
        }
        await store.finish()
    }

}
