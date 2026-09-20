import ComposableArchitecture
import Dependencies
@testable import KumoneCore
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
}
